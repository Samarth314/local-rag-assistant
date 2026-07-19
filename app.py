from fastapi import FastAPI
from pydantic import BaseModel

import config
import store
from llm import chat, embed

app = FastAPI(title="Local RAG Assistant")

SYSTEM_PROMPT = (
    "You are a personal search assistant with access to the user's own files. "
    "You will be given retrieved excerpts and a question. Answer only from the "
    "excerpts provided."
)


class QueryRequest(BaseModel):
    query: str
    top_k: int = config.TOP_K


class Source(BaseModel):
    path: str
    chunk_index: int
    text: str
    score: float


class QueryResponse(BaseModel):
    response: str
    sources: list[Source]


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/query", response_model=QueryResponse)
def query(req: QueryRequest):
    if store.count_rows() == 0:
        return QueryResponse(
            response="No indexed content yet. Run the indexer on a directory first.",
            sources=[],
        )

    query_vector = embed(req.query)
    matches = store.search(query_vector, req.top_k)

    sources = [
        Source(
            path=m["path"],
            chunk_index=m["chunk_index"],
            text=m["text"],
            score=1 - m["_distance"],  # LanceDB returns L2 distance by default
        )
        for m in matches
    ]

    context_chunks = [f"[{s.path}]\n{s.text}" for s in sources]
    answer = chat(SYSTEM_PROMPT, context_chunks, req.query)

    return QueryResponse(response=answer, sources=sources)
