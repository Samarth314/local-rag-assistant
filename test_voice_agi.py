"""Offline tests for the Asterisk AGI bridge and the media helpers.

No Asterisk, no espeak, no sox, no ASR endpoint: the channel takes its streams
by injection and the media layer's command builders are pure. Run:
`python -m unittest`."""

import io
import unittest
from pathlib import Path
from unittest import mock

import voice_agi
from voice import Answer, CallSession
from voice_agi import (AGIChannel, CallRunner, parse_agi_environment,
                       parse_get_data, parse_result)
from voice_backend import (HttpVoiceBackend, VoiceBackend, parse_voice_response,
                           top_source)
from voice_media import (MediaConfig, cache_key, espeak_command, parse_transcript,
                         resample_command, stream_name)

AGENTS = ["comms", "finance", "health", "life", "records"]


class TestAGIProtocol(unittest.TestCase):
    def test_parses_environment_block(self):
        env = parse_agi_environment([
            "agi_channel: PJSIP/phone-0001\n",
            "agi_callerid: 100\n",
            "\n",
        ])
        self.assertEqual(env["agi_channel"], "PJSIP/phone-0001")
        self.assertEqual(env["agi_callerid"], "100")

    def test_parse_result_extracts_integer(self):
        self.assertEqual(parse_result("200 result=1\n"), 1)
        self.assertEqual(parse_result("200 result=-1\n"), -1)
        self.assertEqual(parse_result("garbage"), -1)

    def test_get_data_keeps_zero_as_a_real_keypress(self):
        # The regression this guards: reading result as an int turned the "0"
        # menu key into "caller pressed nothing".
        self.assertEqual(parse_get_data("200 result=0\n"), "0")

    def test_get_data_preserves_leading_zeros(self):
        self.assertEqual(parse_get_data("200 result=0481\n"), "0481")

    def test_get_data_empty_means_no_input(self):
        self.assertEqual(parse_get_data("200 result= (timeout)\n"), "")
        self.assertEqual(parse_get_data("200 result=-1\n"), "")

    def test_channel_connect_reads_env_then_stops_at_blank_line(self):
        stdin = io.StringIO("agi_callerid: 100\nagi_channel: X\n\nleftover\n")
        channel = AGIChannel.connect(stdin=stdin, stdout=io.StringIO())
        self.assertEqual(channel.caller_id, "100")
        self.assertEqual(stdin.readline(), "leftover\n")

    def test_command_writes_line_and_reads_response(self):
        stdout = io.StringIO()
        channel = AGIChannel(stdin=io.StringIO("200 result=1\n"), stdout=stdout, env={})
        self.assertEqual(channel.command("ANSWER"), "200 result=1\n")
        self.assertEqual(stdout.getvalue(), "ANSWER\n")

    def test_stream_returns_barge_in_digit(self):
        # STREAM FILE reports the ASCII code of the interrupting key: 53 -> "5".
        channel = AGIChannel(stdin=io.StringIO("200 result=53\n"),
                             stdout=io.StringIO(), env={})
        self.assertEqual(channel.stream("/tmp/x"), "5")

    def test_stream_returns_empty_when_uninterrupted(self):
        channel = AGIChannel(stdin=io.StringIO("200 result=0\n"),
                             stdout=io.StringIO(), env={})
        self.assertEqual(channel.stream("/tmp/x"), "")


class _FakeChannel:
    """Records commands and replays canned AGI responses."""

    def __init__(self, dtmf=None, barge=None):
        self.commands = []
        self.spoken = []
        self.dtmf = list(dtmf or [])
        self.barge = list(barge or [])
        self.caller_id = "100"
        self.hung_up = False

    def answer(self): self.commands.append("ANSWER")
    def verbose(self, message): self.commands.append(f"VERBOSE {message}")
    def hangup(self): self.hung_up = True; self.commands.append("HANGUP")

    def stream(self, audio_no_ext, escape_digits=""):
        self.spoken.append(audio_no_ext)
        return self.barge.pop(0) if self.barge else ""

    def get_data(self, audio_no_ext, timeout_ms, max_digits):
        return self.dtmf.pop(0) if self.dtmf else ""

    def record(self, path_no_ext, timeout_ms):
        self.commands.append(f"RECORD {path_no_ext}")


class TestCallRunner(unittest.TestCase):
    """Drives a whole call with synthesis and transcription stubbed out."""

    def _run(self, dtmf=None, barge=None, transcripts=None, stt=True):
        channel = _FakeChannel(dtmf=dtmf, barge=barge)
        session = CallSession(
            agents=AGENTS,
            answer_fn=lambda q, a: Answer(text="Two renew soon.", source="records/x.pdf"),
            pin="4821",
        )
        media = MediaConfig(sounds_dir=Path("/tmp/ataru-test"),
                            stt_url="http://stub/asr" if stt else None)
        runner = CallRunner(channel, session, media)

        spoken_text = []

        def fake_synth(text, _config):
            spoken_text.append(text)
            return Path("/tmp/ataru-test/x.wav")

        pending = list(transcripts or [])

        def fake_transcribe(_wav, _config):
            return pending.pop(0) if pending else ""

        with mock.patch.object(voice_agi, "synthesize", fake_synth), \
             mock.patch.object(voice_agi, "transcribe", fake_transcribe):
            runner.run()
        return channel, spoken_text

    def test_call_answers_and_hangs_up(self):
        channel, _ = self._run(dtmf=["4821"], transcripts=["that's all"])
        self.assertIn("ANSWER", channel.commands)
        self.assertTrue(channel.hung_up)

    def test_happy_path_reaches_an_answer(self):
        _, spoken = self._run(dtmf=["4821", "2"], transcripts=["what renews", "goodbye"])
        joined = " ".join(spoken)
        self.assertIn("Enter your access code", joined)
        self.assertIn("Two renew soon", joined)

    def test_wrong_pin_never_reaches_content(self):
        leaked = []
        channel = _FakeChannel(dtmf=["0000", "0000", "0000"])
        session = CallSession(
            agents=AGENTS,
            answer_fn=lambda q, a: leaked.append(q) or Answer(text="secret"),
            pin="4821",
        )
        media = MediaConfig(sounds_dir=Path("/tmp/ataru-test"), stt_url="http://stub/asr")
        with mock.patch.object(voice_agi, "synthesize",
                               lambda text, c: Path("/tmp/ataru-test/x.wav")), \
             mock.patch.object(voice_agi, "transcribe", lambda w, c: "read my labs"):
            CallRunner(channel, session, media).run()
        self.assertEqual(leaked, [])
        self.assertTrue(channel.hung_up)

    def test_barge_in_digit_is_honoured_over_recording(self):
        # Pressing a key while an answer plays should navigate, not record.
        channel, spoken = self._run(dtmf=["4821"], barge=["", "", "0"],
                                    transcripts=["goodbye"])
        self.assertNotIn("RECORD", " ".join(channel.commands))

    def test_keypad_only_mode_when_no_asr_configured(self):
        # With no ASR endpoint the line must stay usable, not record silence.
        channel, spoken = self._run(dtmf=["4821", "#"], stt=False)
        self.assertTrue(channel.hung_up)
        self.assertNotIn("RECORD", " ".join(channel.commands))


class TestMediaHelpers(unittest.TestCase):
    def setUp(self):
        self.config = MediaConfig(sounds_dir=Path("/tmp/x"), voice="en-us", words_per_minute=165)

    def test_espeak_command_shape(self):
        command = espeak_command("hello", Path("/tmp/o.wav"), self.config)
        self.assertEqual(command[0], "espeak-ng")
        self.assertIn("hello", command)
        self.assertIn("/tmp/o.wav", command)

    def test_resample_targets_telephony_format(self):
        command = resample_command(Path("/a.wav"), Path("/b.wav"))
        self.assertEqual(command[0], "sox")
        self.assertIn("8000", command)   # phone lines are 8 kHz
        self.assertIn("1", command)      # mono

    def test_cache_key_is_stable_and_voice_sensitive(self):
        other = MediaConfig(sounds_dir=Path("/tmp/x"), voice="en-gb")
        self.assertEqual(cache_key("hi", self.config), cache_key("hi", self.config))
        self.assertNotEqual(cache_key("hi", self.config), cache_key("hi", other))

    def test_stream_name_drops_extension(self):
        self.assertEqual(stream_name(Path("/s/ataru/a1.wav")), "/s/ataru/a1")

    def test_speech_disabled_without_asr_endpoint(self):
        self.assertFalse(self.config.speech_enabled)
        self.assertTrue(MediaConfig(sounds_dir=Path("/tmp"), stt_url="http://x").speech_enabled)

    def test_parse_transcript_handles_known_shapes(self):
        self.assertEqual(parse_transcript('{"text":" hello "}'), "hello")
        self.assertEqual(parse_transcript('{"results":[{"transcript":"hi"}]}'), "hi")
        self.assertEqual(parse_transcript('"bare string"'), "bare string")
        self.assertEqual(parse_transcript("plain text"), "plain text")
        self.assertEqual(parse_transcript(""), "")
        self.assertEqual(parse_transcript('{"unexpected":1}'), "")


class TestVoiceBackend(unittest.TestCase):
    def test_top_source_prefers_closest_vector_match(self):
        matches = [{"path": "a", "_distance": 0.4}, {"path": "b", "_distance": 0.1}]
        self.assertEqual(top_source(matches), "b")

    def test_top_source_falls_back_without_distances(self):
        self.assertEqual(top_source([{"path": "a"}, {"path": "b"}]), "a")
        self.assertIsNone(top_source([]))

    def test_retrieval_failure_still_returns_something_sayable(self):
        def boom(question, top_k): raise RuntimeError("index down")
        backend = VoiceBackend(retrieve=boom, generate=lambda *a: "unused")
        answer = backend.answer("anything")
        self.assertIn("couldn't reach", answer.text)

    def test_generation_failure_still_returns_something_sayable(self):
        backend = VoiceBackend(
            retrieve=lambda q, k: [{"path": "p", "text": "t", "_distance": 0.1}],
            generate=lambda *a: (_ for _ in ()).throw(RuntimeError("model down")),
        )
        self.assertIn("went wrong", backend.answer("anything").text)

    def test_no_matches_is_reported_honestly(self):
        backend = VoiceBackend(retrieve=lambda q, k: [], generate=lambda *a: "unused")
        self.assertIn("couldn't find anything", backend.answer("q").text)

    def test_pinned_agent_is_passed_through(self):
        backend = VoiceBackend(
            retrieve=lambda q, k: [{"path": "p", "text": "t", "_distance": 0.1}],
            generate=lambda *a: "answer",
        )
        self.assertEqual(backend.answer("q", "finance").agent, "finance")

    def test_parse_voice_response_shapes(self):
        answer = parse_voice_response('{"text":"hi","source":"records/a.md"}')
        self.assertEqual((answer.text, answer.source), ("hi", "records/a.md"))
        self.assertEqual(parse_voice_response('{"response":"alt"}').text, "alt")
        self.assertEqual(parse_voice_response("not json").text, "not json")

    def test_http_backend_degrades_when_service_is_down(self):
        backend = HttpVoiceBackend(base_url="http://127.0.0.1:9")  # nothing listening
        answer = backend.answer("what renews")
        self.assertIn("can't reach", answer.text)
        self.assertIsNone(answer.source)


if __name__ == "__main__":
    unittest.main()
