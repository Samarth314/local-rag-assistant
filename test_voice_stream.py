"""Offline tests for the streaming voice session. No server, no models, no
sockets -- the session talks to a fake socket and fake engines, so a whole
call is driven in-process. Run: `python -m unittest`."""

import asyncio
import struct
import unittest

import voice_stream
from voice_stream import (AnswerStream, SentenceStream, SessionDeps,
                          WavStreamParser)


def _wav(pcm: bytes, rate: int = 24000, channels: int = 1) -> bytes:
    """A minimal valid WAV wrapping `pcm`."""
    fmt = struct.pack("<HHIIHH", 1, channels, rate,
                      rate * channels * 2, channels * 2, 16)
    return (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE"
            + b"fmt " + struct.pack("<I", len(fmt)) + fmt
            + b"data" + struct.pack("<I", len(pcm)) + pcm)


class TestSentenceStream(unittest.TestCase):
    def test_splits_across_deltas(self):
        s = SentenceStream()
        out = s.feed("The rent is due on Friday. The landl")
        self.assertEqual(out, ["The rent is due on Friday."])
        out = s.feed("ord confirmed it. And that")
        self.assertEqual(out, ["The landlord confirmed it."])
        self.assertEqual(s.flush(), ["And that"])

    def test_cleans_each_sentence(self):
        s = SentenceStream()
        out = s.feed("The tuition is **2500 dollars**. [/docs/faq.txt] Next one starts. ")
        self.assertEqual(out[0], "The tuition is 2500 dollars.")
        self.assertNotIn("/docs/", " ".join(out))

    def test_dropped_when_cleaning_leaves_nothing(self):
        s = SentenceStream()
        self.assertEqual(s.feed("[/docs/faq.txt]. "), [])

    def test_runaway_clause_is_flushed_at_word_break(self):
        s = SentenceStream()
        out = s.feed("word " * 100)  # 500 chars, no terminator
        self.assertTrue(out, "expected a forced flush")
        self.assertTrue(all(len(c) <= voice_stream.MAX_UNTERMINATED_CHARS + 10
                            for c in out))

    def test_flush_empty(self):
        self.assertEqual(SentenceStream().flush(), [])


class TestWavStreamParser(unittest.TestCase):
    def test_parses_header_and_strips_it(self):
        pcm = bytes(range(256)) * 4
        parser = WavStreamParser()
        got = parser.feed(_wav(pcm, rate=22050, channels=1))
        self.assertEqual(got, pcm)
        self.assertEqual(parser.sample_rate, 22050)
        self.assertEqual(parser.channels, 1)

    def test_header_split_across_chunks(self):
        pcm = b"\x01\x02" * 100
        wav = _wav(pcm)
        parser = WavStreamParser()
        got = parser.feed(wav[:10]) + parser.feed(wav[10:30]) + parser.feed(wav[30:])
        self.assertEqual(got, pcm)
        self.assertEqual(parser.sample_rate, 24000)

    def test_rejects_non_riff(self):
        with self.assertRaises(ValueError):
            WavStreamParser().feed(b"HTTP/1.1 502 Bad Gateway")


class FakeSocket:
    """Records everything the session sends; serves scripted client messages."""

    def __init__(self, incoming):
        self.incoming = list(incoming)
        self.sent = []

    async def send_json(self, payload):
        self.sent.append(payload)

    async def send_bytes(self, data):
        self.sent.append(data)

    async def receive_json(self):
        if not self.incoming:
            raise ConnectionError("client went away")
        return self.incoming.pop(0)


def _run(ws, deps):
    async def main():
        try:
            await voice_stream.run_session(ws, deps)
        except ConnectionError:
            pass
    asyncio.run(main())


def _answer(tokens, source="/docs/faq.txt", canned=None):
    def factory(question, top_k):
        return AnswerStream(tokens=iter(tokens), source=source,
                            model="test-model", canned=canned)
    return factory


def _file_tts(pcm=b"\x00\x01" * 400):
    calls = []

    def synth(sentence):
        calls.append(sentence)
        return _wav(pcm)
    synth.calls = calls
    return synth


class TestSession(unittest.TestCase):
    def _events(self, sent):
        return [m["type"] for m in sent if isinstance(m, dict)]

    def test_streams_deltas_then_audio_then_done(self):
        ws = FakeSocket([{"type": "ask", "q": "when is rent due"}])
        tts = _file_tts()
        deps = SessionDeps(answer_stream=_answer(["Rent is due ", "Friday. "]),
                           synthesize_stream=None, synthesize_file=tts,
                           max_sentences=3)
        _run(ws, deps)

        types = self._events(ws.sent)
        self.assertEqual(types[0], "accepted")
        self.assertIn("delta", types)
        self.assertIn("audio_begin", types)
        self.assertIn("audio_end", types)
        self.assertEqual(types[-1], "done")
        # Binary PCM frames actually went out, header stripped.
        blobs = [m for m in ws.sent if isinstance(m, bytes)]
        self.assertTrue(blobs)
        self.assertEqual(b"".join(blobs), b"\x00\x01" * 400)
        self.assertEqual(tts.calls, ["Rent is due Friday."])
        done = ws.sent[-1]
        self.assertEqual(done["text"], "Rent is due Friday.")
        self.assertEqual(done["source"], "/docs/faq.txt")

    def test_audio_begin_carries_format(self):
        ws = FakeSocket([{"type": "ask", "q": "q"}])
        deps = SessionDeps(answer_stream=_answer(["One. "]),
                           synthesize_stream=None, synthesize_file=_file_tts(),
                           max_sentences=3)
        _run(ws, deps)
        begin = next(m for m in ws.sent
                     if isinstance(m, dict) and m["type"] == "audio_begin")
        self.assertEqual(begin["sampleRate"], 24000)
        self.assertEqual(begin["encoding"], "pcm_s16le")
        self.assertEqual(begin["text"], "One.")

    def test_sentence_cap_limits_speech(self):
        ws = FakeSocket([{"type": "ask", "q": "q"}])
        tts = _file_tts()
        tokens = ["One. ", "Two. ", "Three. ", "Four. ", "Five. "]
        deps = SessionDeps(answer_stream=_answer(tokens),
                           synthesize_stream=None, synthesize_file=tts,
                           max_sentences=2)
        _run(ws, deps)
        self.assertEqual(tts.calls, ["One.", "Two."])
        self.assertEqual(ws.sent[-1]["text"], "One. Two.")

    def test_tts_failure_degrades_to_text_only(self):
        ws = FakeSocket([{"type": "ask", "q": "q"}])

        def broken(sentence):
            raise RuntimeError("engine gone")

        deps = SessionDeps(answer_stream=_answer(["One. ", "Two. "]),
                           synthesize_stream=None, synthesize_file=broken,
                           max_sentences=3)
        _run(ws, deps)
        types = self._events(ws.sent)
        self.assertEqual(types.count("tts_unavailable"), 1)
        self.assertNotIn("audio_begin", types)
        self.assertEqual(types[-1], "done")

    def test_canned_answer_is_spoken(self):
        ws = FakeSocket([{"type": "ask", "q": "q"}])
        tts = _file_tts()
        deps = SessionDeps(
            answer_stream=_answer([], source=None,
                                  canned="There's nothing indexed yet, so I have nothing to search."),
            synthesize_stream=None, synthesize_file=tts, max_sentences=3)
        _run(ws, deps)
        self.assertEqual(len(tts.calls), 1)
        self.assertEqual(ws.sent[-1]["type"], "done")

    def test_empty_question_is_an_error_not_a_crash(self):
        ws = FakeSocket([{"type": "ask", "q": "  "},
                         {"type": "ask", "q": "real question. "}])
        deps = SessionDeps(answer_stream=_answer(["Fine. "]),
                           synthesize_stream=None, synthesize_file=_file_tts(),
                           max_sentences=3)
        _run(ws, deps)
        types = self._events(ws.sent)
        self.assertEqual(types[0], "error")
        self.assertIn("done", types)

    def test_answer_error_reported_in_band(self):
        ws = FakeSocket([{"type": "ask", "q": "q"}])

        def exploding(question, top_k):
            raise RuntimeError("store on fire")

        deps = SessionDeps(answer_stream=exploding, synthesize_stream=None,
                           synthesize_file=_file_tts(), max_sentences=3)
        _run(ws, deps)
        self.assertEqual(self._events(ws.sent), ["accepted", "error"])


if __name__ == "__main__":
    unittest.main()
