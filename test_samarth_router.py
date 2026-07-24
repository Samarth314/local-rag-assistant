"""Offline tests for SamarthRouter -- the agent-axis RouterPolicy (Task A).

Uses the module's own contract shim (_FakeAgentSpec) so it runs without B3.
The real gate is Arya's `contract_test.py --policy routing.SamarthRouter`,
which these mirror the invariants of. Run: `python -m unittest`.
"""

import unittest

from routing import RouteDecision, SamarthRouter, _FakeAgentSpec


def _registry():
    return {
        "comms": _FakeAgentSpec(
            "comms", "email and messages",
            route_keywords=["email", "gmail", "message", "reply", "inbox"],
            route_examples=["any email from my landlord?", "draft a reply"],
        ),
        "finance": _FakeAgentSpec(
            "finance", "money, accounts, net worth, budget",
            route_keywords=["net worth", "budget", "spend", "account", "invoice"],
            route_examples=["what is my net worth?", "how much did I spend?"],
        ),
        "records": _FakeAgentSpec(
            "records", "general vault lookup, documents and notes",
            route_keywords=["find", "document", "note", "lease", "file"],
            route_examples=["find my lease terms", "what documents do I have?"],
        ),
    }


class TestRouteCorrectness(unittest.TestCase):
    def setUp(self):
        self.router = SamarthRouter(_registry())

    def test_email_query_routes_to_comms(self):
        self.assertEqual(self.router.route("Any email from my landlord?").agent, "comms")

    def test_money_query_routes_to_finance(self):
        self.assertEqual(self.router.route("What is my net worth?").agent, "finance")

    def test_document_query_routes_to_records(self):
        self.assertEqual(self.router.route("Find my lease terms").agent, "records")

    def test_returns_route_decision_type(self):
        d = self.router.route("draft a reply to the invoice email")
        self.assertIsInstance(d, RouteDecision)
        self.assertTrue(0.0 <= d.confidence <= 1.0)
        self.assertTrue(d.reason)


class TestInvariants(unittest.TestCase):
    """The Phase-A gate: these mirror contract_test.py's invariants."""

    def setUp(self):
        self.router = SamarthRouter(_registry())

    def test_agent_is_always_a_registry_key(self):
        # Invariant #1 -- every decision names a real agent.
        for q in ["Any email?", "net worth", "zzz nonsense", "", "42"]:
            self.assertIn(self.router.route(q).agent, self.router.agents)

    def test_no_signal_falls_back_to_records(self):
        # Invariant #1 -- when unsure, records (general vault lookup).
        d = self.router.route("What's the capital of France?")
        self.assertEqual(d.agent, "records")
        self.assertLess(d.confidence, 0.5)

    def test_never_hardcodes_missing_records_uses_first_agent(self):
        # If `records` isn't registered, fallback must still be a registry key.
        reg = {"finance": _registry()["finance"]}
        d = SamarthRouter(reg).route("totally unrelated query")
        self.assertIn(d.agent, reg)

    def test_route_only_reads_registry_never_mutates_it(self):
        # Invariant #2/#3 -- routing selects, never widens scope or adds tools.
        reg = _registry()
        before = {k: (v.route_keywords, v.route_examples) for k, v in reg.items()}
        SamarthRouter(reg).route("email about my budget invoice")
        after = {k: (v.route_keywords, v.route_examples) for k, v in reg.items()}
        self.assertEqual(before, after)


class TestTuning(unittest.TestCase):
    """Item-1 tunings: stopword filtering, confidence-floor / thin-margin
    fallback, and a deterministic tie-break."""

    def setUp(self):
        self.router = SamarthRouter(_registry())

    def test_labeled_examples_route_to_their_agent(self):
        # Labeled set built straight from the manifest route_examples: every
        # example must route to the agent that declared it.
        for name, spec in _registry().items():
            for ex in spec.route_examples:
                self.assertEqual(self.router.route(ex).agent, name, msg=repr(ex))

    def test_out_of_domain_falls_back_not_misroutes(self):
        # Arya's case: no content overlap -> records, NOT a false comms pick.
        d = self.router.route("when was I admitted to Stanford")
        self.assertEqual(d.agent, "records")
        self.assertLess(d.confidence, 0.5)

    def test_pure_stopword_noise_falls_back(self):
        for noise in ("the a to of my", "when is it", "how do i", "what is that"):
            self.assertEqual(self.router.route(noise).agent, "records", msg=noise)

    def test_gibberish_falls_back(self):
        self.assertEqual(self.router.route("asdf qwerty zzz").agent, "records")

    def test_single_weak_overlap_cannot_clear_floor(self):
        # "draft" overlaps one comms example (0.5) but isn't a comms keyword;
        # below the 1.0 floor -> records, not a confident comms pick.
        self.assertEqual(self.router.route("draft").agent, "records")

    def test_tie_resolves_deterministically_never_dict_order(self):
        # An exact tie is a thin margin -> deterministic fallback. With no
        # `records` agent, fallback is the alphabetically-first agent (never
        # dict-insertion order), the same on every call and regardless of how
        # the registry dict was built.
        reg_a = {
            "zeta": _FakeAgentSpec("zeta", "widgets", route_keywords=["widget"]),
            "alpha": _FakeAgentSpec("alpha", "widgets", route_keywords=["widget"]),
        }
        reg_b = {  # same agents, opposite insertion order
            "alpha": _FakeAgentSpec("alpha", "widgets", route_keywords=["widget"]),
            "zeta": _FakeAgentSpec("zeta", "widgets", route_keywords=["widget"]),
        }
        self.assertEqual(SamarthRouter(reg_a).route("widget order").agent, "alpha")
        self.assertEqual(SamarthRouter(reg_b).route("widget order").agent, "alpha")

    def test_tie_prefers_records_when_present(self):
        # With a records agent, any ambiguous tie routes there (the safe default).
        reg = {
            "comms": _FakeAgentSpec("comms", "", route_keywords=["widget"]),
            "finance": _FakeAgentSpec("finance", "", route_keywords=["widget"]),
            "records": _FakeAgentSpec("records", "general lookup"),
        }
        self.assertEqual(SamarthRouter(reg).route("widget order").agent, "records")


if __name__ == "__main__":
    unittest.main()
