"""Offline tests for the telephone front door. No telephony stack, no models --
the answering backend is injected, so the whole call is driven with a stub.
Run: `python -m unittest`."""

import unittest

from voice import (Answer, CallSession, CallState, Expect, KeypadOption,
                   build_keypad, to_speech)

AGENTS = ["comms", "finance", "health", "life", "records"]


def _stub_answer(text="Two subscriptions renew in the next two weeks.",
                 source="records/finances/subscriptions/Subscription Inventory.pdf"):
    def fn(question, agent):
        return Answer(text=text, source=source, agent=agent)
    return fn


def _session(pin="4821", **kw):
    return CallSession(agents=AGENTS, answer_fn=kw.pop("answer_fn", _stub_answer()),
                       pin=pin, **kw)


class TestSpeechShaping(unittest.TestCase):
    def test_strips_bracketed_citation_paths(self):
        spoken = to_speech("The tuition is 2500 dollars. [/docs/vex-academy-faq.txt]")
        self.assertNotIn("/docs/", spoken)
        self.assertIn("2500 dollars", spoken)

    def test_strips_cjk_bracket_citations(self):
        self.assertNotIn("docs", to_speech("Ready overnight.【/docs/recipe.txt】"))

    def test_strips_markdown_syntax(self):
        spoken = to_speech("**Bold** and `code` and # Heading")
        for ch in "*`#":
            self.assertNotIn(ch, spoken)

    def test_flattens_bullets_into_sentences(self):
        spoken = to_speech("- First item\n- Second item")
        self.assertNotIn("-", spoken)
        self.assertIn("First item", spoken)

    def test_truncates_to_listenable_length(self):
        long_text = " ".join(f"Sentence number {i}." for i in range(40))
        spoken = to_speech(long_text)
        self.assertLessEqual(len(spoken), 460)
        self.assertLessEqual(spoken.count("."), 4)

    def test_empty_text_is_empty(self):
        self.assertEqual(to_speech(""), "")

    def test_plain_answer_survives_intact(self):
        text = "Your net worth is not stated in the indexed documents."
        self.assertEqual(to_speech(text), text)


class TestKeypad(unittest.TestCase):
    def test_digits_assigned_from_registry_not_hardcoded(self):
        keypad = build_keypad(["zeta", "alpha"])
        self.assertEqual([o.agent for o in keypad], ["alpha", "zeta"])
        self.assertEqual([o.digit for o in keypad], ["1", "2"])

    def test_stable_across_calls(self):
        self.assertEqual(build_keypad(AGENTS), build_keypad(AGENTS))

    def test_reserved_digits_not_assigned_to_agents(self):
        keypad = build_keypad([f"agent{i}" for i in range(12)])
        self.assertNotIn("9", [o.digit for o in keypad])
        self.assertNotIn("0", [o.digit for o in keypad])


class TestAuthentication(unittest.TestCase):
    def test_call_opens_by_demanding_a_code(self):
        turn = _session().begin()
        self.assertEqual(turn.state, CallState.AUTH)
        self.assertEqual(turn.expect, Expect.DTMF)

    def test_correct_pin_reaches_the_menu(self):
        s = _session()
        s.begin()
        turn = s.handle_dtmf("4821")
        self.assertEqual(turn.state, CallState.MENU)
        self.assertIn("Press 1", turn.speak)

    def test_wrong_pin_retries_then_hangs_up(self):
        s = _session()
        s.begin()
        for _ in range(2):
            turn = s.handle_dtmf("0000")
            self.assertFalse(turn.end_call)
        turn = s.handle_dtmf("0000")
        self.assertTrue(turn.end_call)
        self.assertEqual(turn.state, CallState.DENIED)

    def test_no_content_before_pin_clears(self):
        # The load-bearing test: speech during AUTH must never reach answer_fn.
        called = []

        def spy(question, agent):
            called.append(question)
            return Answer(text="secret")

        s = _session(answer_fn=spy)
        s.begin()
        turn = s.handle_speech("read me my lab results")
        self.assertEqual(called, [])
        self.assertTrue(turn.end_call)

    def test_unconfigured_pin_fails_closed(self):
        # With no PIN set the line must refuse service, not serve openly.
        s = CallSession(agents=AGENTS, answer_fn=_stub_answer(), pin="")
        turn = s.begin()
        self.assertEqual(turn.state, CallState.DENIED)
        self.assertTrue(turn.end_call)

    def test_denied_call_stays_denied(self):
        s = CallSession(agents=AGENTS, answer_fn=_stub_answer(), pin="")
        s.begin()
        self.assertTrue(s.handle_speech("hello?").end_call)


class TestMenuAndAnswering(unittest.TestCase):
    def _authed(self, **kw):
        s = _session(**kw)
        s.begin()
        s.handle_dtmf("4821")
        return s

    def test_digit_pins_the_agent(self):
        s = self._authed()
        turn = s.handle_dtmf("2")          # alphabetical: comms,finance,...
        self.assertEqual(s.selected_agent, "finance")
        self.assertEqual(turn.expect, Expect.SPEECH)

    def test_pinned_agent_is_passed_to_backend(self):
        seen = {}

        def spy(question, agent):
            seen["agent"] = agent
            return Answer(text="ok")

        s = self._authed(answer_fn=spy)
        s.handle_dtmf("3")                 # health
        s.handle_speech("what were my last results")
        self.assertEqual(seen["agent"], "health")

    def test_speech_without_menu_selection_leaves_agent_unset(self):
        # Router decides downstream; the phone layer must not invent an agent.
        seen = {}

        def spy(question, agent):
            seen["agent"] = agent
            return Answer(text="ok")

        s = self._authed(answer_fn=spy)
        s.handle_speech("anything from my landlord")
        self.assertIsNone(seen["agent"])

    def test_answer_is_spoken_without_citation_paths(self):
        s = self._authed(answer_fn=_stub_answer(
            text="Two renew soon. [/docs/subs.pdf]",
            source="records/finances/subs.pdf"))
        turn = s.handle_speech("what renews")
        self.assertNotIn("/docs/", turn.speak)
        self.assertIn("Press 9 for the source", turn.speak)

    def test_source_offered_only_when_present(self):
        s = self._authed(answer_fn=_stub_answer(text="No idea.", source=None))
        turn = s.handle_speech("what renews")
        self.assertNotIn("Press 9", turn.speak)

    def test_nine_reads_back_a_speakable_source(self):
        s = self._authed()
        s.handle_speech("what renews")
        turn = s.handle_dtmf("9")
        self.assertIn("Subscription Inventory", turn.speak)
        self.assertNotIn(".pdf", turn.speak)

    def test_zero_returns_to_menu(self):
        s = self._authed()
        s.handle_dtmf("1")
        turn = s.handle_dtmf("0")
        self.assertEqual(turn.state, CallState.MENU)

    def test_unknown_digit_reprompts_without_ending(self):
        s = self._authed()
        turn = s.handle_dtmf("7")
        self.assertFalse(turn.end_call)
        self.assertIn("isn't one of the options", turn.speak)

    def test_empty_transcript_reprompts(self):
        s = self._authed()
        turn = s.handle_speech("   ")
        self.assertFalse(turn.end_call)
        self.assertEqual(turn.expect, Expect.SPEECH)

    def test_empty_answer_is_reported_honestly(self):
        s = self._authed(answer_fn=_stub_answer(text="", source=None))
        turn = s.handle_speech("what renews")
        self.assertIn("couldn't find anything", turn.speak)

    def test_goodbye_ends_the_call(self):
        s = self._authed()
        turn = s.handle_speech("that's all")
        self.assertTrue(turn.end_call)
        self.assertEqual(turn.state, CallState.ENDED)

    def test_hash_ends_the_call(self):
        s = self._authed()
        self.assertTrue(s.handle_dtmf("#").end_call)


if __name__ == "__main__":
    unittest.main()
