"""Cross-encoder reranking.

Hybrid search embeds the query and each chunk *separately*, so a broad document
(e.g. a 500-chunk textbook) can land a chunk near almost any query on vocabulary
alone. A cross-encoder instead scores the (query, chunk) pair *together* and
judges whether the chunk actually answers the query -- so weak topical matches
get pushed out without removing anything from the index.

The same model runs on the Mac (MPS/CPU) and the Jetson (CUDA); torch picks the
device. Reranking is best-effort: if the model can't load, we return the input
order unchanged so retrieval still works.
"""

import config

_MODEL = None
_LOAD_FAILED = False


def _get_model():
    global _MODEL, _LOAD_FAILED
    if _MODEL is None and not _LOAD_FAILED:
        try:
            from sentence_transformers import CrossEncoder

            _MODEL = CrossEncoder(config.RERANK_MODEL)
        except Exception as e:
            _LOAD_FAILED = True
            print(f"  (rerank disabled: {e})")
    return _MODEL


def rerank(query: str, rows: list[dict], top_k: int) -> list[dict]:
    """Reorder `rows` by cross-encoder relevance to `query`, return the best
    `top_k`. Falls back to the existing order if the model is unavailable."""
    if not config.RERANK_ENABLED or len(rows) <= 1:
        return rows[:top_k]
    model = _get_model()
    if model is None:
        return rows[:top_k]

    pairs = [(query, row["text"]) for row in rows]
    scores = model.predict(pairs)
    ranked = sorted(zip(scores, rows), key=lambda sr: sr[0], reverse=True)
    return [row for _, row in ranked[:top_k]]
