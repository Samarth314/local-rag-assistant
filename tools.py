"""Tool definitions for the agent loop: JSON schemas Ollama uses for tool-calling,
the python functions that actually execute them, and a risk level per tool so the
orchestrator -- not the model -- decides what needs human confirmation."""

from pathlib import Path

import config
import store
from indexer import list_indexed_paths
from llm import embed, expand_query

NOTES_DIR = config.DATA_DIR / "agent_notes"

TOOL_SCHEMAS = [
    {
        "type": "function",
        "function": {
            "name": "search_documents",
            "description": "Semantic search over the user's indexed local documents. "
            "Returns the top matching excerpts with their source file paths.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "What to search for"},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_documents",
            "description": "List indexed document filenames, optionally filtered. "
            "Pass a 'filter' substring (e.g. 'resume', 'transcript', 'CMSC') to "
            "find a specific file's exact name -- much better than listing "
            "everything when the index is large. Omit filter only to browse; "
            "results are capped.",
            "parameters": {
                "type": "object",
                "properties": {
                    "filter": {
                        "type": "string",
                        "description": "Optional substring to match in filenames",
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_document",
            "description": "Read the FULL text of one specific document (not just "
            "matching excerpts). Use this instead of search_documents when the "
            "question is about a single named document as a whole -- e.g. "
            "summarizing it, or listing every item in it (all courses on a "
            "transcript, all points in a paper). Give a filename or a distinctive "
            "part of it; use list_documents first if unsure of the exact name.",
            "parameters": {
                "type": "object",
                "properties": {
                    "filename": {
                        "type": "string",
                        "description": "Filename or a distinctive part of it, "
                        "e.g. 'transcript' or 'autonomy'",
                    },
                },
                "required": ["filename"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_note",
            "description": "Save a text note to disk for the user. Writes only inside "
            "a sandboxed notes folder, never to arbitrary filesystem paths.",
            "parameters": {
                "type": "object",
                "properties": {
                    "filename": {
                        "type": "string",
                        "description": "Simple filename, e.g. 'summary.txt' -- no slashes",
                    },
                    "content": {"type": "string", "description": "The text to save"},
                },
                "required": ["filename", "content"],
            },
        },
    },
]

# Deterministic risk classification -- the orchestrator decides this, not the model.
RISK_LEVELS = {
    "search_documents": "low",
    "list_documents": "low",
    "read_document": "low",
    "write_note": "high",
}


def _search_documents(query: str) -> str:
    query_variants = [(embed(q), q) for q in expand_query(query)]
    matches = store.search(query_variants, config.TOP_K, rerank_query=query)
    if not matches:
        return "No relevant documents found."
    return "\n\n".join(f"[{m['path']}]\n{m['text']}" for m in matches)


def _list_documents(filter: str = "") -> str:
    paths = list_indexed_paths()
    if not paths:
        return "No documents indexed yet."
    if filter:
        needle = filter.lower()
        matched = [p for p in paths if needle in p.lower()]
        if not matched:
            return f"No indexed documents match '{filter}'."
        paths = matched
    total = len(paths)
    shown = paths[: config.LIST_DOCS_LIMIT]
    out = "\n".join(shown)
    if total > len(shown):
        out += (
            f"\n... ({total} documents match; showing {len(shown)}. "
            "Narrow with a more specific filter.)"
        )
    return out


def _read_document(filename: str) -> str:
    import re

    needle = filename.lower().strip()
    paths = list_indexed_paths()
    # First try the whole string as a substring; if nothing matches, fall back
    # to matching on individual words so "autonomy paper" still finds a file
    # named "...Autonomy in Mental Illness...", ranked by how many words hit.
    matches = [p for p in paths if needle in p.lower()]
    if not matches:
        # Drop generic words so a distinctive term drives the match (e.g.
        # "autonomy paper" should match on "autonomy", not "paper").
        generic = {"paper", "document", "file", "doc", "pdf", "the", "my", "notes"}
        words = [
            w for w in re.findall(r"\w+", needle)
            if len(w) > 2 and w not in generic
        ]
        scored = [
            (sum(w in p.lower() for w in words), p)
            for p in paths
            if words and any(w in p.lower() for w in words)
        ]
        best = max((s for s, _ in scored), default=0)
        matches = [p for s, p in scored if s == best] if best else []
    if not matches:
        return (
            f"No indexed document matches '{filename}'. Use list_documents to see "
            "the available files."
        )
    if len(matches) > 1:
        # Prefer an exact filename match; otherwise the shortest path (least
        # likely to be a near-duplicate copy with a longer decorated name).
        exact = [p for p in matches if Path(p).name.lower() == needle]
        chosen = exact[0] if exact else min(matches, key=len)
        others = [Path(p).name for p in matches if p != chosen]
        note = f"(Multiple documents matched; reading '{Path(chosen).name}'. Others: {', '.join(others)})\n\n"
    else:
        chosen = matches[0]
        note = ""

    text = store.get_document_text(chosen)
    if len(text) > config.READ_DOC_MAX_CHARS:
        text = (
            text[: config.READ_DOC_MAX_CHARS]
            + f"\n\n[...document truncated at {config.READ_DOC_MAX_CHARS} chars. "
            "For a document this large, use search_documents to find specific parts instead.]"
        )
    return f"{note}[{chosen}]\n{text}"


def _write_note(filename: str, content: str) -> str:
    safe_name = Path(filename).name  # strips any directory components
    if not safe_name or safe_name != filename or ".." in filename:
        return f"Rejected: '{filename}' is not a valid simple filename."
    NOTES_DIR.mkdir(parents=True, exist_ok=True)
    path = NOTES_DIR / safe_name
    path.write_text(content)
    return f"Saved to {path}"


TOOL_FUNCTIONS = {
    "search_documents": _search_documents,
    "list_documents": _list_documents,
    "read_document": _read_document,
    "write_note": _write_note,
}
