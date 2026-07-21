"""Offline tests for the pure logic helpers: refusal detection, the
escalate distance gate, query dedup, and trace logging. No Ollama server
needed (importing llm needs only the ollama *package*, which is a declared
dependency). Run from the project root:

    python -m unittest
"""

import json
import tempfile
import unittest
from pathlib import Path

import config
import traces
from llm import _dedupe_queries, looks_incomplete, retrieval_supports_escalation


class TestLooksIncomplete(unittest.TestCase):
    def test_does_not_contain_is_refusal(self):
        self.assertTrue(looks_incomplete("The context does not contain that fact."))

    def test_does_not_include_is_refusal(self):
        # Added this session after the 7B varied its phrasing to "include".
        self.assertTrue(looks_incomplete("The document does not include that info."))

    def test_normal_answer_is_not_refusal(self):
        self.assertFalse(
            looks_incomplete("The dosa batter needs idli rice, urad dal, and fenugreek.")
        )

    def test_soft_qualifier_does_not_over_trigger(self):
        # "not specified" is a soft qualifier inside a real answer -- it must
        # NOT be read as a refusal, or escalate fires on good answers.
        self.assertFalse(
            looks_incomplete("It ferments overnight; the exact hours are not specified.")
        )


class TestRetrievalSupportsEscalation(unittest.TestCase):
    def test_strong_match_supports_escalation(self):
        # distance 0.3 <= 0.4 threshold -> a refusal here is suspicious.
        self.assertTrue(retrieval_supports_escalation([{"_distance": 0.3}]))

    def test_weak_match_does_not_support_escalation(self):
        # distance 0.5 > 0.4 -> refusal is probably a genuine absence.
        self.assertFalse(retrieval_supports_escalation([{"_distance": 0.5}]))

    def test_no_matches_does_not_support_escalation(self):
        self.assertFalse(retrieval_supports_escalation([]))


class TestDedupeQueries(unittest.TestCase):
    def test_question_first_and_order_preserved(self):
        self.assertEqual(
            _dedupe_queries("original?", ["variant a", "variant b"]),
            ["original?", "variant a", "variant b"],
        )

    def test_case_insensitive_dedup_and_cap_at_four(self):
        out = _dedupe_queries("Query", ["query", "A", "a", "B", "C", "D"])
        # "query" dupes "Query", "a" dupes "A" -> deduped, then capped at 4.
        self.assertEqual(out[0], "Query")
        self.assertEqual(len(out), 4)
        self.assertNotIn("query", out)


class TestTraceLog(unittest.TestCase):
    def test_writes_valid_json_and_respects_toggle(self):
        original_file, original_enabled = config.LOG_FILE, config.LOG_ENABLED
        try:
            tmp = Path(tempfile.mkdtemp()) / "log.jsonl"
            config.LOG_FILE = tmp

            # Disabled -> no file written.
            config.LOG_ENABLED = False
            traces.log({"question": "skip me", "tier": "fast"})
            self.assertFalse(tmp.exists())

            # Enabled -> one valid JSON line, timestamp auto-added.
            config.LOG_ENABLED = True
            traces.log({"question": "keep me", "tier": "good"})
            record = json.loads(tmp.read_text().strip())
            self.assertEqual(record["question"], "keep me")
            self.assertEqual(record["tier"], "good")
            self.assertIn("ts", record)
        finally:
            config.LOG_FILE, config.LOG_ENABLED = original_file, original_enabled


if __name__ == "__main__":
    unittest.main()
