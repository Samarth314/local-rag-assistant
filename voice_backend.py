"""Wires the telephone front door to the local RAG stack.

This is the `answer_fn` the call state machine calls. Two decisions here are
driven by the phone medium rather than by taste, and both are deliberate
departures from how the CLI behaves:

  1. THE FAST TIER IS PINNED. Escalation to the thorough model is disabled
     outright. Measured on the Orin, the fast model answers in ~2.5s and the
     thorough one in 20-30s; past roughly three seconds of silence a caller
     assumes the line dropped. A slower, better answer is the wrong trade on a
     phone call.

  2. QUERY EXPANSION IS SKIPPED. Expansion costs ~6s on its own, which alone
     would blow the latency budget. The phone path embeds the raw question and
     accepts slightly weaker recall in exchange for staying conversational.

Retrieval, generation and formatting are injected, so the whole thing is
testable without Ollama, LanceDB or an index.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Callable, Optional, Protocol

from voice import Answer

logger = logging.getLogger("ataru.voice")

# Spoken answers must be short. This is enforced twice: once by instructing the
# model, and again by `to_speech()` truncating whatever comes back.
VOICE_SYSTEM_PROMPT = (
    "You are answering over a telephone call, out loud. Reply in at most two "
    "short sentences of plain spoken English. Never use markdown, bullet "
    "points, headings, or bracketed file paths -- they are unreadable aloud. "
    "Give the answer directly, with no preamble. If the excerpts do not "
    "contain the answer, say so in one sentence and stop."
)


class Retriever(Protocol):
    def __call__(self, question: str, top_k: int) -> list[dict]: ...


class Generator(Protocol):
    def __call__(self, system_prompt: str, context_chunks: list[str], question: str) -> str: ...


@dataclass
class VoiceBackend:
    """Builds an `answer_fn` for `CallSession`."""

    retrieve: Retriever
    generate: Generator
    top_k: int = 4  # fewer chunks than the CLI: less prefill, faster first word

    def answer(self, question: str, agent: Optional[str] = None) -> Answer:
        """Answer one spoken question. Never raises -- a phone call must always
        get something sayable back, even when the stack is broken."""
        try:
            matches = self.retrieve(question, self.top_k)
        except Exception as exc:  # noqa: BLE001 - the caller is on the line
            logger.warning("voice retrieval failed: %s", exc)
            return Answer(text="I couldn't reach your document index just now.",
                          source=None, agent=agent)

        if not matches:
            return Answer(text="I couldn't find anything about that in your files.",
                          source=None, agent=agent)

        chunks = [f"[{m.get('path', '')}]\n{m.get('text', '')}" for m in matches]
        try:
            text = self.generate(VOICE_SYSTEM_PROMPT, chunks, question)
        except Exception as exc:  # noqa: BLE001
            logger.warning("voice generation failed: %s", exc)
            return Answer(text="Something went wrong answering that. Try again.",
                          source=None, agent=agent)

        return Answer(text=text, source=top_source(matches), agent=agent)

    def as_callable(self) -> Callable[[str, Optional[str]], Answer]:
        return self.answer


def top_source(matches: list[dict]) -> Optional[str]:
    """The path of the best-scoring match, offered to the caller on keypress 9.

    Prefers the closest vector match; falls back to the first result when the
    store returned no distances (keyword-only hits).
    """
    if not matches:
        return None
    scored = [m for m in matches if m.get("_distance") is not None]
    if scored:
        best = min(scored, key=lambda m: m["_distance"])
        return best.get("path")
    return matches[0].get("path")


def build_inprocess_backend() -> VoiceBackend:
    """Wire the local stack directly, in this process.

    Only usable where lancedb/ollama/pyarrow are importable. Imported lazily so
    the call state machine and its tests never require them.
    """
    import config
    import store
    from llm import chat, embed

    def retrieve(question: str, top_k: int) -> list[dict]:
        # No query expansion: see the module docstring on the latency budget.
        vector = embed(question)
        return store.search([(vector, question)], top_k, rerank_query=question)

    def generate(system_prompt: str, context_chunks: list[str], question: str) -> str:
        return chat(
            system_prompt,
            context_chunks,
            question,
            stream=False,
            model=config.CHAT_MODEL,   # fast tier, pinned; never GOOD_MODEL
        )

    return VoiceBackend(retrieve=retrieve, generate=generate)


# --------------------------------------------------------------------------- #
# HTTP backend (the default for the Asterisk container)
# --------------------------------------------------------------------------- #

def parse_voice_response(payload: str) -> Answer:
    """Decode `/voice/answer`. Tolerates a missing source and odd shapes."""
    import json

    try:
        data = json.loads(payload)
    except json.JSONDecodeError:
        return Answer(text=payload.strip(), source=None)
    if not isinstance(data, dict):
        return Answer(text=str(data), source=None)
    return Answer(
        text=str(data.get("text") or data.get("response") or "").strip(),
        source=data.get("source"),
    )


@dataclass
class HttpVoiceBackend:
    """Calls the RAG service over HTTP instead of importing it.

    This is what the telephony container uses: Asterisk needs espeak and sox,
    not lancedb and torch, so the two images stay independent and the phone
    line can't wedge the index.
    """

    base_url: str
    timeout: float = 25.0

    def answer(self, question: str, agent: Optional[str] = None) -> Answer:
        import json
        import urllib.error
        import urllib.request

        body = json.dumps({"query": question, "agent": agent}).encode("utf-8")
        request = urllib.request.Request(
            self.base_url.rstrip("/") + "/voice/answer",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                answer = parse_voice_response(response.read().decode("utf-8", "replace"))
        except (urllib.error.URLError, OSError) as exc:
            logger.warning("voice backend unreachable: %s", exc)
            return Answer(text="I can't reach your document index right now.",
                          source=None, agent=agent)

        if not answer.text:
            return Answer(text="I couldn't find anything about that in your files.",
                          source=None, agent=agent)
        return Answer(text=answer.text, source=answer.source, agent=agent)

    def as_callable(self) -> Callable[[str, Optional[str]], Answer]:
        return self.answer


def build_default_backend():
    """Pick a backend from the environment.

    Prefers HTTP (`RAG_API_URL`), which is how the telephony container is wired.
    Falls back to importing the stack in-process for single-box deployments.
    """
    import os

    api_url = os.environ.get("RAG_API_URL")
    if api_url:
        return HttpVoiceBackend(base_url=api_url)
    return build_inprocess_backend()
