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


if __name__ == "__main__":
    unittest.main()
