"""Heuristic pre-router: instant, zero-cost tier routing for unambiguous
questions.

The LLM preprocess call costs 1.5-6s on every query; for most questions the
tier is obvious from surface patterns alone. This module classifies those
instantly with regexes, and returns None for anything ambiguous so the
caller can fall back to the LLM classifier. Inspired by OpenJarvis's
zero-call complexity scorer, adapted to our tier set.

Deliberately conservative in two places:
  - WORLD (question text goes to the cloud) requires a live-world topic AND
    a live-time marker AND no first-person possessive -- "my"/"i" always
    stays local, so a misfire can't leak a personal question.
  - Anything not clearly matched returns None (LLM decides), so the
    heuristic can only ever make routing faster, not more wrong.

Dependency-free on purpose: importable into any host system (checkpoint-9
handoff) without dragging in ollama or the rest of this harness.
"""

import re

# Questions about the indexed collection itself -- answered from the index
# in code, no model call. Narrow: requires explicit index/collection framing,
# so "how many cups of rice" or "how many files does the doc mention" fall
# through to the LLM instead.
_META = re.compile(
    r"(?i)(?:\b(?:how many|list|what|which)\b.{0,50}\b(?:files?|documents?|docs)\b"
    r".{0,50}\b(?:indexed|in (?:the|my) (?:index|collection)|do i have)\b"
    r"|\blist (?:all|every) (?:my )?(?:files?|documents?|docs)\b)"
)

# Live outside-world topics + a live-time marker. Both must hit, and no
# personal pronoun may appear, before a question is allowed to short-circuit
# to the cloud.
_WORLD_TOPIC = re.compile(
    r"(?i)\b(?:time|weather|temperature|news|headlines?|stock|stocks|"
    r"price of|exchange rate|score|forecast)\b"
)
_WORLD_LIVE = re.compile(
    r"(?i)\b(?:right now|now|today|tonight|currently|current|latest|"
    r"this (?:week|morning|evening))\b"
)
_PERSONAL = re.compile(r"(?i)\b(?:my|mine|our|ours|i|me|we)\b")

# Clear synthesis/reasoning markers -> the stronger local model.
_COMPLEX = re.compile(
    r"(?i)\b(?:compare|comparison|versus|vs\.?|difference between|"
    r"walk (?:me )?through|step[- ]by[- ]step|every step|in order|"
    r"what would (?:break|happen|change)|what happens if|"
    r"pros and cons|trade[- ]?offs?|"
    r"summarize (?:every|all|each)|across (?:all|both|every))\b"
)

# Interrogative openers that mark a plain lookup when the question is short.
_SIMPLE_OPENER = re.compile(
    r"(?i)^(?:who|what|what's|whats|when|where|which|how (?:much|many|long|"
    r"big|fast|old)|does|do|did|is|are|was|were|can|could|has|have)\b"
)
_SIMPLE_MAX_WORDS = 12


def heuristic_route(question: str) -> str | None:
    """Classify a question by surface patterns alone.

    Returns 'meta', 'world', 'good', or 'fast' when the tier is unambiguous,
    or None when the LLM classifier should decide. Precedence: meta ->
    world -> good -> fast (so a short "compare A vs B" lands on good, not
    fast).
    """
    q = question.strip()

    if _META.search(q):
        return "meta"

    if _WORLD_TOPIC.search(q) and _WORLD_LIVE.search(q) and not _PERSONAL.search(q):
        return "world"

    if _COMPLEX.search(q) or q.count("?") >= 2:
        return "good"

    if _SIMPLE_OPENER.match(q) and len(q.split()) <= _SIMPLE_MAX_WORDS:
        return "fast"

    return None
