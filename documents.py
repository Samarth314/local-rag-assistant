"""Enumerating the index as a document library.

This is the read side of the vault: what is indexed, what each file is, and
its bytes. Retrieval (`retrieval.py`) answers "which chunks are relevant to a
question"; this module answers "what documents exist" -- a different question
with a different shape, which is why it is not part of the search path.

Everything here is derived from `index_state.json`, which the indexer already
maintains. Nothing walks the filesystem: a file that is not indexed is not a
document as far as this API is concerned, and that is the property the whole
module leans on for safety (see `resolve`).
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Optional

import config

# Categories the mobile client filters by. Derived from the path rather than
# stored: the vault's directory layout is the taxonomy the user already keeps,
# so inventing a second one would just be a thing to keep in sync.
CATEGORIES = ("finances", "health", "communications", "work", "personal")

_CATEGORY_HINTS: dict[str, tuple[str, ...]] = {
    "finances": ("finance", "financial", "budget", "tax", "taxes", "loan",
                 "loans", "mortgage", "invoice", "invoices", "billing",
                 "bank", "banking", "receipts", "subscriptions"),
    "health": ("health", "medical", "labs", "lab", "clinic", "clinical",
               "prescription", "prescriptions", "medications", "insurance"),
    "communications": ("communications", "comms", "email", "emails", "mail",
                       "messages", "correspondence", "threads"),
    "work": ("work", "projects", "project", "school", "course", "courses",
             "class", "classes", "research", "papers", "career", "resume"),
    "personal": ("personal", "life", "journal", "notes", "travel", "recipes",
                 "photos", "home"),
}

# Longest hint first, so "financial-planning" is not matched by a shorter,
# less specific hint that happens to appear earlier in another category.
_HINT_INDEX: tuple[tuple[str, str], ...] = tuple(
    sorted(
        ((hint, category)
         for category, hints in _CATEGORY_HINTS.items()
         for hint in hints),
        key=lambda pair: (-len(pair[0]), pair[0]),
    )
)

DEFAULT_CATEGORY = "personal"
EXCERPT_CHARS = 240


@dataclass(frozen=True)
class Document:
    """One indexed file, as the library presents it."""
    id: str
    title: str
    path: str
    category: str
    file_type: str
    size_bytes: Optional[int]
    modified_at: Optional[float]   # source file mtime, from the fingerprint
    indexed_at: Optional[float]    # when the indexer last processed it
    excerpt: str = ""
    chunk_count: Optional[int] = None
    tags: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "id": self.id,
            "title": self.title,
            "path": self.path,
            "category": self.category,
            "file_type": self.file_type,
            "size_bytes": self.size_bytes,
            "modified_at": self.modified_at,
            "indexed_at": self.indexed_at,
            "excerpt": self.excerpt,
            "chunk_count": self.chunk_count,
            "tags": self.tags,
        }


def doc_id(path: str) -> str:
    """Stable opaque id for an indexed path.

    Opaque on purpose. The client never sends a filesystem path back to us, so
    `/documents/{id}/content` cannot be pointed at /etc/passwd no matter what
    is in the URL -- an id that isn't in the index simply doesn't resolve.
    Hashing also keeps directory names, which are often personal, out of URLs
    and therefore out of proxy and server logs.
    """
    return hashlib.sha256(path.encode("utf-8")).hexdigest()[:16]


def categorize(path: str) -> str:
    """Bucket a path into one of CATEGORIES by directory name.

    Only directory components are considered, never the filename: a file
    called "health insurance receipt.pdf" sitting in finances/ belongs to
    finances, and matching the leaf would move it on the strength of a word in
    its title.
    """
    parts = [p.lower() for p in Path(path).parts[:-1]]
    for part in parts:
        for hint, category in _HINT_INDEX:
            if hint in part:
                return category
    return DEFAULT_CATEGORY


def parse_fingerprint(fp: object) -> tuple[Optional[int], Optional[float]]:
    """Pull (size, mtime) out of the indexer's "size-mtime" fingerprint.

    Tolerates the legacy bare-string entries and anything malformed, because a
    library listing must not fail over one odd row written by an older build.
    """
    if not isinstance(fp, str) or "-" not in fp:
        return (None, None)
    size, _, mtime = fp.rpartition("-")
    try:
        return (int(size), float(mtime))
    except ValueError:
        return (None, None)


def _entry_meta(entry: object) -> tuple[Optional[int], Optional[float], Optional[float]]:
    """(size, mtime, indexed_at) from a state entry of either vintage."""
    if isinstance(entry, dict):
        size, mtime = parse_fingerprint(entry.get("fp"))
        indexed = entry.get("indexed_at")
        return (size, mtime, indexed if isinstance(indexed, (int, float)) else None)
    size, mtime = parse_fingerprint(entry)
    return (size, mtime, None)


def build(path: str, entry: object, excerpt: str = "",
          chunk_count: Optional[int] = None) -> Document:
    """Assemble a Document from one index_state.json row."""
    size, mtime, indexed = _entry_meta(entry)
    return Document(
        id=doc_id(path),
        title=Path(path).name,
        path=path,
        category=categorize(path),
        file_type=Path(path).suffix.lstrip(".").lower(),
        size_bytes=size,
        modified_at=mtime,
        indexed_at=indexed,
        excerpt=excerpt,
        chunk_count=chunk_count,
    )


def list_documents(state: Optional[dict] = None) -> list[Document]:
    """Every indexed document, newest first.

    Duplicates folded into a canonical copy are omitted, matching what
    `indexer.list_indexed_paths` reports -- the library should show the file
    once, not once per copy on disk.
    """
    if state is None:
        from indexer import _load_state  # local: keeps import cost off /health
        state = _load_state()

    docs = [
        build(path, entry)
        for path, entry in state.items()
        if not (isinstance(entry, dict) and entry.get("dup_of"))
    ]
    # Unknown mtimes sort last rather than crashing the comparison.
    docs.sort(key=lambda d: (d.modified_at is not None, d.modified_at or 0.0),
              reverse=True)
    return docs


def find(document_id: str, state: Optional[dict] = None) -> Optional[Document]:
    """Look up one document by opaque id, or None."""
    for doc in list_documents(state):
        if doc.id == document_id:
            return doc
    return None


def excerpt_of(text: str, limit: int = EXCERPT_CHARS) -> str:
    """First `limit` characters of a document, collapsed onto one line.

    Deliberately not an LLM summary: the library lists every indexed file, and
    summarising the whole vault on each load would cost minutes and a lot of
    tokens for something the user is only scanning.
    """
    flat = " ".join(text.split())
    if len(flat) <= limit:
        return flat
    return flat[:limit].rsplit(" ", 1)[0] + "…"


def is_previewable(file_type: str) -> bool:
    """Whether a native iOS preview exists for this type."""
    return file_type.lower() in {
        "pdf", "txt", "md", "markdown", "rtf",
        "png", "jpg", "jpeg", "heic", "gif",
        "mp4", "mov", "m4v",
    }


def content_type_for(file_type: str) -> str:
    """MIME type for the raw-content route, so iOS previews it natively."""
    return {
        "pdf": "application/pdf",
        "txt": "text/plain; charset=utf-8",
        "md": "text/markdown; charset=utf-8",
        "markdown": "text/markdown; charset=utf-8",
        "rtf": "application/rtf",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "heic": "image/heic",
        "gif": "image/gif",
        "mp4": "video/mp4",
        "mov": "video/quicktime",
        "m4v": "video/x-m4v",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    }.get(file_type.lower(), "application/octet-stream")


def matches(doc: Document, query: str = "", category: str = "") -> bool:
    """Filter predicate shared by the API and its tests.

    Case-insensitive substring over title and path. Search is done here rather
    than by the retrieval engine on purpose -- the user is looking for a file
    they already know exists, which is a different task from asking a question
    about its contents.
    """
    if category and category != "all" and doc.category != category:
        return False
    if query:
        needle = query.strip().lower()
        if needle and needle not in doc.title.lower() and needle not in doc.path.lower():
            return False
    return True


def filter_documents(docs: Iterable[Document], query: str = "",
                     category: str = "") -> list[Document]:
    return [d for d in docs if matches(d, query, category)]


def category_counts(docs: Iterable[Document]) -> dict[str, int]:
    """Per-category totals for the filter chips, including empty categories.

    Categories with no documents are still reported (as 0) so the filter row
    doesn't reflow as the vault changes.
    """
    counts = {name: 0 for name in CATEGORIES}
    for doc in docs:
        counts[doc.category] = counts.get(doc.category, 0) + 1
    return counts


def resolve_on_disk(doc: Document) -> Optional[Path]:
    """The document's real file, if it is still readable.

    Returns None when the file has moved or the container doesn't have that
    volume mounted -- callers fall back to the text reconstructed from the
    index, so a stale mount degrades the preview rather than 404ing.
    """
    candidate = Path(doc.path)
    try:
        if candidate.is_file():
            return candidate
    except OSError:
        return None
    return None


__all__ = [
    "CATEGORIES", "DEFAULT_CATEGORY", "Document", "build", "categorize",
    "category_counts", "content_type_for", "doc_id", "excerpt_of", "find",
    "filter_documents", "is_previewable", "list_documents", "matches",
    "parse_fingerprint", "resolve_on_disk",
]
