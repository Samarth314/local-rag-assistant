"""Offline tests for the heuristic pre-router (router.py).

Pure regex, no Ollama or network needed. Run from the project root:

    python -m unittest

These encode the routing behavior validated by hand against the Orin this
session, so any future change to router.py is scored against known-good
expectations instead of eyeballed.
"""

import unittest

from router import heuristic_route


class TestSimpleRouting(unittest.TestCase):
    def test_who_question_is_fast(self):
        self.assertEqual(heuristic_route("who are the co-founders of robolabs"), "fast")

    def test_what_brand_is_fast(self):
        self.assertEqual(
            heuristic_route("what brand is the ups used for the orin setup"), "fast"
        )

    def test_how_many_short_lookup_is_fast(self):
        # "how many" opener, short, no collection/world framing -> plain lookup.
        self.assertEqual(
            heuristic_route("how many gb is the samsung nvme drive"), "fast"
        )

    def test_case_insensitive(self):
        self.assertEqual(
            heuristic_route("WHO ARE THE CO-FOUNDERS OF ROBOLABS"), "fast"
        )


class TestComplexRouting(unittest.TestCase):
    def test_walkthrough_is_good(self):
        self.assertEqual(
            heuristic_route("walk me through every step of the rasam recipe in order"),
            "good",
        )

    def test_compare_is_good(self):
        self.assertEqual(
            heuristic_route("compare the full and reduced tuition tracks"), "good"
        )

    def test_what_would_break_is_good(self):
        self.assertEqual(
            heuristic_route("what would break if i used a raspberry pi instead"), "good"
        )

    def test_summarize_every_is_good(self):
        self.assertEqual(
            heuristic_route("summarize every document in my collection"), "good"
        )

    def test_two_questions_is_good(self):
        self.assertEqual(
            heuristic_route("what is the tuition? what is the refund policy?"), "good"
        )


class TestMetaRouting(unittest.TestCase):
    def test_how_many_files_is_meta(self):
        self.assertEqual(heuristic_route("how many files are indexed"), "meta")

    def test_list_every_document_is_meta(self):
        self.assertEqual(heuristic_route("list every document i have"), "meta")


class TestWorldRouting(unittest.TestCase):
    def test_current_time_is_world(self):
        self.assertEqual(
            heuristic_route("what time is it in chennai india right now"), "world"
        )

    def test_weather_today_is_world(self):
        self.assertEqual(heuristic_route("what is the weather in toronto today"), "world")

    def test_latest_news_is_world(self):
        self.assertEqual(heuristic_route("what are the latest news headlines"), "world")


class TestWorldPrivacyGuards(unittest.TestCase):
    """The one tier where a misroute leaks the question text off the machine,
    so these are the load-bearing safety tests."""

    def test_personal_pronoun_blocks_world_even_with_live_topic(self):
        # weather + "right now" but "i live" -> personal, must NOT go to cloud.
        result = heuristic_route("what is the weather where i live right now")
        self.assertNotEqual(result, "world")
        self.assertEqual(result, "fast")

    def test_personal_financial_question_stays_local(self):
        # "price" + "current" is live world-shaped, but "my stocks" is the
        # user's own data -> must stay local, never route to cloud.
        result = heuristic_route("what's the current price of my stocks")
        self.assertNotEqual(result, "world")
        self.assertEqual(result, "fast")

    def test_world_topic_without_live_marker_defers_to_llm(self):
        # Ambiguous (no "now"/"today") -> defer rather than mis-serve locally.
        self.assertIsNone(heuristic_route("what is the weather in toronto"))


class TestAmbiguousDefersToLLM(unittest.TestCase):
    def test_how_do_i_defers(self):
        # "how do i make X" is not a bare lookup opener -> LLM decides.
        self.assertIsNone(heuristic_route("how do i make dosa batter"))

    def test_long_question_defers(self):
        # Over the simple-opener word cap -> LLM decides.
        self.assertIsNone(
            heuristic_route(
                "what is the refund policy if a student drops out of the vex "
                "academy halfway through"
            )
        )

    def test_payment_lookup_stays_local(self):
        # No world topic word -> plain personal lookup, stays fast/local.
        self.assertEqual(heuristic_route("what did i pay for the vex academy"), "fast")


if __name__ == "__main__":
    unittest.main()
