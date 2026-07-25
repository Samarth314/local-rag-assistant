"""Incremental filesystem indexer.

Walks a directory, compares each file's (size, mtime) fingerprint against the
last known state, and only re-chunks/re-embeds files that are new or changed.
Removed files have their chunks deleted from the vector store.
"""

import hashlib
import json
import os
import time
import uuid
from pathlib import Path

import config
import store
from chunker import chunk_text
from extractors import extract_text
from llm import embed


def _load_state() -> dict:
    if config.STATE_FILE.exists():
        return json.loads(config.STATE_FILE.read_text())
    return {}


def _save_state(state: dict) -> None:
    config.DATA_DIR.mkdir(parents=True, exist_ok=True)
    config.STATE_FILE.write_text(json.dumps(state, indent=2))


def _walk(root: Path):
    for dirpath, dirnames, filenames in os.walk(root):
        if ".git" in dirnames:
            # This directory is a git repo root (someone's cloned project, not a
            # personal document) -- skip its contents and don't descend into it.
            dirnames[:] = []
            continue
        dirnames[:] = [
            d for d in dirnames
            if d not in config.EXCLUDED_DIRS
            and not d.startswith(".")
            # Never index our own database/state -- it changes every run and
            # would put the index in a feedback loop with itself.
            and (Path(dirpath) / d) != config.DATA_DIR
        ]
        for name in filenames:
            path = Path(dirpath) / name
            if name in config.EXCLUDED_FILES:
                continue
            if path.suffix.lower() in config.SUPPORTED_EXTENSIONS:
                yield path


def _fingerprint(path: Path) -> str:
    stat = path.stat()
    return f"{stat.st_size}-{int(stat.st_mtime)}"


def _fp_of(entry) -> str:
    # State entries are dicts now; tolerate the old bare-string format so a
    # stale state file just triggers a re-index rather than crashing.
    return entry["fp"] if isinstance(entry, dict) else entry


def _content_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "ignore")).hexdigest()


def list_indexed_paths() -> list[str]:
    """Return every distinct document in the index (enumeration, not search).

    Files detected as byte-for-byte content duplicates are folded into their
    canonical copy and omitted here."""
    state = _load_state()
    return sorted(
        p for p, meta in state.items()
        if not (isinstance(meta, dict) and meta.get("dup_of"))
    )


def index_directory(root: str, limit: int | None = None) -> dict:
    """Walk `root` and index new/changed files.

    State is saved after every file (not just at the end) so a Ctrl+C mid-run
    only loses the file currently in flight -- re-running picks up where it
    left off instead of redoing everything already processed.

    `limit`, if set, caps how many changed files are processed this run --
    useful for a quick smoke test on a large tree before committing to a full
    index.
    """
    root_path = Path(root).expanduser().resolve()
    state = _load_state()

    current_paths = {}
    for path in _walk(root_path):
        try:
            size = path.stat().st_size
        except OSError:
            continue
        if size > config.MAX_FILE_SIZE_BYTES:
            continue
        if path.suffix.lower() in config.PLAINTEXT_EXTENSIONS and size > config.MAX_TEXT_FILE_BYTES:
            continue
        current_paths[str(path)] = _fingerprint(path)

    changed = [p for p, fp in current_paths.items() if _fp_of(state.get(p)) != fp]
    # Prune files that vanished from disk OR no longer qualify (e.g. an
    # extension we've stopped supporting) -- but only within this root, so
    # indexing one folder never evicts documents indexed from another.
    removed = [
        p for p in state
        if p not in current_paths and Path(p).is_relative_to(root_path)
    ]

    for path_str in removed:
        store.delete_by_path(path_str)
        del state[path_str]
    if removed:
        _save_state(state)

    if limit is not None:
        changed = changed[:limit]

    # Map content hash -> canonical path, seeded from files already indexed
    # (non-duplicates still present on disk) so a duplicate is recognized even
    # when its original was indexed on a previous run.
    hash_to_path = {
        meta["hash"]: p
        for p, meta in state.items()
        if isinstance(meta, dict) and meta.get("hash") and not meta.get("dup_of")
        and p in current_paths and p not in changed
    }

    indexed_count = 0
    duplicate_count = 0
    error_count = 0
    try:
        for path_str in changed:
            path = Path(path_str)
            try:
                text = extract_text(path)
            except Exception as e:
                print(f"  skip (extract failed): {path} ({e})")
                error_count += 1
                continue

            if not text.strip():
                state[path_str] = {"fp": current_paths[path_str], "hash": None,
                                   "indexed_at": time.time()}
                _save_state(state)
                continue

            content_hash = _content_hash(text)
            canonical = hash_to_path.get(content_hash)
            if canonical and canonical != path_str:
                # Byte-for-byte duplicate of an already-indexed file: don't add
                # its chunks (they'd crowd out distinct docs at query time).
                store.delete_by_path(path_str)
                state[path_str] = {
                    "fp": current_paths[path_str],
                    "hash": content_hash,
                    "dup_of": canonical,
                    "indexed_at": time.time(),
                }
                _save_state(state)
                duplicate_count += 1
                print(f"  skip (duplicate of {Path(canonical).name})")
                continue
            hash_to_path[content_hash] = path_str

            store.delete_by_path(path_str)  # clear any stale chunks before re-adding
            chunks = chunk_text(text, config.CHUNK_SIZE_WORDS, config.CHUNK_OVERLAP_WORDS)

            rows = []
            for i, chunk in enumerate(chunks):
                # Embed filename + content so queries can match a document by
                # its name (e.g. "CMSC351_Summer_2024"), not just its text.
                search_text = f"File: {path.name}\n{chunk}"
                try:
                    vector = embed(search_text)
                except Exception as e:
                    print(f"  skip chunk (embed failed): {path} [{i}] ({e})")
                    continue
                rows.append(
                    {
                        "id": str(uuid.uuid4()),
                        "text": chunk,
                        "search_text": search_text,
                        "path": path_str,
                        "chunk_index": i,
                        "vector": vector,
                    }
                )

            store.add_chunks(rows)
            # indexed_at drives the document library's "ingested" column. State
            # entries written before this existed simply report null.
            state[path_str] = {"fp": current_paths[path_str], "hash": content_hash,
                               "indexed_at": time.time()}
            _save_state(state)
            indexed_count += 1
            print(f"  indexed: {path} ({len(rows)} chunks)")
    except KeyboardInterrupt:
        print(f"\nInterrupted -- progress up to this point is saved. "
              f"Re-run the same command to continue.")

    if indexed_count or removed:
        store.rebuild_fts_index()

    return {
        "scanned": len(current_paths),
        "indexed": indexed_count,
        "duplicates": duplicate_count,
        "removed": len(removed),
        "errors": error_count,
    }
