"""Speech in and out for the telephone front door.

Two jobs, both with a local-only default so the line works with no cloud
service and no API key:

  TTS  espeak-ng (offline, in-container) by default; a Kokoro-style HTTP
       endpoint can be pointed at instead via RAG_TTS_URL.
  STT  an HTTP endpoint (Parakeet/whisper-server) via RAG_STT_URL. When none is
       configured, speech input is simply unavailable and the caller stays on
       the keypad -- the line degrades, it does not break.

Telephony audio is 8 kHz mono 16-bit PCM. Everything here normalises to that,
because Asterisk will happily play a 22 kHz file at the wrong pitch otherwise.

The command builders are pure functions so they can be unit-tested without
espeak, sox or a running Asterisk.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

# Telephony line format. Do not change without changing the dialplan.
SAMPLE_RATE = 8000
CHANNELS = 1
BIT_DEPTH = 16

# What Piper's medium voices emit natively. Resampling to this is a no-op for
# Piper and an upsample for nothing else, so it is the right rate to serve to
# a phone speaker over the tailnet.
WIDEBAND_RATE = 22050


# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #

@dataclass(frozen=True)
class MediaConfig:
    """Where generated audio lives and which engines to use.

    TTS engine precedence: a remote endpoint if configured, else Piper if its
    model is present, else espeak-ng. Piper is the preferred local engine --
    it is a neural voice and sounds enormously better than espeak over a phone
    line, while still running offline on CPU.
    """
    sounds_dir: Path
    tts_url: Optional[str] = None      # remote TTS (Kokoro-style), optional
    stt_url: Optional[str] = None      # ASR endpoint (Parakeet), optional
    piper_model: Optional[Path] = None  # path to a Piper .onnx voice
    voice: str = "en-us"               # espeak voice, fallback engine only
    words_per_minute: int = 165
    timeout: float = 20.0
    # Output rate. 8 kHz is the *telephony* constraint, not a property of the
    # voice: over a phone line nothing above 4 kHz survives anyway. Clients
    # that play the audio directly (the iOS Shortcut) should ask for the
    # model's native rate instead -- see WIDEBAND_RATE.
    sample_rate: int = SAMPLE_RATE

    @staticmethod
    def from_env() -> "MediaConfig":
        model = os.environ.get("RAG_PIPER_MODEL") or None
        return MediaConfig(
            sounds_dir=Path(os.environ.get("RAG_VOICE_SOUNDS", "/var/lib/asterisk/sounds/ataru")),
            tts_url=os.environ.get("RAG_TTS_URL") or None,
            stt_url=os.environ.get("RAG_STT_URL") or None,
            piper_model=Path(model) if model else None,
            voice=os.environ.get("RAG_TTS_VOICE", "en-us"),
            words_per_minute=int(os.environ.get("RAG_TTS_WPM", "165")),
            sample_rate=int(os.environ.get("RAG_TTS_SAMPLE_RATE", str(SAMPLE_RATE))),
        )

    @property
    def speech_enabled(self) -> bool:
        """Speech input needs a transcriber; without one the line is keypad-only."""
        return bool(self.stt_url)

    @property
    def engine(self) -> str:
        """Which TTS engine will actually be used: 'remote', 'piper' or 'espeak'."""
        if self.tts_url:
            return "remote"
        if self.piper_model and self.piper_model.exists():
            return "piper"
        return "espeak"


# --------------------------------------------------------------------------- #
# Pure command builders (unit-tested without the binaries present)
# --------------------------------------------------------------------------- #

def espeak_command(text: str, out_path: Path, config: MediaConfig) -> list[str]:
    """espeak-ng writes a WAV; `-a 170` keeps it audible over a phone line."""
    return [
        "espeak-ng",
        "-v", config.voice,
        "-s", str(config.words_per_minute),
        "-a", "170",
        "-w", str(out_path),
        text,
    ]


def piper_command(model: Path, out_path: Path) -> list[str]:
    """Piper reads the text on stdin and writes a WAV.

    Piper emits at its model's native rate (usually 22.05 kHz), so the output
    still goes through `resample_command` before Asterisk sees it.
    """
    return [
        "piper",
        "--model", str(model),
        "--output_file", str(out_path),
    ]


def resample_command(src: Path, dst: Path, rate: int = SAMPLE_RATE) -> list[str]:
    """Normalise any WAV to mono 16-bit at `rate`.

    Defaults to the 8 kHz Asterisk expects; the HTTP `/voice/speak` path passes
    WIDEBAND_RATE so a phone speaker isn't fed telephone-grade audio.
    """
    return [
        "sox", str(src),
        "-r", str(rate),
        "-c", str(CHANNELS),
        "-b", str(BIT_DEPTH),
        str(dst),
    ]


def cache_key(text: str, config: MediaConfig) -> str:
    """Stable filename for a phrase, so fixed prompts are synthesised once.

    Keyed on the engine and voice settings too, so switching from espeak to
    Piper (or changing voice) invalidates the cache rather than replaying old
    audio in the wrong voice.
    """
    model = config.piper_model.name if config.piper_model else ""
    seed = (f"{config.engine}|{model}|{config.voice}|{config.words_per_minute}"
            f"|{config.sample_rate}|{text}")
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()[:24]


# --------------------------------------------------------------------------- #
# Text to speech
# --------------------------------------------------------------------------- #

class SynthesisError(RuntimeError):
    pass


def synthesize(text: str, config: MediaConfig) -> Path:
    """Render `text` to a mono WAV at `config.sample_rate` and return its path.

    Returns a path WITH the .wav extension. Asterisk's STREAM FILE wants the
    path WITHOUT it -- use `stream_name()`.
    """
    if not text.strip():
        raise SynthesisError("refusing to synthesise empty text")

    config.sounds_dir.mkdir(parents=True, exist_ok=True)
    final = config.sounds_dir / f"{cache_key(text, config)}.wav"
    if final.exists():
        return final  # fixed prompts (menu, PIN) are only ever rendered once

    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / "raw.wav"
        engine = config.engine
        if engine == "remote":
            _http_tts(text, raw, config)
        elif engine == "piper":
            # Piper takes the text on stdin, not as an argument.
            _run(piper_command(config.piper_model, raw),
                 timeout=config.timeout, stdin_text=text)
        else:
            _run(espeak_command(text, raw, config), timeout=config.timeout)

        # Piper emits ~22 kHz and remote engines often 24 kHz; the line is
        # 8 kHz. Without this the voice plays at the wrong pitch and speed.
        if shutil.which("sox"):
            _run(resample_command(raw, final, config.sample_rate),
                 timeout=config.timeout)
        else:
            shutil.copyfile(raw, final)
    return final


def _http_tts(text: str, out_path: Path, config: MediaConfig) -> None:
    """POST {"text": ...} and write back the returned audio bytes."""
    request = urllib.request.Request(
        config.tts_url,
        data=json.dumps({"text": text}).encode("utf-8"),
        headers={"Content-Type": "application/json", "Accept": "audio/wav"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=config.timeout) as response:
            out_path.write_bytes(response.read())
    except (urllib.error.URLError, OSError) as exc:
        raise SynthesisError(f"TTS endpoint unavailable: {exc}") from exc


def stream_name(path: Path) -> str:
    """Asterisk STREAM FILE takes a path with the extension stripped."""
    return str(path.with_suffix(""))


# --------------------------------------------------------------------------- #
# Speech to text
# --------------------------------------------------------------------------- #

class TranscriptionError(RuntimeError):
    pass


def transcribe(wav_path: Path, config: MediaConfig) -> str:
    """Send a recorded turn to the configured ASR endpoint.

    Accepts the two response shapes these servers usually return:
    `{"text": "..."}` and `{"results": [{"transcript": "..."}]}`.
    """
    if not config.stt_url:
        raise TranscriptionError("no ASR endpoint configured (RAG_STT_URL)")
    if not wav_path.exists():
        raise TranscriptionError(f"recording missing: {wav_path}")

    request = urllib.request.Request(
        config.stt_url,
        data=wav_path.read_bytes(),
        headers={"Content-Type": "audio/wav"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=config.timeout) as response:
            payload = response.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, OSError) as exc:
        raise TranscriptionError(f"ASR endpoint unavailable: {exc}") from exc

    return parse_transcript(payload)


def parse_transcript(payload: str) -> str:
    """Extract the transcript from a JSON (or bare text) ASR response."""
    payload = payload.strip()
    if not payload:
        return ""
    try:
        data = json.loads(payload)
    except json.JSONDecodeError:
        return payload  # some servers return plain text
    if isinstance(data, str):
        return data.strip()
    if isinstance(data, dict):
        if isinstance(data.get("text"), str):
            return data["text"].strip()
        results = data.get("results")
        if isinstance(results, list) and results:
            first = results[0]
            if isinstance(first, dict):
                for key in ("transcript", "text"):
                    if isinstance(first.get(key), str):
                        return first[key].strip()
    return ""


# --------------------------------------------------------------------------- #

def _run(command: list[str], timeout: float, stdin_text: Optional[str] = None) -> None:
    try:
        subprocess.run(
            command,
            check=True,
            capture_output=True,
            timeout=timeout,
            input=stdin_text.encode("utf-8") if stdin_text is not None else None,
        )
    except FileNotFoundError as exc:
        raise SynthesisError(f"{command[0]} is not installed in this image") from exc
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.decode("utf-8", errors="replace")[:200]
        raise SynthesisError(f"{command[0]} failed: {detail}") from exc
    except subprocess.TimeoutExpired as exc:
        raise SynthesisError(f"{command[0]} timed out") from exc
