"""ATARU privacy gate (Task B) -- the cloud-eligibility axis OpenJarvis lacks.

Dependency-free (stdlib only). Everything that leaves the machine passes
through `sanitize_for_cloud()`; everything shown to the user can pass through
`scan_output()`. Two detection layers:

  1. CREDENTIALS -- high-precision token-format regexes (API keys, AWS keys,
     GitHub/Slack tokens, bearer tokens, PEM headers). Ported from OpenJarvis's
     credential stripper, applied on the *egress* path (they only strip tool
     output; this strips anything bound for the cloud).

  2. STRUCTURED PII -- regexes for emails, phone numbers, SSNs, credit-card
     numbers (Luhn-checked to cut false positives), and IPv4. This is
     increment 1: high-precision, dependency-free.

     NOT YET COVERED: names, street addresses, org names -- these need NER.
     `detect_pii()` exposes a pluggable `ner` hook so a local GLiNER/Presidio
     backend can be dropped in as increment 2 without touching callers. Adding
     that backend is a deliberate dependency decision, not made here.

Design note: this is built to also contribute upstream as a boundary that
gates cloud eligibility, distinct from model selection (brief §5/§8).
"""

from __future__ import annotations

import re
from typing import Callable, Optional

# --------------------------------------------------------------------------- #
# Layer 1: credentials (token formats -- never words like "password")
# --------------------------------------------------------------------------- #
_CREDENTIAL_PATTERNS = (
    ("api_key", re.compile(r"sk-[A-Za-z0-9_-]{16,}")),
    ("aws_key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("github_token", re.compile(r"gh[pos]_[A-Za-z0-9]{20,}")),
    ("slack_token", re.compile(r"xox[baprs]-[0-9A-Za-z-]{10,}")),
    ("bearer_token", re.compile(r"(?i)bearer\s+[A-Za-z0-9_\-.=]{20,}")),
    ("private_key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
)

# --------------------------------------------------------------------------- #
# Layer 2: structured PII
# --------------------------------------------------------------------------- #
_EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
_PHONE = re.compile(
    r"(?<!\d)(?:\+?1[-.\s]?)?(?:\(\d{3}\)|\d{3})[-.\s]?\d{3}[-.\s]?\d{4}(?!\d)"
)
_SSN = re.compile(r"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)")
_IPV4 = re.compile(
    r"(?<!\d)(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?!\d)"
)
# 13-16 digit runs, possibly space/dash grouped -> candidate card numbers.
_CARD_CANDIDATE = re.compile(r"(?<!\d)(?:\d[ -]?){13,16}(?!\d)")
# 8-17 digit runs -> candidate account / long-id numbers (anything not a valid
# card). High-precision (a contiguous or space/dash-grouped digit run), so it
# fires on account numbers but not on ordinary prose.
_LONG_DIGITS = re.compile(r"(?<!\d)(?:\d[ -]?){7,16}\d(?!\d)")


def _luhn_ok(number: str) -> bool:
    """Luhn checksum -- filters random digit runs from real card numbers."""
    digits = [int(c) for c in number if c.isdigit()]
    if not 13 <= len(digits) <= 16:
        return False
    total, parity = 0, len(digits) % 2
    for i, d in enumerate(digits):
        if i % 2 == parity:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


def detect_pii(
    text: str, ner: Optional[Callable[[str], list[tuple[str, str]]]] = None
) -> list[tuple[str, str]]:
    """Return a list of (label, matched_text) PII findings, structured layer
    only. `ner`, if given, is a callable that returns extra (label, span)
    findings (the GLiNER/Presidio slot for names/addresses -- increment 2)."""
    findings: list[tuple[str, str]] = []
    for m in _EMAIL.finditer(text):
        findings.append(("email", m.group()))
    for m in _PHONE.finditer(text):
        findings.append(("phone", m.group()))
    for m in _SSN.finditer(text):
        findings.append(("ssn", m.group()))
    for m in _IPV4.finditer(text):
        findings.append(("ip", m.group()))
    for m in _CARD_CANDIDATE.finditer(text):
        if _luhn_ok(m.group()):
            findings.append(("credit_card", m.group()))
    for m in _LONG_DIGITS.finditer(text):
        # A long digit run that isn't a valid card -> treat as account/id.
        if not _luhn_ok(m.group()):
            findings.append(("account", m.group()))
    if ner is not None:
        try:
            findings.extend(ner(text))
        except Exception:
            pass  # a failing NER backend must never break the gate
    return findings


def _redact_credentials(text: str) -> tuple[str, dict[str, int]]:
    counts: dict[str, int] = {}
    for label, pattern in _CREDENTIAL_PATTERNS:
        text, n = pattern.subn(f"[REDACTED:{label}]", text)
        if n:
            counts[label] = counts.get(label, 0) + n
    return text, counts


def redact_credentials(text: str) -> tuple[str, int]:
    """Back-compat shim (llm.py calls this): returns (clean, total_count)."""
    clean, counts = _redact_credentials(text)
    return clean, sum(counts.values())


def sanitize_for_cloud(
    text: str, ner: Optional[Callable[[str], list[tuple[str, str]]]] = None
) -> tuple[str, dict[str, int]]:
    """Full egress gate: strip credentials AND structured PII from anything
    bound for the cloud. Returns (clean_text, {label: count}). This is what
    the --deep / world paths should call before sending."""
    text, counts = _redact_credentials(text)
    # PII is replaced longest-match-first so a card number isn't half-eaten by
    # a shorter overlapping match.
    for label, span in sorted(detect_pii(text, ner=ner), key=lambda f: -len(f[1])):
        if span and span in text:
            text = text.replace(span, f"[REDACTED:{label}]")
            counts[label] = counts.get(label, 0) + 1
    return text, counts


def scan_output(
    text: str, ner: Optional[Callable[[str], list[tuple[str, str]]]] = None
) -> tuple[str, dict[str, int]]:
    """Output-side scan before display -- models can regurgitate or reconstruct
    sensitive values. Same detection as the egress gate. Callers decide whether
    to redact in place (default) or just warn on a non-empty count."""
    return sanitize_for_cloud(text, ner=ner)


def summarize(counts: dict[str, int]) -> str:
    """Human-readable one-liner for the [redact] notice, e.g. '2 email, 1 ssn'."""
    return ", ".join(f"{n} {label}" for label, n in counts.items())


if __name__ == "__main__":
    sample = (
        "Contact me at jane.doe@example.com or (415) 555-0132. "
        "SSN 123-45-6789, card 4111 1111 1111 1111, key "
        "sk-ant-api03-ABCDEFGHIJKLMNOP, server 192.168.1.42. "
        "This sentence has no secrets and must survive intact."
    )
    clean, counts = sanitize_for_cloud(sample)
    print("counts:", counts)
    print("clean :", clean)
    assert "jane.doe@example.com" not in clean
    assert "sk-ant" not in clean
    assert "must survive intact" in clean
    print("OK")
