"""LanceDB-backed store for text chunks: vector search + full-text keyword
search, fused with reciprocal rank fusion (RRF) for hybrid retrieval."""

import lancedb
import pyarrow as pa

import config


def _schema() -> pa.Schema:
    return pa.schema(
        [
            pa.field("id", pa.string()),
            pa.field("text", pa.string()),
            # Filename + chunk text: what gets embedded and keyword-indexed,
            # so queries can match on the file's name, not just its contents.
            pa.field("search_text", pa.string()),
            pa.field("path", pa.string()),
            pa.field("chunk_index", pa.int32()),
            pa.field("vector", pa.list_(pa.float32(), config.EMBED_DIM)),
        ]
    )


def get_table():
    config.DATA_DIR.mkdir(parents=True, exist_ok=True)
    db = lancedb.connect(config.DB_PATH)
    if config.CHUNKS_TABLE in db.table_names():
        return db.open_table(config.CHUNKS_TABLE)
    return db.create_table(config.CHUNKS_TABLE, schema=_schema())


def add_chunks(rows: list[dict]) -> None:
    if not rows:
        return
    get_table().add(rows)


def delete_by_path(path: str) -> None:
    escaped = path.replace("'", "''")
    get_table().delete(f"path = '{escaped}'")


def count_rows() -> int:
    return get_table().count_rows()


def get_document_text(path: str) -> str:
    """Reconstruct a document's full text from its stored chunks, in order.
    No re-embedding or disk read -- just concatenates what's already indexed."""
    table = get_table()
    escaped = path.replace("'", "''")
    rows = table.search().where(f"path = '{escaped}'").limit(100000).to_list()
    rows.sort(key=lambda r: r["chunk_index"])
    return "\n\n".join(r["text"] for r in rows)


def rebuild_fts_index() -> None:
    table = get_table()
    if table.count_rows() > 0:
        table.create_fts_index("search_text", replace=True)


def search(
    query_variants: list[tuple[list[float], str]],
    top_k: int,
    rerank_query: str | None = None,
    whole_collection: bool = False,
) -> list[dict]:
    """Hybrid search over one or more query variants (each an embedded-vector +
    text pair, e.g. from query expansion). Every variant contributes a vector
    ranking and a keyword ranking; all rankings are fused together with RRF so
    a chunk that any variant finds well rises to the top.

    A wide candidate pool is fused and deduped, then a cross-encoder reranks it
    against `rerank_query` (the user's original question) and the true top_k is
    returned. `rerank_query` defaults to the first variant's text."""
    table = get_table()
    if table.count_rows() == 0:
        return []
    candidates = max(config.RERANK_CANDIDATES, top_k * 4, 20)

    result_lists = []
    for vector, text in query_variants:
        vector_hits = (
            table.search(vector).distance_type("cosine").limit(candidates).to_list()
        )
        result_lists.append(
            [r for r in vector_hits if r["_distance"] <= config.MAX_DISTANCE]
        )
        try:
            result_lists.append(
                table.search(text, query_type="fts").limit(candidates).to_list()
            )
        except Exception:
            # No FTS index yet (e.g. mid-migration) -- vector ranking still counts.
            pass

    import retrieval
    fused = retrieval.dedupe_by_text(retrieval.rrf_fuse(result_lists))

    # Breadth queries ("summarize every document") need one chunk per document,
    # not top-k clustered in one file. Skip the reranker (which optimizes for a
    # single best answer) and guarantee whole-collection coverage instead.
    if whole_collection:
        return retrieval.select_whole_collection(fused, per_doc=1)

    import rerank
    if rerank_query is None and query_variants:
        rerank_query = query_variants[0][1]
    return rerank.rerank(rerank_query, fused[:candidates], top_k)
