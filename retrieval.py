"""Portable retrieval techniques (Item 3) -- graduation target for ATARU's
`ataru-search` MCP.

Dependency-light (stdlib only): every function operates on plain candidate
records -- dicts with at least `path`, `chunk_index`, `text`, and (for vector
hits) `_distance`. It does NOT touch any vector DB: the store supplies
candidates, this module ranks and selects them, so the same logic drops into
ataru-search (sqlite-vec) unchanged.

Interface / spec (query -> ranked results):
  - retrieval happens per query VARIANT (original + expansions); each variant
    yields a vector ranking and a keyword (BM25/FTS) ranking.
  - `rrf_fuse` merges all those rankings (reciprocal rank fusion) so a chunk
    ranked well by multiple signals rises to the top -- robust to the very
    different score scales of BM25 vs cosine.
  - `dedupe_by_text` drops near-identical chunks.
  - `select_top_k` is the naive baseline; `select_whole_collection` is the
    breadth path for "summarize/across everything" queries, guaranteeing every
    document is represented instead of top-k clustering in one or two.
  - `supports_escalation` is the distance-gated backstop signal.
  - `build_expansion_prompt` is the (model-agnostic) query-expansion prompt.
"""

from __future__ import annotations

import re

RRF_K = 60
DEFAULT_ESCALATE_DISTANCE = 0.4


# --------------------------------------------------------------------------- #
# Fusion + dedup
# --------------------------------------------------------------------------- #
def rrf_fuse(result_lists: list[list[dict]], k: int = RRF_K) -> list[dict]:
    """Reciprocal rank fusion: each hit scores 1/(k + rank) per list it appears
    in, so chunks ranked well by multiple signals rise. Returns rows ordered by
    fused score (highest first)."""
    scores: dict = {}
    hits: dict = {}
    for results in result_lists:
        for rank, row in enumerate(results):
            key = (row["path"], row["chunk_index"])
            scores[key] = scores.get(key, 0.0) + 1.0 / (k + rank + 1)
            hits.setdefault(key, row)
    ordered = sorted(scores, key=lambda key: (-scores[key], hits[key]["path"],
                                              hits[key]["chunk_index"]))
    return [hits[key] for key in ordered]


def dedupe_by_text(rows: list[dict], prefix: int = 400) -> list[dict]:
    """Drop chunks whose (whitespace/case-normalized) text duplicates a
    higher-ranked one -- near-identical files shouldn't fill several slots."""
    seen: set[str] = set()
    out = []
    for row in rows:
        key = " ".join(row["text"].split()).lower()[:prefix]
        if key not in seen:
            seen.add(key)
            out.append(row)
    return out


# --------------------------------------------------------------------------- #
# Selection: naive top-k vs whole-collection breadth
# --------------------------------------------------------------------------- #
def select_top_k(rows: list[dict], top_k: int) -> list[dict]:
    """Naive baseline: the best `top_k` fused chunks (may all be one document)."""
    return rows[:top_k]


def select_whole_collection(
    rows: list[dict], per_doc: int = 1, cap: int | None = None
) -> list[dict]:
    """Breadth path: at most `per_doc` best chunks per distinct document, in
    fused order. Guarantees every document is represented -- the fix for the
    top-k gap where "summarize every document" returns chunks clustered in one
    file and the model silently drops the rest."""
    taken: dict = {}
    out = []
    for row in rows:
        path = row.get("path")
        if taken.get(path, 0) < per_doc:
            taken[path] = taken.get(path, 0) + 1
            out.append(row)
            if cap is not None and len(out) >= cap:
                break
    return out


# --------------------------------------------------------------------------- #
# Breadth detection + escalation signal + expansion prompt
# --------------------------------------------------------------------------- #
_BREADTH = re.compile(
    r"(?i)(?:"
    r"\b(?:summariz|overview|rundown)\w*\b.{0,60}"
    r"\b(?:every|all|each|both|across|three)\b.{0,25}"
    r"\b(?:documents?|docs?|files?|notes?|records?|recipes?)\b"
    r"|\b(?:every|all|each|both)\b.{0,25}"
    r"\b(?:documents?|docs?|files?|notes?|records?|recipes?)\b.{0,40}"
    r"\b(?:paragraph|line|sentence|summary|one)\b"
    r"|\bacross (?:all|both|every)\b.{0,20}"
    r"\b(?:documents?|files?|recipes?|notes?)\b"
    r"|\b(?:whole|entire) (?:collection|vault|corpus|library)\b"
    r")"
)


def is_breadth_query(query: str) -> bool:
    """True if the query asks to summarize/compare ACROSS the whole collection
    (breadth), so the caller should use `select_whole_collection` not top-k."""
    return bool(_BREADTH.search(query))


def supports_escalation(
    matches: list[dict], threshold: float = DEFAULT_ESCALATE_DISTANCE
) -> bool:
    """True if at least one retrieved chunk is a strong semantic match (cosine
    distance <= threshold) -- the distance-gated escalation signal."""
    return any(
        m.get("_distance") is not None and m["_distance"] <= threshold
        for m in matches
    )


def build_expansion_prompt(question: str) -> str:
    """Model-agnostic query-expansion prompt: rewrite into alternative search
    queries to bridge vocabulary gaps (e.g. 'philosophy' -> 'PHIL338')."""
    return (
        "Rewrite the user's question into 2-3 short alternative search queries "
        "that improve document retrieval. Use different wording, likely "
        "synonyms, and any abbreviations or codes the source documents might "
        "use -- for example a university subject like 'philosophy' often "
        "appears only as a course code like 'PHIL338'. Output only the "
        "queries, one per line, no numbering or commentary.\n\n"
        f"Question: {question}"
    )
