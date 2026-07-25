"""Telephone front door for ATARU: a provider-agnostic call state machine.

The whole point of this module is that it knows nothing about Asterisk, SIP or
Twilio. It consumes two events -- "the caller pressed digits" and "the caller
said something" -- and returns what to say next. That keeps the call logic
unit-testable with no telephony stack, and lets the same logic sit behind an
Asterisk dialplan today and a Twilio webhook later.

Design constraints that come from the medium, not from taste:

  * LATENCY. On a live call, >3s of silence reads as a dropped line. The phone
    path pins the fast tier and never auto-escalates to the slow one -- our own
    benchmarks put the fast model near 2.5s and the thorough one at 20-30s,
    which is unusable while someone holds a handset.
  * SPOKEN SHAPE. Vault answers are markdown with bracketed citation paths.
    Read aloud that is unlistenable, so every answer goes through
    `to_speech()` and citations become "press 9 for the source" instead.
  * AUTHENTICATION. A number that reads out private documents to whoever dials
    it is an open door, and caller ID is trivially spoofed. A PIN is required
    before any content, with a hard attempt limit.

Nothing here writes to the network. Retrieval/answering is injected as
`answer_fn`, so tests drive the whole call with a stub.
"""

from __future__ import annotations

import hmac
import os
import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Optional

# --------------------------------------------------------------------------- #
# Speech shaping
# --------------------------------------------------------------------------- #

# Bracketed vault paths: [/docs/foo.txt], 【/docs/foo.txt】, (records/health/x)
_CITATION = re.compile(r"[\[\(【]\s*/?(?:docs|records)/[^\]\)】]*[\]\)】]")
_CODE_FENCE = re.compile(r"```.*?```", re.S)
_MD_INLINE = re.compile(r"[*_`#>|]+")
_MD_LINK = re.compile(r"\[([^\]]+)\]\([^)]*\)")
_BULLET = re.compile(r"^\s*[-*•]\s+", re.M)
_NUM_BULLET = re.compile(r"^\s*\d+[.)]\s+", re.M)
_WS = re.compile(r"\s+")

# A phone answer that runs longer than this stops being listenable.
MAX_SPOKEN_SENTENCES = 3
MAX_SPOKEN_CHARS = 420


def to_speech(text: str,
              max_sentences: int = MAX_SPOKEN_SENTENCES,
              max_chars: int = MAX_SPOKEN_CHARS) -> str:
    """Turn a markdown vault answer into something a TTS voice can read.

    Strips code fences, markdown syntax and bracketed citation paths, flattens
    bullets into sentences, and truncates to a listenable length. Citations are
    NOT spoken -- the caller is offered them on a keypress instead.
    """
    if not text:
        return ""
    out = _CODE_FENCE.sub(" ", text)
    out = _MD_LINK.sub(r"\1", out)
    out = _CITATION.sub(" ", out)
    out = _BULLET.sub("", out)
    out = _NUM_BULLET.sub("", out)
    out = _MD_INLINE.sub("", out)
    out = out.replace("\n", ". ")
    out = _WS.sub(" ", out).strip()
    # Collapse the ". ." runs the newline replacement can create.
    out = re.sub(r"(\.\s*){2,}", ". ", out).strip()

    sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", out) if s.strip()]
    if sentences:
        out = " ".join(sentences[:max_sentences])
    if len(out) > max_chars:
        out = out[:max_chars].rsplit(" ", 1)[0].rstrip(",;:") + "."
    return out


# --------------------------------------------------------------------------- #
# Keypad map
# --------------------------------------------------------------------------- #

@dataclass(frozen=True)
class KeypadOption:
    digit: str
    agent: str
    spoken: str


def build_keypad(agent_names: list[str]) -> list[KeypadOption]:
    """Map registry agents onto digits 1..n, in a stable order.

    Read from the registry rather than hardcoded, so adding an agent server-side
    changes the phone menu with no code change here (invariant: never hardcode
    agent names).
    """
    spoken = {
        "finance": "money, spending and renewals",
        "health": "labs and health records",
        "comms": "email and messages",
        "records": "general document lookup",
        "life": "calendar and personal",
    }
    ordered = sorted(agent_names)
    return [
        KeypadOption(digit=str(i + 1), agent=name, spoken=spoken.get(name, name))
        for i, name in enumerate(ordered[:8])  # 9 and 0 are reserved
    ]


DIGIT_SOURCE = "9"   # repeat the citation/source for the last answer
DIGIT_REPEAT = "0"   # repeat the menu
DIGIT_HANGUP = "#"   # end the call


# --------------------------------------------------------------------------- #
# Call state
# --------------------------------------------------------------------------- #

class CallState(Enum):
    GREETING = "greeting"
    AUTH = "auth"
    MENU = "menu"
    LISTENING = "listening"
    ANSWERED = "answered"
    ENDED = "ended"
    DENIED = "denied"


class Expect(Enum):
    """What the telephony adapter should collect next."""
    DTMF = "dtmf"
    SPEECH = "speech"
    NOTHING = "nothing"   # terminal turn: play the prompt, then hang up


@dataclass
class VoiceTurn:
    """One thing to say, plus what to collect afterwards."""
    speak: str
    expect: Expect = Expect.DTMF
    digits: int = 1
    end_call: bool = False
    state: CallState = CallState.MENU


@dataclass
class Answer:
    """What the answering backend returns for a spoken question."""
    text: str
    source: Optional[str] = None
    agent: Optional[str] = None


# `answer_fn(question, agent) -> Answer`
AnswerFn = Callable[[str, Optional[str]], Answer]


MAX_PIN_ATTEMPTS = 3


@dataclass
class CallSession:
    """The call state machine.

    Usage from an adapter:

        session = CallSession(agents=["comms", "finance", ...], answer_fn=fn)
        turn = session.begin()
        turn = session.handle_dtmf("1234")     # caller keyed a PIN
        turn = session.handle_speech("what renews this month")
    """

    agents: list[str]
    answer_fn: AnswerFn
    pin: Optional[str] = None
    state: CallState = CallState.GREETING
    selected_agent: Optional[str] = None
    last_source: Optional[str] = None
    pin_attempts: int = 0
    keypad: list[KeypadOption] = field(init=False)

    def __post_init__(self) -> None:
        self.keypad = build_keypad(self.agents)
        if self.pin is None:
            self.pin = os.environ.get("ATARU_VOICE_PIN") or None

    # -- prompts ----------------------------------------------------------- #

    def _menu_prompt(self) -> str:
        parts = [f"Press {o.digit} for {o.spoken}." for o in self.keypad]
        parts.append("Or just say what you're looking for after the tone.")
        return " ".join(parts)

    # -- entry ------------------------------------------------------------- #

    def begin(self) -> VoiceTurn:
        """First turn of the call."""
        if self.pin:
            self.state = CallState.AUTH
            return VoiceTurn(
                speak="ATARU. Enter your access code, then hash.",
                expect=Expect.DTMF, digits=8, state=CallState.AUTH,
            )
        # No PIN configured: refuse to serve content rather than fail open.
        self.state = CallState.DENIED
        return VoiceTurn(
            speak=("ATARU is not configured for phone access. "
                   "No access code is set, so this line can't read your records. "
                   "Goodbye."),
            expect=Expect.NOTHING, end_call=True, state=CallState.DENIED,
        )

    # -- DTMF -------------------------------------------------------------- #

    def handle_dtmf(self, digits: str) -> VoiceTurn:
        digits = (digits or "").strip().replace("#", "")

        if self.state == CallState.AUTH:
            return self._check_pin(digits)

        if self.state in (CallState.DENIED, CallState.ENDED):
            return self._goodbye()

        if digits == DIGIT_HANGUP or digits == "":
            return self._goodbye()

        if digits == DIGIT_REPEAT:
            self.state = CallState.MENU
            return VoiceTurn(speak=self._menu_prompt(), expect=Expect.DTMF,
                             state=CallState.MENU)

        if digits == DIGIT_SOURCE:
            if self.last_source:
                return VoiceTurn(
                    speak=f"That came from {_speakable_path(self.last_source)}. "
                          "Press 0 for the menu, or ask another question.",
                    expect=Expect.SPEECH, state=CallState.ANSWERED,
                )
            return VoiceTurn(
                speak="I don't have a source for that one. Press 0 for the menu.",
                expect=Expect.DTMF, state=CallState.ANSWERED,
            )

        for option in self.keypad:
            if option.digit == digits:
                self.selected_agent = option.agent
                self.state = CallState.LISTENING
                return VoiceTurn(
                    speak=f"{option.spoken.capitalize()}. What would you like to know?",
                    expect=Expect.SPEECH, state=CallState.LISTENING,
                )

        return VoiceTurn(
            speak="That isn't one of the options. " + self._menu_prompt(),
            expect=Expect.DTMF, state=CallState.MENU,
        )

    def _check_pin(self, digits: str) -> VoiceTurn:
        # Constant-time compare so the line can't be used as an oracle.
        if self.pin and hmac.compare_digest(digits, self.pin):
            self.pin_attempts = 0
            self.state = CallState.MENU
            return VoiceTurn(speak="Thank you. " + self._menu_prompt(),
                             expect=Expect.DTMF, state=CallState.MENU)

        self.pin_attempts += 1
        if self.pin_attempts >= MAX_PIN_ATTEMPTS:
            self.state = CallState.DENIED
            return VoiceTurn(
                speak="That code was not recognised. Goodbye.",
                expect=Expect.NOTHING, end_call=True, state=CallState.DENIED,
            )
        return VoiceTurn(
            speak="That code was not recognised. Try again, then hash.",
            expect=Expect.DTMF, digits=8, state=CallState.AUTH,
        )

    # -- Speech ------------------------------------------------------------ #

    def handle_speech(self, transcript: str) -> VoiceTurn:
        if self.state in (CallState.AUTH, CallState.DENIED, CallState.ENDED):
            # Never answer content before the PIN clears.
            return self._goodbye()

        question = (transcript or "").strip()
        if not question:
            return VoiceTurn(
                speak="I didn't catch that. Ask again, or press 0 for the menu.",
                expect=Expect.SPEECH, state=self.state,
            )

        if _is_hangup_phrase(question):
            return self._goodbye()

        answer = self.answer_fn(question, self.selected_agent)
        self.last_source = answer.source
        self.state = CallState.ANSWERED

        spoken = to_speech(answer.text)
        if not spoken:
            return VoiceTurn(
                speak="I couldn't find anything on that in your files. "
                      "Ask something else, or press 0 for the menu.",
                expect=Expect.SPEECH, state=CallState.ANSWERED,
            )

        tail = (" Press 9 for the source, 0 for the menu, or ask another question."
                if answer.source else
                " Press 0 for the menu, or ask another question.")
        return VoiceTurn(speak=spoken + tail, expect=Expect.SPEECH,
                         state=CallState.ANSWERED)

    # -- exit -------------------------------------------------------------- #

    def _goodbye(self) -> VoiceTurn:
        self.state = CallState.ENDED
        return VoiceTurn(speak="Goodbye.", expect=Expect.NOTHING,
                         end_call=True, state=CallState.ENDED)


_HANGUP_WORDS = {"goodbye", "bye", "hang up", "that's all", "thats all",
                 "nothing else", "end call", "thank you goodbye"}


def _is_hangup_phrase(text: str) -> bool:
    low = text.strip().lower().rstrip(".!")
    return low in _HANGUP_WORDS


def _speakable_path(path: str) -> str:
    """Turn a vault path into something a TTS voice reads sensibly."""
    name = path.rstrip("/").split("/")[-1]
    name = re.sub(r"\.(md|txt|pdf|docx|xlsx|jpg|png)$", "", name, flags=re.I)
    return name.replace("-", " ").replace("_", " ")
