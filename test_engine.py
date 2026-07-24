"""Offline tests for the pluggable inference engine (engine.py). Pure logic
only -- no server, no ollama/openai import needed. Run: `python -m unittest`."""

import unittest

import config
import engine


class TestEngineConfig(unittest.TestCase):
    def test_default_engine_is_ollama(self):
        self.assertEqual(config.ENGINE, "ollama")

    def test_ollama_options_only_includes_present_keys(self):
        self.assertEqual(engine._ollama_options(None, None), {})
        self.assertEqual(engine._ollama_options(8192, None), {"num_ctx": 8192})
        self.assertEqual(
            engine._ollama_options(4096, 128),
            {"num_ctx": 4096, "num_predict": 128},
        )

    def test_ollama_kwargs_omits_think_when_absent(self):
        kw = engine._ollama_kwargs("m", [], 8192, None, None)
        self.assertNotIn("think", kw)
        kw = engine._ollama_kwargs("m", [], 8192, None, "low")
        self.assertEqual(kw["think"], "low")

    def test_vllm_max_tokens_falls_back_to_config(self):
        self.assertEqual(engine._vllm_max_tokens(128), 128)
        self.assertEqual(engine._vllm_max_tokens(None), config.VLLM_MAX_TOKENS)


if __name__ == "__main__":
    unittest.main()
