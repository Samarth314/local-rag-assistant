#!/usr/bin/env python3
"""Asterisk AGI bridge: turns a live SIP call into `CallSession` events.

Asterisk executes this script per call and speaks a line protocol over
stdin/stdout. This module implements just enough of AGI to answer, play audio,
collect DTMF and record a spoken turn -- then hands each event to the
provider-agnostic state machine in `voice.py`.

The protocol layer takes its streams by injection, so the parsing and command
formatting are unit-tested with no Asterisk anywhere.

Dialplan side (see telephony/extensions.conf):

    exten => 100,1,Answer()
     same  =>     n,AGI(/opt/ataru/voice_agi.py)
     same  =>     n,Hangup()
"""

from __future__ import annotations

import logging
import os
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import IO, Optional

from voice import CallSession, Expect, VoiceTurn
from voice_media import (MediaConfig, SynthesisError, TranscriptionError,
                         stream_name, synthesize, transcribe)

logger = logging.getLogger("ataru.agi")

# How long to wait for the caller to key something, and to speak.
DTMF_TIMEOUT_MS = 8000
RECORD_TIMEOUT_MS = 12000
# Asterisk ends a RECORD FILE after this much silence (seconds).
RECORD_SILENCE_S = 2
# Digits that interrupt playback so the caller can barge in.
BARGE_DIGITS = "0123456789#*"

_RESULT = re.compile(r"result=(-?\d+)")
# GET DATA reports the literal digits keyed, which must be read as a string:
# reading it as an int would turn a lone "0" (our menu key) into "no input".
_RESULT_RAW = re.compile(r"result=([0-9*#]*)")


# --------------------------------------------------------------------------- #
# AGI protocol
# --------------------------------------------------------------------------- #

def parse_agi_environment(lines: list[str]) -> dict[str, str]:
    """Parse the `agi_x: value` block Asterisk sends when the script starts."""
    env: dict[str, str] = {}
    for line in lines:
        line = line.strip()
        if not line:
            break
        if ":" in line:
            key, _, value = line.partition(":")
            env[key.strip()] = value.strip()
    return env


def parse_result(response: str) -> int:
    """Pull the integer out of `200 result=1`. Returns -1 when absent."""
    match = _RESULT.search(response or "")
    return int(match.group(1)) if match else -1


def parse_get_data(response: str) -> str:
    """GET DATA reports the digits the caller keyed, as a literal string.

    Must not be parsed as an integer: `result=0` means the caller pressed the
    `0` key (our menu key), not "nothing". An empty `result=` means no input.
    """
    match = _RESULT_RAW.search(response or "")
    if not match:
        return ""
    digits = match.group(1)
    # `-1` signals a hangup/channel failure; treat as no input.
    return "" if digits in ("", "-1") else digits


@dataclass
class AGIChannel:
    """Line protocol over the streams Asterisk gave us."""

    stdin: IO[str]
    stdout: IO[str]
    env: dict[str, str]

    @classmethod
    def connect(cls, stdin: IO[str] = sys.stdin, stdout: IO[str] = sys.stdout) -> "AGIChannel":
        lines: list[str] = []
        while True:
            line = stdin.readline()
            if not line or not line.strip():
                break
            lines.append(line)
        return cls(stdin=stdin, stdout=stdout, env=parse_agi_environment(lines))

    def command(self, text: str) -> str:
        self.stdout.write(text + "\n")
        self.stdout.flush()
        return self.stdin.readline()

    # -- primitives ---------------------------------------------------- #

    def answer(self) -> None:
        self.command("ANSWER")

    def verbose(self, message: str) -> None:
        safe = message.replace('"', "'")[:180]
        self.command(f'VERBOSE "{safe}" 1')

    def hangup(self) -> None:
        self.command("HANGUP")

    def stream(self, audio_no_ext: str, escape_digits: str = BARGE_DIGITS) -> str:
        """Play a file. Returns the digit that interrupted it, or ""."""
        response = self.command(f'STREAM FILE {audio_no_ext} "{escape_digits}"')
        value = parse_result(response)
        return chr(value) if value > 0 else ""

    def get_data(self, audio_no_ext: str, timeout_ms: int, max_digits: int) -> str:
        """Play a prompt and collect DTMF."""
        response = self.command(f"GET DATA {audio_no_ext} {timeout_ms} {max_digits}")
        return parse_get_data(response)

    def record(self, path_no_ext: str, timeout_ms: int) -> None:
        """Record the caller until silence or timeout. '#' also ends it."""
        self.command(
            f"RECORD FILE {path_no_ext} wav '#' {timeout_ms} 0 s={RECORD_SILENCE_S}"
        )

    @property
    def caller_id(self) -> str:
        return self.env.get("agi_callerid", "unknown")


# --------------------------------------------------------------------------- #
# Call driver
# --------------------------------------------------------------------------- #

class CallRunner:
    """Plays turns and feeds caller input back into the state machine."""

    def __init__(self, channel: AGIChannel, session: CallSession, media: MediaConfig):
        self.channel = channel
        self.session = session
        self.media = media
        self.workdir = Path(tempfile.mkdtemp(prefix="ataru-call-"))

    def run(self) -> None:
        self.channel.answer()
        self.channel.verbose(f"ATARU call from {self.channel.caller_id}")
        turn = self.session.begin()

        # A call is a short interaction; the cap stops a wedged loop from
        # holding the channel open indefinitely.
        for _ in range(40):
            digit = self._play(turn)
            if turn.end_call:
                break

            if turn.expect is Expect.DTMF:
                turn = self.session.handle_dtmf(self._entry(turn, digit))
            elif turn.expect is Expect.SPEECH:
                # A keypress during an answer means the caller wants the menu,
                # not to talk -- honour it instead of recording silence.
                if digit:
                    turn = self.session.handle_dtmf(digit)
                elif self.media.speech_enabled:
                    turn = self.session.handle_speech(self._collect_speech())
                else:
                    turn = self.session.handle_dtmf("0")
            else:
                break

        self.channel.hangup()

    # -- helpers -------------------------------------------------------- #

    def _play(self, turn: VoiceTurn) -> str:
        """Speak a turn. Returns a barge-in digit if the caller interrupted."""
        try:
            audio = synthesize(turn.speak, self.media)
        except SynthesisError as exc:
            logger.error("synthesis failed: %s", exc)
            self.channel.verbose(f"TTS failed: {exc}")
            return ""
        return self.channel.stream(stream_name(audio))

    def _entry(self, turn: VoiceTurn, barge_digit: str) -> str:
        """Assemble a full DTMF entry, honouring a mid-prompt barge-in.

        Callers key their access code over the greeting. STREAM FILE returns
        only the digit that interrupted playback, so for a multi-digit entry we
        must keep collecting the rest instead of treating that first digit as
        the whole code.
        """
        if not barge_digit:
            return self._collect_dtmf(turn.digits)
        if turn.digits <= 1:
            return barge_digit
        return barge_digit + self._collect_dtmf(turn.digits - 1)

    def _collect_dtmf(self, max_digits: int) -> str:
        """Collect digits after the prompt already played (silent re-prompt)."""
        silence = self.media.sounds_dir / "silence"
        return self.channel.get_data(str(silence), DTMF_TIMEOUT_MS, max_digits)

    def _collect_speech(self) -> str:
        target = self.workdir / "turn"
        self.channel.record(str(target), RECORD_TIMEOUT_MS)
        wav = target.with_suffix(".wav")
        try:
            return transcribe(wav, self.media)
        except TranscriptionError as exc:
            logger.warning("transcription failed: %s", exc)
            self.channel.verbose(f"ASR failed: {exc}")
            return ""
        finally:
            wav.unlink(missing_ok=True)


# --------------------------------------------------------------------------- #

def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        filename=os.environ.get("RAG_VOICE_LOG", "/var/log/asterisk/ataru-voice.log"),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    channel = AGIChannel.connect()
    media = MediaConfig.from_env()

    try:
        from voice_backend import build_default_backend
        backend = build_default_backend()
        answer_fn = backend.as_callable()
    except Exception as exc:  # noqa: BLE001 - never drop the call silently
        logger.error("backend unavailable: %s", exc)

        def answer_fn(question, agent):  # type: ignore[misc]
            from voice import Answer
            return Answer(text="My document index isn't reachable right now.",
                          source=None, agent=agent)

    agents = [a.strip() for a in
              os.environ.get("RAG_VOICE_AGENTS", "comms,finance,health,life,records").split(",")
              if a.strip()]

    session = CallSession(agents=agents, answer_fn=answer_fn)
    CallRunner(channel, session, media).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
