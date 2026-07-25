import dataclasses

from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel

import config
import store
import voice_media
from llm import chat, embed
from voice import to_speech
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


@app.get("/voice/answer", response_model=VoiceResponse)
def voice_answer_get(q: str, agent: str | None = None, top_k: int = 4):
    """GET form of /voice/answer, for clients that can't easily POST JSON.

    Exists specifically for iOS Shortcuts: building a POST with a JSON body
    there means six separate settings and a variable token in the right box,
    which is error-prone. With this, the whole action is one URL plus one
    variable. Identical behaviour to the POST route.
    """
    return _voice_answer(VoiceRequest(query=q, agent=agent, top_k=top_k))


@app.post("/voice/answer", response_model=VoiceResponse)
def voice_answer(req: VoiceRequest):
    return _voice_answer(req)


# Spoken output is cached under the data volume, NOT the Asterisk sounds
# directory: this process runs as a non-root user in a different container and
# has no business writing there.
SPEECH_CACHE = config.DATA_DIR / "speech"


def _speech_config() -> voice_media.MediaConfig:
    """TTS settings for the HTTP path.

    Differs from the telephony config in one way that matters: the audio is
    served at the voice model's native rate rather than downsampled to 8 kHz.
    That downsample exists because a phone line cannot carry more; a phone
    *speaker* can, and 8 kHz through it sounds like a bad call for no reason.
    """
    return dataclasses.replace(
        voice_media.MediaConfig.from_env(),
        sounds_dir=SPEECH_CACHE,
        sample_rate=voice_media.WIDEBAND_RATE,
    )


@app.get("/voice/speak")
def voice_speak(q: str, agent: str | None = None, top_k: int = 4):
    """Answer `q` and return the answer as spoken WAV audio.

    For the iOS Shortcut: one action fetches this URL and one plays the result,
    so the voice matches the phone line exactly instead of being an iOS voice
    that merely resembles it. The text answer is also returned, in the
    `X-Ataru-Text` header, for clients that want to show it.
    """
    answer = _voice_answer(VoiceRequest(query=q, agent=agent, top_k=top_k))
    spoken = to_speech(answer.text)
    try:
        wav = voice_media.synthesize(spoken, _speech_config())
    except voice_media.SynthesisError as exc:
        # 503, not 500: the answer is fine, only the voice is unavailable
        # (no piper/espeak in this image). Callers can fall back to /voice/answer.
        raise HTTPException(status_code=503, detail=f"speech unavailable: {exc}")
    return Response(
        content=wav.read_bytes(),
        media_type="audio/wav",
        headers={
            # Header values must be latin-1 encodable and single-line.
            "X-Ataru-Text": spoken.encode("ascii", "replace").decode("ascii"),
            "X-Ataru-Source": (answer.source or "").encode("ascii", "replace").decode("ascii"),
        },
    )


def _voice_answer(req: VoiceRequest) -> VoiceResponse:
    """Answer shaped for being read aloud.

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
