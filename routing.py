"""ATARU routing module (graduation target for Task A).

Dependency-free (stdlib only) so it imports cleanly into the ATARU/OpenJarvis
dispatch seam without dragging in ollama or the rest of this harness.

Two things live here, on two orthogonal axes (per brief §7):

  1. AGENT axis -- `SamarthRouter(RouterPolicy)`: given a query, pick which
     narrow agent owns it. This is the RouterPolicy that replaces B3's
     placeholder policies. It reads the agent registry handed in by the base
     constructor and never hardcodes agent names.

  2. TIER axis (this harness's own logic, kept separate and downstream):
     `heuristic_route` (fast/good/meta/world) plus the escalation-quality
     helpers `looks_incomplete` / `retrieval_supports_escalation`. Per
     invariant #4 these do NOT belong inside `route()` -- model/tier choice is
     per-agent, applied by the runner, not the dispatcher. They're here because
     they're the reusable, dependency-free half of the harness.

The credential/PII redaction helpers live in the companion `privacy.py`
(the cloud-eligibility axis). Both modules are stdlib-only; concatenate them
if a single-file drop is preferred.
"""

from __future__ import annotations

import re
from abc import ABC, abstractmethod
from dataclasses import dataclass, field


# =========================================================================== #
# AGENT AXIS -- the RouterPolicy contract (brief §7 / ROUTER_INTERFACE.md)
# =========================================================================== #

# --- INTEGRATION SHIM ------------------------------------------------------ #
# On integration into b3, DELETE this block and instead do:
#     from policy import RouterPolicy, RouteDecision
# (AgentSpec comes from registry.py; only its documented fields are read.)
# The SamarthRouter logic below does not change when the shim is swapped out.
@dataclass
class RouteDecision:
    agent: str            # MUST be a key in the agent registry
    confidence: float     # 0..1
    reason: str           # human-readable, for logs/audit
    scores: dict          # optional per-agent raw scores ({} is fine)


class RouterPolicy(ABC):
    """Mirror of B3's ABC: the base constructor hands the policy the registry."""

    def __init__(self, agents: dict):
        self.agents = agents  # dict[str, AgentSpec]

    @abstractmethod
    def route(self, query: str) -> RouteDecision:
        ...


@dataclass
class _FakeAgentSpec:
    """Stand-in for registry.AgentSpec (documented fields only) for self-test."""
    name: str
    description: str = ""
    route_keywords: list = field(default_factory=list)
    route_examples: list = field(default_factory=list)
# --------------------------- end INTEGRATION SHIM -------------------------- #


_WORD = re.compile(r"[a-z0-9']+")
_FALLBACK_AGENT = "records"  # invariant #1: general vault lookup when unsure


def _tokens(text: str) -> set[str]:
    return set(_WORD.findall(text.lower()))


class SamarthRouter(RouterPolicy):
    """Agent-axis router. Scores the query against each registered agent's
    keywords/examples/description and returns the best match, or the `records`
    fallback. Mirrors the harness's proven heuristic-first shape, retargeted
    from tier -> agent. Preserves the Phase-A invariants:

      #1 always returns a registry name (falls back to `records`);
      #2 never widens scope (selects an agent, never adds tools);
      #3 never enables a gated tool (it only picks a name);
      #4 model-agnostic (no tier/model choice here).
    """

    def route(self, query: str) -> RouteDecision:
        q_tokens = _tokens(query)
        low = query.lower()
        scores: dict[str, float] = {}

        for name, spec in self.agents.items():
            keywords = [k.lower() for k in getattr(spec, "route_keywords", []) or []]
            examples = getattr(spec, "route_examples", []) or []
            description = getattr(spec, "description", "") or ""

            score = 0.0
            for kw in keywords:                       # strong: explicit keywords
                if kw in low:
                    score += 2.0
            for ex in examples:                        # medium: example overlap
                overlap = len(q_tokens & _tokens(ex))
                if overlap:
                    score += 0.5 * overlap
            score += 0.25 * len(q_tokens & _tokens(description))  # weak: desc

            if score > 0:
                scores[name] = round(score, 3)

        if not scores:
            return RouteDecision(
                agent=self._fallback(),
                confidence=0.30,
                reason="samarth/routing: no agent signal -> records fallback",
                scores={},
            )

        best = max(scores, key=scores.get)
        total = sum(scores.values())
        confidence = round(scores[best] / total, 3) if total else 0.5
        return RouteDecision(
            agent=best,
            confidence=confidence,
            reason=f"samarth/routing: keyword+example match (score={scores[best]})",
            scores=scores,
        )

    def _fallback(self) -> str:
        if _FALLBACK_AGENT in self.agents:
            return _FALLBACK_AGENT
        return next(iter(self.agents))


# =========================================================================== #
# TIER AXIS -- this harness's own routing (kept separate; not part of route())
# =========================================================================== #

_META = re.compile(
    r"(?i)(?:\b(?:how many|list|what|which)\b.{0,50}\b(?:files?|documents?|docs)\b"
    r".{0,50}\b(?:indexed|in (?:the|my) (?:index|collection)|do i have)\b"
    r"|\blist (?:all|every) (?:my )?(?:files?|documents?|docs)\b)"
)
_WORLD_TOPIC = re.compile(
    r"(?i)\b(?:time|weather|temperature|news|headlines?|stock|stocks|"
    r"price of|exchange rate|score|forecast)\b"
)
_WORLD_LIVE = re.compile(
    r"(?i)\b(?:right now|now|today|tonight|currently|current|latest|"
    r"this (?:week|morning|evening))\b"
)
_PERSONAL = re.compile(r"(?i)\b(?:my|mine|our|ours|i|me|we)\b")
_COMPLEX = re.compile(
    r"(?i)\b(?:compare|comparison|versus|vs\.?|difference between|"
    r"walk (?:me )?through|step[- ]by[- ]step|every step|in order|"
    r"what would (?:break|happen|change)|what happens if|"
    r"pros and cons|trade[- ]?offs?|"
    r"summarize (?:every|all|each)|across (?:all|both|every))\b"
)
_SIMPLE_OPENER = re.compile(
    r"(?i)^(?:who|what|what's|whats|when|where|which|how (?:much|many|long|"
    r"big|fast|old)|does|do|did|is|are|was|were|can|could|has|have)\b"
)
_SIMPLE_MAX_WORDS = 12


def heuristic_route(question: str) -> str | None:
    """Classify a question by surface patterns alone: 'meta'/'world'/'good'/
    'fast', or None when the LLM classifier should decide. Precedence:
    meta -> world -> good -> fast. Conservative by design -- ambiguity returns
    None, so the heuristic can only make routing faster, never more wrong."""
    q = question.strip()
    if _META.search(q):
        return "meta"
    if _WORLD_TOPIC.search(q) and _WORLD_LIVE.search(q) and not _PERSONAL.search(q):
        return "world"
    if _COMPLEX.search(q) or q.count("?") >= 2:
        return "good"
    if _SIMPLE_OPENER.match(q) and len(q.split()) <= _SIMPLE_MAX_WORDS:
        # World-topic word without a personal pronoun is ambiguous -> defer.
        if _WORLD_TOPIC.search(q) and not _PERSONAL.search(q):
            return None
        return "fast"
    return None


# Refusal-style phrasing (narrow, not soft qualifiers) -> the answer looks
# like the model couldn't answer from the context.
_FAILURE_SIGNALS = (
    "does not contain", "doesn't contain", "do not contain",
    "cannot answer", "can't answer", "unable to answer", "cannot determine",
    "no relevant information", "not enough information", "insufficient information",
    "does not provide", "doesn't provide", "no information about",
    "the context does not", "excerpts do not", "not found in the",
    "no mention of", "does not mention",
    "does not include", "doesn't include",
)

# Default cosine-distance cutoff for "strong retrieval match". The harness
# overrides this from config; kept here so the module stays config-free.
DEFAULT_ESCALATE_DISTANCE = 0.4


def looks_incomplete(answer: str) -> bool:
    """True if the answer reads like a refusal/hedge (the escalate backstop's
    trigger)."""
    low = answer.lower()
    return any(sig in low for sig in _FAILURE_SIGNALS)


def retrieval_supports_escalation(
    matches: list[dict], threshold: float = DEFAULT_ESCALATE_DISTANCE
) -> bool:
    """True if at least one retrieved chunk is a strong semantic match (cosine
    distance <= threshold). A refusal next to only weak matches is trusted;
    a refusal next to a strong match is the suspicious case worth retrying."""
    return any(
        m.get("_distance") is not None and m["_distance"] <= threshold
        for m in matches
    )


if __name__ == "__main__":
    # Standalone smoke test (no B3): `python routing.py`
    # The real gate is Arya's: `python contract_test.py --policy routing.SamarthRouter`
    registry = {
        "comms": _FakeAgentSpec(
            "comms", "email and messages",
            route_keywords=["email", "gmail", "message", "reply", "inbox"],
            route_examples=["any email from my landlord?", "draft a reply to Sam"],
        ),
        "finance": _FakeAgentSpec(
            "finance", "money, accounts, net worth",
            route_keywords=["net worth", "budget", "spend", "account", "invoice"],
            route_examples=["what is my net worth?", "how much did I spend on rent?"],
        ),
        "records": _FakeAgentSpec(
            "records", "general vault lookup",
            route_keywords=["find", "document", "note", "lease", "file"],
            route_examples=["find my lease terms", "what documents do I have?"],
        ),
    }
    router = SamarthRouter(registry)
    for q in ["Any email from my landlord?", "What is my net worth?",
              "Find my lease terms", "What's the capital of France?"]:
        d = router.route(q)
        print(f"{d.agent:8} conf={d.confidence:<5} | {q}")
