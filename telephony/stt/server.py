"""NVIDIA Parakeet ASR as a tiny HTTP service.

Speaks the contract the telephony bridge already expects: POST a WAV body to
`/asr`, get back `{"text": "..."}`. That is the same shape `voice_media.transcribe`
parses, so pointing `RAG_STT_URL` here is the only wiring needed.

Parakeet is loaded once at startup and kept resident -- model load is many
seconds and a caller is on the line, so it must never happen per request.

Telephony audio arrives as 8 kHz mono. Parakeet expects 16 kHz, so every clip
is resampled before inference; skipping that step degrades accuracy badly
rather than failing outright, which makes it an easy bug to miss.
"""

from __future__ import annotations

import io
import logging
import os
import tempfile
import wave

from fastapi import FastAPI, Request
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("ataru.stt")

MODEL_NAME = os.environ.get("PARAKEET_MODEL", "nvidia/parakeet-tdt-0.6b-v2")
TARGET_RATE = 16_000

app = FastAPI(title="ATARU Parakeet ASR")
_model = None


class Transcript(BaseModel):
    text: str
    model: str


def _load_model():
    """Load Parakeet once. Imported lazily so the module can be inspected
    (and unit-tested) without NeMo installed."""
    global _model
    if _model is None:
        import nemo.collections.asr as nemo_asr
        logger.info("loading %s (this takes a while on first run)", MODEL_NAME)
        _model = nemo_asr.models.ASRModel.from_pretrained(model_name=MODEL_NAME)
        _model.eval()
        logger.info("model ready")
    return _model


@app.on_event("startup")
def warm() -> None:
    """Load at boot so the first caller doesn't pay for it."""
    try:
        _load_model()
    except Exception as exc:  # noqa: BLE001 - stay up and report per-request
        logger.error("model failed to load at startup: %s", exc)


def resample_to_16k(wav_bytes: bytes) -> bytes:
    """Resample an 8 kHz telephony WAV to the 16 kHz Parakeet expects.

    Uses numpy (already a NeMo dependency) rather than the stdlib `audioop`,
    which was REMOVED in Python 3.13 -- relying on it would quietly pin this
    service to an old interpreter.

    Assumes 16-bit PCM, which is what Asterisk records.
    """
    import numpy as np

    with wave.open(io.BytesIO(wav_bytes), "rb") as source:
        channels = source.getnchannels()
        width = source.getsampwidth()
        rate = source.getframerate()
        frames = source.readframes(source.getnframes())

    if width != 2:
        raise ValueError(f"expected 16-bit PCM, got {width * 8}-bit")

    samples = np.frombuffer(frames, dtype="<i2").astype(np.float32)
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)

    if rate != TARGET_RATE and samples.size:
        # Linear interpolation is sufficient for 8k->16k speech.
        target_len = int(round(samples.size * TARGET_RATE / rate))
        samples = np.interp(
            np.linspace(0, samples.size - 1, target_len, dtype=np.float64),
            np.arange(samples.size, dtype=np.float64),
            samples,
        )

    clipped = np.clip(samples, -32768, 32767).astype("<i2")

    out = io.BytesIO()
    with wave.open(out, "wb") as sink:
        sink.setnchannels(1)
        sink.setsampwidth(2)
        sink.setframerate(TARGET_RATE)
        sink.writeframes(clipped.tobytes())
    return out.getvalue()


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "model": MODEL_NAME, "loaded": _model is not None}


@app.post("/asr", response_model=Transcript)
async def asr(request: Request) -> Transcript:
    """Transcribe a posted WAV. Always returns 200 with a (possibly empty)
    transcript -- a caller is mid-call, so a 500 would just drop the turn."""
    body = await request.body()
    if not body:
        return Transcript(text="", model=MODEL_NAME)

    try:
        audio = resample_to_16k(body)
    except Exception as exc:  # noqa: BLE001
        logger.warning("could not decode posted audio: %s", exc)
        return Transcript(text="", model=MODEL_NAME)

    try:
        model = _load_model()
    except Exception as exc:  # noqa: BLE001
        logger.error("model unavailable: %s", exc)
        return Transcript(text="", model=MODEL_NAME)

    with tempfile.NamedTemporaryFile(suffix=".wav") as handle:
        handle.write(audio)
        handle.flush()
        try:
            results = model.transcribe([handle.name])
        except Exception as exc:  # noqa: BLE001
            logger.error("transcription failed: %s", exc)
            return Transcript(text="", model=MODEL_NAME)

    return Transcript(text=_first_text(results), model=MODEL_NAME)


def _first_text(results) -> str:
    """NeMo has returned plain strings, objects with `.text`, and nested lists
    across versions. Normalise all three rather than pinning a version."""
    if not results:
        return ""
    first = results[0]
    if isinstance(first, list):
        first = first[0] if first else ""
    if isinstance(first, str):
        return first.strip()
    return str(getattr(first, "text", "")).strip()
