"""Streaming voice sessions for the iOS app: text question in, spoken answer
out as it is being generated.

The blocking `/voice/speak` path serialises everything -- the caller waits for
retrieval, then the full generation, then the full synthesis, then the full
download, and only then hears sample one. This module overlaps all four: LLM
tokens stream off the engine, completed sentences peel off the stream, each
sentence is synthesised while later ones are still being written, and audio
frames go to the phone the moment the TTS engine emits them. Time-to-first-
audio becomes the cost of the first *sentence*, not the whole answer.

Wire protocol (one WebSocket, JSON text frames + binary audio frames):

  client -> server
    {"type": "ask", "q": "...", "topK": 4}

  server -> client, in order
    {"type": "accepted"}
    {"type": "delta", "text": "..."}          raw model text, for live display
    {"type": "audio_begin", "seq": 0, "sampleRate": 24000, "channels": 1,
     "encoding": "pcm_s16le", "text": "<the sentence being spoken>"}
    <binary frames: raw little-endian 16-bit PCM for the current seq>
    {"type": "audio_end", "seq": 0}
    ... more delta / audio_* interleaved ...
    {"type": "tts_unavailable"}               at most once; speak locally instead
    {"type": "done", "text": "<spoken text>", "source": "...", "model": "..."}
    {"type": "error", "message": "..."}

Binary frames always belong to the most recent `audio_begin`; WebSocket message
ordering makes that unambiguous. The session then waits for the next "ask", so
one connection serves a whole call.

Everything here is engine-agnostic and transport-testable: `run_session` talks
to a duck-typed socket (send_json / send_bytes / receive_json) so the tests
drive a whole session with no server, no models and no network.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import re
import struct
import threading
from dataclasses import dataclass, field
from typing import AsyncIterator, Awaitable, Callable, Iterator, Protocol

import voice
import voice_media

# How many sentences of an answer are spoken. Matches the blocking path's
# MAX_SPOKEN_SENTENCES by default; can be raised for streaming because the
# listener is no longer paying for the whole answer up front.
MAX_STREAM_SENTENCES = int(os.environ.get("RAG_VOICE_STREAM_MAX_SENTENCES",
                                          str(voice.MAX_SPOKEN_SENTENCES)))

# A run-on clause longer than this is flushed to the TTS engine at the last
# word break even without a sentence terminator, so a model that rambles
# without punctuation cannot stall the audio stream indefinitely.
MAX_UNTERMINATED_CHARS = 350

_SENTENCE_END = re.compile(r"(?<=[.!?])\s+")


# --------------------------------------------------------------------------- #
# Incremental sentence splitting
# --------------------------------------------------------------------------- #

class SentenceStream:
    """Feeds on text deltas, yields completed sentences ready for TTS.

    Sentences are detected on the raw model text and cleaned individually with
    the same shaping as the blocking path (markdown stripped, citations
    removed), minus the truncation -- truncation is the session's decision,
    not the splitter's. Cleaning can leave a sentence empty (a bare citation,
    a code fence); those are dropped.
    """

    def __init__(self) -> None:
        self._buffer = ""

    def feed(self, delta: str) -> list[str]:
        self._buffer += delta
        out: list[str] = []

        parts = _SENTENCE_END.split(self._buffer)
        # The last part is either an unfinished sentence or empty; keep it.
        self._buffer = parts.pop()
        out.extend(parts)

        while len(self._buffer) > MAX_UNTERMINATED_CHARS:
            head, sep, _ = self._buffer[:MAX_UNTERMINATED_CHARS].rpartition(" ")
            if not sep:
                break  # one unbroken 350-char token; leave it for flush()
            out.append(head)
            self._buffer = self._buffer[len(head) + 1:]

        return [c for c in (self._clean(s) for s in out) if c]

    def flush(self) -> list[str]:
        rest, self._buffer = self._buffer, ""
        cleaned = self._clean(rest)
        return [cleaned] if cleaned else []

    @staticmethod
    def _clean(sentence: str) -> str:
        # to_speech with the limits effectively off = shaping without cutting.
        cleaned = voice.to_speech(sentence, max_sentences=10_000, max_chars=100_000)
        # Cleaning can reduce a "sentence" to bare punctuation (a stripped
        # citation leaves its full stop behind). Nothing pronounceable, drop it.
        return cleaned if re.search(r"\w", cleaned) else ""


# --------------------------------------------------------------------------- #
# WAV in, PCM out
# --------------------------------------------------------------------------- #

@dataclass
class WavStreamParser:
    """Strips the RIFF header off a streamed WAV and reports its format.

    TTS engines answer with a WAV file; the phone schedules raw PCM buffers.
    Parsing the header server-side means the client never needs to understand
    containers -- it is told the rate once and then receives bare samples.
    """

    sample_rate: int | None = None
    channels: int | None = None
    _header: bytes = b""
    _in_data: bool = False

    def feed(self, chunk: bytes) -> bytes:
        if self._in_data:
            return chunk

        self._header += chunk
        if len(self._header) < 12 or self._header[:4] != b"RIFF":
            if len(self._header) >= 4 and self._header[:4] != b"RIFF":
                raise ValueError("not a RIFF stream")
            return b""

        # Walk chunks: [4 id][4 size][payload], WAVE form at offset 8.
        pos = 12
        while pos + 8 <= len(self._header):
            cid = self._header[pos:pos + 4]
            size = struct.unpack_from("<I", self._header, pos + 4)[0]
            if cid == b"fmt " and pos + 8 + 16 <= len(self._header):
                _, self.channels, self.sample_rate = struct.unpack_from(
                    "<HHI", self._header, pos + 8)
            if cid == b"data":
                self._in_data = True
                return self._header[pos + 8:]
            pos += 8 + size + (size & 1)
        return b""


# --------------------------------------------------------------------------- #
# The pieces a session needs, injected so tests can fake all of them
# --------------------------------------------------------------------------- #

class SessionSocket(Protocol):
    async def send_json(self, payload: dict) -> None: ...
    async def send_bytes(self, data: bytes) -> None: ...
    async def receive_json(self) -> dict: ...


@dataclass
class SessionDeps:
    """Everything `run_session` touches outside its own logic."""

    answer_stream: Callable[[str, int], "AnswerStream"]
    synthesize_stream: Callable[[str], AsyncIterator[bytes]] | None
    synthesize_file: Callable[[str], bytes] | None
    max_sentences: int = MAX_STREAM_SENTENCES


@dataclass
class AnswerStream:
    """A started answer: token iterator plus the metadata known up front."""

    tokens: Iterator[str]
    source: str | None
    model: str
    # Set for canned replies (nothing indexed / nothing found) that should be
    # spoken as-is without consulting the token iterator.
    canned: str | None = None


# --------------------------------------------------------------------------- #
# Session loop
# --------------------------------------------------------------------------- #

async def run_session(ws: SessionSocket, deps: SessionDeps) -> None:
    """Serve one WebSocket connection until the client goes away.

    Any exception from the socket (disconnect, protocol violation) propagates
    to the caller; errors in answering are reported in-band so a hiccup on one
    question does not tear down the call.
    """
    while True:
        request = await ws.receive_json()
        if request.get("type") != "ask":
            await ws.send_json({"type": "error",
                                "message": f"unexpected message type "
                                           f"{request.get('type')!r}"})
            continue

        question = (request.get("q") or "").strip()
        if not question:
            await ws.send_json({"type": "error", "message": "empty question"})
            continue

        await ws.send_json({"type": "accepted"})
        try:
            await _answer_one(ws, deps, question, int(request.get("topK") or 4))
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 -- reported to the caller
            await ws.send_json({"type": "error", "message": str(exc)})


async def _answer_one(ws: SessionSocket, deps: SessionDeps,
                      question: str, top_k: int) -> None:
    loop = asyncio.get_running_loop()
    answer = await loop.run_in_executor(None, deps.answer_stream, question, top_k)

    speaker = _Speaker(ws, deps)

    if answer.canned is not None:
        await ws.send_json({"type": "delta", "text": answer.canned})
        await speaker.speak(answer.canned)
        await speaker.finish(answer.canned, answer.source, answer.model)
        return

    splitter = SentenceStream()
    spoken: list[str] = []
    stop_generation = threading.Event()
    queue: asyncio.Queue[str | None] = asyncio.Queue()

    def _pump() -> None:
        """Drains the blocking token iterator onto the loop's queue."""
        try:
            for piece in answer.tokens:
                if stop_generation.is_set():
                    break
                loop.call_soon_threadsafe(queue.put_nowait, piece)
        finally:
            loop.call_soon_threadsafe(queue.put_nowait, None)

    pump = threading.Thread(target=_pump, name="voice-stream-llm", daemon=True)
    pump.start()

    try:
        while (piece := await queue.get()) is not None:
            await ws.send_json({"type": "delta", "text": piece})
            for sentence in splitter.feed(piece):
                if len(spoken) < deps.max_sentences:
                    spoken.append(sentence)
                    await speaker.speak(sentence)
                if len(spoken) >= deps.max_sentences:
                    # Enough is spoken; stop paying for tokens nobody hears.
                    stop_generation.set()

        if len(spoken) < deps.max_sentences:
            for sentence in splitter.flush():
                spoken.append(sentence)
                await speaker.speak(sentence)
    finally:
        stop_generation.set()

    await speaker.finish(" ".join(spoken), answer.source, answer.model)


class _Speaker:
    """Sends one sentence's audio over the socket, tolerating a dead engine.

    TTS failing mid-call downgrades the experience (the phone falls back to
    its local voice), it must never end the call -- so the first failure sends
    `tts_unavailable` and every later sentence is text-only.
    """

    def __init__(self, ws: SessionSocket, deps: SessionDeps) -> None:
        self._ws = ws
        self._deps = deps
        self._seq = 0
        self._tts_dead = deps.synthesize_stream is None and deps.synthesize_file is None
        self._announced_dead = False

    async def speak(self, sentence: str) -> None:
        if self._tts_dead:
            await self._announce_dead()
            return
        try:
            if self._deps.synthesize_stream is not None:
                await self._speak_streaming(sentence)
            else:
                await self._speak_file(sentence)
        except Exception:  # noqa: BLE001 -- degrade, never drop the call
            self._tts_dead = True
            await self._announce_dead()

    async def finish(self, text: str, source: str | None, model: str) -> None:
        await self._ws.send_json({"type": "done", "text": text,
                                  "source": source or "", "model": model})

    async def _announce_dead(self) -> None:
        if not self._announced_dead:
            self._announced_dead = True
            await self._ws.send_json({"type": "tts_unavailable"})

    async def _speak_streaming(self, sentence: str) -> None:
        parser = WavStreamParser()
        began = False
        async for chunk in self._deps.synthesize_stream(sentence):
            pcm = parser.feed(chunk)
            if not pcm:
                continue
            if not began:
                began = True
                await self._begin(parser, sentence)
            await self._ws.send_bytes(pcm)
        if began:
            await self._end()
        else:
            raise voice_media.SynthesisError("TTS returned no audio")

    async def _speak_file(self, sentence: str) -> None:
        loop = asyncio.get_running_loop()
        wav = await loop.run_in_executor(None, self._deps.synthesize_file, sentence)
        parser = WavStreamParser()
        pcm = parser.feed(wav)
        if not pcm:
            raise voice_media.SynthesisError("TTS returned no audio")
        await self._begin(parser, sentence)
        # One sentence is a few seconds of audio; frame it so the client can
        # start scheduling before the last byte arrives at the socket layer.
        for i in range(0, len(pcm), 16384):
            await self._ws.send_bytes(pcm[i:i + 16384])
        await self._end()

    async def _begin(self, parser: WavStreamParser, sentence: str) -> None:
        await self._ws.send_json({
            "type": "audio_begin", "seq": self._seq,
            "sampleRate": parser.sample_rate or voice_media.WIDEBAND_RATE,
            "channels": parser.channels or 1,
            "encoding": "pcm_s16le",
            "text": sentence,
        })

    async def _end(self) -> None:
        await self._ws.send_json({"type": "audio_end", "seq": self._seq})
        self._seq += 1


# --------------------------------------------------------------------------- #
# Production wiring
# --------------------------------------------------------------------------- #

def http_tts_stream(tts_url: str, timeout: float) -> Callable[[str], AsyncIterator[bytes]]:
    """A `synthesize_stream` backed by a Kokoro-style POST {"text": ...} -> WAV
    endpoint, forwarding response bytes as the engine emits them."""
    import httpx

    async def synth(sentence: str) -> AsyncIterator[bytes]:
        async with httpx.AsyncClient(timeout=timeout) as client:
            async with client.stream(
                "POST", tts_url,
                json={"text": sentence},
                headers={"Accept": "audio/wav"},
            ) as response:
                response.raise_for_status()
                async for chunk in response.aiter_bytes():
                    yield chunk

    return synth


def local_tts_file(speech_config: voice_media.MediaConfig) -> Callable[[str], bytes]:
    """A `synthesize_file` backed by the local engine (Piper/espeak), reusing
    the blocking path's cache so repeated phrases cost one synthesis ever."""

    def synth(sentence: str) -> bytes:
        return voice_media.synthesize(sentence, speech_config).read_bytes()

    return synth
