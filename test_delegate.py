"""Offline tests for PAPILLON delegation (Task B). The models are injected as
fakes, so the whole flow runs with no Ollama/Anthropic. The load-bearing test
is the payload diff: whatever the local model leaks into the sub-task, a diff
of *what actually went to the cloud* must contain none of the private
specifics. Run: `python -m unittest`."""

import unittest

from llm import delegate_deep

# Synthetic secret corpus (structured shapes the egress gate must catch).
SECRETS = {
    "api_key": "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUV",
    "aws_key": "AKIAIOSFODNN7EXAMPLE",
    "github_token": "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345",
    "email": "patient.jane@hospital.org",
    "phone": "(415) 555-0199",
    "ssn": "123-45-6789",
    "card": "4111 1111 1111 1111",
    "ip": "10.0.42.17",
    "account": "4830027261509",
}


class _FakeModels:
    """First local call = the (leaky) rewrite; second = recombination.
    cloud_solve records exactly what it received."""

    def __init__(self, subtask):
        self.subtask = subtask
        self.local_calls = 0
        self.cloud_received = None

    def local_chat(self, system, ctx, user):
        self.local_calls += 1
        return self.subtask if self.local_calls == 1 else "final grounded answer"

    def cloud_solve(self, system, content):
        self.cloud_received = content
        return "general reasoning about the abstract question"


class TestDelegateDeep(unittest.TestCase):
    def test_no_private_specifics_reach_cloud(self):
        # Worst case: the local model LEAKS every secret into the sub-task.
        leaky = "Sub-task using " + " ".join(SECRETS.values())
        fm = _FakeModels(leaky)
        answer, record = delegate_deep(
            "what do my labs mean",
            ["[/docs/labs.txt]\n" + leaky],
            local_chat=fm.local_chat, cloud_solve=fm.cloud_solve,
        )
        sent = record["sent_to_cloud"]
        # (a) the record IS the exact payload the cloud received
        self.assertEqual(fm.cloud_received, sent)
        # (b) payload diff: no structured secret survives in what left the box
        for label, secret in SECRETS.items():
            self.assertNotIn(secret, sent, msg=f"{label} leaked into payload")
            self.assertNotIn(secret, fm.cloud_received, msg=f"{label} reached cloud")
        # (c) the gate actually did the stripping, and no docs ever left
        self.assertTrue(record["redactions"])
        self.assertEqual(record["documents_sent"], [])
        self.assertTrue(answer)

    def test_context_only_secret_never_leaves(self):
        # A secret living ONLY in the private context (not echoed by the
        # rewrite) must never appear in the cloud payload.
        secret = "9988776655443322"
        fm = _FakeModels("Explain the general concept of an A1C blood-sugar test.")
        _, record = delegate_deep(
            "interpret my result",
            [f"[/docs/labs.txt]\npatient id {secret}, A1C 7.4"],
            local_chat=fm.local_chat, cloud_solve=fm.cloud_solve,
        )
        self.assertNotIn(secret, record["sent_to_cloud"])
        self.assertNotIn(secret, fm.cloud_received)

    def test_clean_subtask_passes_through_unchanged(self):
        fm = _FakeModels("What is a good general approach to comparing two plans?")
        answer, record = delegate_deep(
            "compare my two plans", ["[/d]\nplan A vs plan B"],
            local_chat=fm.local_chat, cloud_solve=fm.cloud_solve,
        )
        self.assertEqual(record["sent_to_cloud"],
                         "What is a good general approach to comparing two plans?")
        self.assertEqual(record["redactions"], {})

    def test_record_shape_is_the_agreed_seam(self):
        fm = _FakeModels("abstract question")
        _, record = delegate_deep(
            "q", ["[/d]\nctx"], local_chat=fm.local_chat, cloud_solve=fm.cloud_solve)
        self.assertEqual(
            set(record),
            {"cloud_model", "sent_to_cloud", "redactions", "documents_sent",
             "cloud_answer", "output_flags"},
        )

    def test_names_path_via_pluggable_ner(self):
        # Names need NER, not regex -- the documented names path. With the hook,
        # a leaked name is stripped from the egress payload.
        from privacy import sanitize_for_cloud
        clean, _ = sanitize_for_cloud(
            "Compare outcomes for Jane Doe and her cohort.",
            ner=lambda t: [("person", "Jane Doe")],
        )
        self.assertNotIn("Jane Doe", clean)


if __name__ == "__main__":
    unittest.main()
