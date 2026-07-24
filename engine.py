"""Pluggable local inference backend.

All LOCAL inference (chat / embeddings / query expansion / routing) goes through
this thin layer, so the same harness runs on either engine:

  - RAG_ENGINE=ollama  (default) -- the Ollama server, unchanged
  - RAG_ENGINE=vllm              -- any OpenAI-compatible server (vLLM, etc.)

The cloud escalation path (Anthropic) is separate and unaffected by this.

Backends are imported lazily: the `ollama` package is needed only for the
ollama engine, the `openai` package only for the vllm engine -- so switching
engines never forces the other's dependency.

Model NAMES differ between engines. Ollama uses tags (`qwen2.5:7b-instruct`);
vLLM serves under HF-style ids (`Qwen/Qwen2.5-7B-Instruct`). When RAG_ENGINE=
vllm, set RAG_CHAT_MODEL / RAG_GOOD_MODEL / RAG_EXPAND_MODEL / RAG_EMBED_MODEL
to whatever your vLLM server actually serves.
"""

from __future__ import annotations

from typing import Iterator

import config


# --------------------------------------------------------------------------- #
# Ollama helpers
# --------------------------------------------------------------------------- #
def _ollama_options(num_ctx: int | None, num_predict: int | None) -> dict:
    o: dict = {}
    if num_ctx is not None:
        o["num_ctx"] = num_ctx
    if num_predict is not None:
        o["num_predict"] = num_predict
    return o


def _ollama_kwargs(model, messages, num_ctx, num_predict, think) -> dict:
    kwargs = {
        "model": model,
        "messages": messages,
        "options": _ollama_options(num_ctx, num_predict),
    }
    if think:  # Ollama-only reasoning-effort knob; vLLM ignores it.
        kwargs["think"] = think
    return kwargs


# --------------------------------------------------------------------------- #
# vLLM (OpenAI-compatible) helpers
# --------------------------------------------------------------------------- #
def _vllm_client():
    from openai import OpenAI  # lazy: only imported under the vllm engine

    return OpenAI(base_url=config.VLLM_URL, api_key=config.VLLM_API_KEY)


def _vllm_max_tokens(num_predict: int | None) -> int:
    # vLLM caps OUTPUT tokens (num_ctx is a server-launch setting, not per call).
    return num_predict or config.VLLM_MAX_TOKENS


# --------------------------------------------------------------------------- #
# Backend-agnostic public interface
# --------------------------------------------------------------------------- #
def chat_once(model, messages, *, num_ctx=None, num_predict=None, think=None) -> str:
    """Single non-streaming completion, returns the full text."""
    if config.ENGINE == "vllm":
        resp = _vllm_client().chat.completions.create(
            model=model, messages=messages,
            max_tokens=_vllm_max_tokens(num_predict), stream=False,
        )
        return resp.choices[0].message.content or ""
    import ollama

    resp = ollama.chat(**_ollama_kwargs(model, messages, num_ctx, num_predict, think))
    return resp["message"]["content"]


def chat_stream(model, messages, *, num_ctx=None, num_predict=None, think=None) -> Iterator[str]:
    """Streaming completion: yields text pieces as they arrive."""
    if config.ENGINE == "vllm":
        stream = _vllm_client().chat.completions.create(
            model=model, messages=messages,
            max_tokens=_vllm_max_tokens(num_predict), stream=True,
        )
        for chunk in stream:
            piece = chunk.choices[0].delta.content
            if piece:
                yield piece
        return
    import ollama

    for chunk in ollama.chat(
        stream=True, **_ollama_kwargs(model, messages, num_ctx, num_predict, think)
    ):
        yield chunk["message"]["content"]


def embed_one(model, text) -> list[float]:
    """Embed a single string. Uses EMBED_ENGINE (not ENGINE) so embeddings can
    stay on Ollama while generation runs on vLLM."""
    if config.EMBED_ENGINE == "vllm":
        resp = _vllm_client().embeddings.create(model=model, input=text)
        return list(resp.data[0].embedding)
    import ollama

    return ollama.embeddings(model=model, prompt=text)["embedding"]
