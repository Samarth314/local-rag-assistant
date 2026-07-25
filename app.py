from fastapi import FastAPI
from pydantic import BaseModel

import config
import store
from llm import chat, embed
from voice_backend import VOICE_SYSTEM_PROMPT, top_source

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


class VoiceRequest(BaseModel):
    """One spoken turn from the telephone front door."""
    query: str
    # Set when the caller pinned an agent from the keypad; advisory only.
    agent: str | None = None
    # Deliberately small: fewer chunks means less prefill and a faster first word.
    top_k: int = 4


class VoiceResponse(BaseModel):
    text: str
    source: str | None = None
    model: str


@app.get("/health")
def health():
    return {"status": "ok"}


def _retrieve(query: str, top_k: int) -> list[dict]:
    """Embed and search. `store.search` takes (vector, text) variant pairs."""
    vector = embed(query)
    return store.search([(vector, query)], top_k, rerank_query=query)


@app.post("/query", response_model=QueryResponse)
def query(req: QueryRequest):
    if store.count_rows() == 0:
        return QueryResponse(
            response="No indexed content yet. Run the indexer on a directory first.",
            sources=[],
        )

    matches = _retrieve(req.query, req.top_k)

    sources = [
        Source(
            path=m["path"],
            chunk_index=m["chunk_index"],
            text=m["text"],
            # Cosine distance -> similarity. Keyword-only hits carry no distance.
            score=1 - m["_distance"] if m.get("_distance") is not None else 0.0,
        )
        for m in matches
    ]

    context_chunks = [f"[{s.path}]\n{s.text}" for s in sources]
    answer = chat(SYSTEM_PROMPT, context_chunks, req.query)

    return QueryResponse(response=answer, sources=sources)


@app.post("/voice/answer", response_model=VoiceResponse)
def voice_answer(req: VoiceRequest):
    """Answer shaped for being read aloud on a phone call.

    Differs from /query in two ways that the medium forces (see voice_backend):
    the fast model is pinned so the caller isn't left in silence, and query
    expansion is skipped because it alone costs more than the latency budget.
    """
    if store.count_rows() == 0:
        return VoiceResponse(
            text="There's nothing indexed yet, so I have nothing to search.",
            source=None,
            model=config.CHAT_MODEL,
        )

    matches = _retrieve(req.query, req.top_k)
    if not matches:
        return VoiceResponse(
            text="I couldn't find anything about that in your files.",
            source=None,
            model=config.CHAT_MODEL,
        )

    context_chunks = [f"[{m['path']}]\n{m['text']}" for m in matches]
    answer = chat(
        VOICE_SYSTEM_PROMPT,
        context_chunks,
        req.query,
        stream=False,
        model=config.CHAT_MODEL,   # fast tier, pinned; never the thorough model
    )
    return VoiceResponse(text=answer, source=top_source(matches), model=config.CHAT_MODEL)
