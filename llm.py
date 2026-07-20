"""Model wrappers: local Ollama for embeddings + chat, and an explicit cloud
escalation path (Claude) for questions the local model can't handle well."""

import time

import ollama

import config


def expand_query(question: str) -> list[str]:
    """Rewrite a question into a few alternative search queries to bridge
    vocabulary gaps between natural language and how documents actually phrase
    things (e.g. "philosophy classes" -> "PHIL338", "computer science" ->
    "CMSC"). Returns the original question first, then variants. Falls back to
    just the original if the model call fails."""
    prompt = (
        "Rewrite the user's question into 2-3 short alternative search queries "
        "that improve document retrieval. Use different wording, likely "
        "synonyms, and any abbreviations or codes the source documents might "
        "use -- for example a university subject like 'philosophy' often "
        "appears only as a course code like 'PHIL338'. Output only the "
        "queries, one per line, no numbering or commentary.\n\n"
        f"Question: {question}"
    )
    try:
        response = ollama.chat(
            model=config.EXPAND_MODEL,
            messages=[{"role": "user", "content": prompt}],
            options={"num_ctx": 4096, "num_predict": 128},
        )
        text = response["message"]["content"]
    except Exception:
        return [question]

    variants = [line.strip("-*0123456789. \t") for line in text.splitlines()]
    queries = [question] + [v for v in variants if v]
    seen, out = set(), []
    for q in queries:
        key = q.lower()
        if key not in seen:
            seen.add(key)
            out.append(q)
    return out[:4]


def embed(text: str, retries: int = 2) -> list[float]:
    last_error = None
    for attempt in range(retries + 1):
        try:
            response = ollama.embeddings(model=config.EMBED_MODEL, prompt=text)
            return response["embedding"]
        except Exception as e:
            last_error = e
            if attempt < retries:
                time.sleep(1)
    raise last_error


def _build_prompt(context_chunks: list[str], user_query: str) -> str:
    if context_chunks:
        context = "\n\n---\n\n".join(context_chunks)
    else:
        context = "(No relevant documents were found for this query.)"
    return (
        f"Here is retrieved context from the user's files:\n\n{context}\n\n"
        f"Here is the user's question:\n{user_query}\n\n"
        "Answer using only the context above. If the context doesn't contain "
        "the answer, say so instead of guessing. Each excerpt above is labeled "
        "with its own source file in brackets -- treat each excerpt as belonging "
        "only to that file, never combine or attribute a detail from one file's "
        "excerpt to a different file. Cite the specific source file path(s) you "
        "used for each claim."
    )


# Strong signals that the model couldn't answer from the retrieved context.
# Deliberately narrow -- refusal-style phrasing, not soft qualifiers -- so a
# genuine answer that happens to say "not specified" in passing doesn't trip it.
_FAILURE_SIGNALS = (
    "does not contain", "doesn't contain", "do not contain",
    "cannot answer", "can't answer", "unable to answer", "cannot determine",
    "no relevant information", "not enough information", "insufficient information",
    "does not provide", "doesn't provide", "no information about",
    "the context does not", "excerpts do not", "not found in the",
    "no mention of", "does not mention",
    "does not include", "doesn't include",
)


def looks_incomplete(answer: str) -> bool:
    """True if the answer reads like the model couldn't answer from the context
    (refusal / hedging). Used by the escalate-on-failure backstop to decide
    whether to retry one tier up."""
    low = answer.lower()
    return any(sig in low for sig in _FAILURE_SIGNALS)


def retrieval_supports_escalation(matches: list[dict]) -> bool:
    """True if at least one retrieved chunk is a strong semantic match (low
    cosine distance). Chunks found only via keyword search, or whose vector
    distance is borderline, don't carry this signal -- so a refusal next to
    those is trusted as-is rather than retried on a bigger model."""
    return any(
        m.get("_distance") is not None and m["_distance"] <= config.ESCALATE_DISTANCE_THRESHOLD
        for m in matches
    )


def route_query(question: str) -> str:
    """Classify a question as 'fast' (simple lookup/summary) or 'good' (needs
    synthesis/reasoning), via one cheap call on the small model. Biases toward
    'fast' on any failure or ambiguity -- misrouting an easy question to the big
    model just wastes a few seconds, so err cheap."""
    prompt = (
        "Classify this question for a document assistant as SIMPLE or COMPLEX.\n"
        "Judge by what the assistant actually has to DO, not by sentence length "
        "or whether it contains words like 'why' or 'if'.\n"
        "SIMPLE = a single fact lookup, a short summary, or checking whether "
        "something is mentioned at all (including checks that will likely come "
        "back 'not mentioned') -- even if the question is phrased as a full "
        "sentence, a policy question, or includes 'why'/'if' as filler.\n"
        "COMPLEX = requires combining multiple facts, multi-step instructions, "
        "comparing values across sources, or reasoning through a hypothetical "
        "scenario using several pieces of context together.\n"
        "Examples:\n"
        "  'does the document mention X' -> SIMPLE (it's just a lookup, even "
        "though it's phrased as a yes/no question)\n"
        "  'what is the refund policy if a student drops out' -> SIMPLE (single "
        "fact lookup, the 'if' is just how the fact is phrased)\n"
        "  'what setting does X need and why' -> SIMPLE (still one lookup)\n"
        "  'walk me through every step of the recipe' -> COMPLEX (multi-step)\n"
        "  'compare A and B across documents' -> COMPLEX (synthesis)\n"
        "  'what would break if I used Y instead of Z' -> COMPLEX (reasoning "
        "over several facts together)\n"
        "Answer with exactly one word: SIMPLE or COMPLEX.\n\n"
        f"Question: {question}"
    )
    try:
        response = ollama.chat(
            model=config.EXPAND_MODEL,  # reuse the small model already loaded
            messages=[{"role": "user", "content": prompt}],
            options={"num_ctx": 2048, "num_predict": 8},
        )
        return "good" if "COMPLEX" in response["message"]["content"].upper() else "fast"
    except Exception:
        return "fast"


def chat(
    system_prompt: str,
    context_chunks: list[str],
    user_query: str,
    stream: bool = False,
    model: str | None = None,
    think: str | None = None,
) -> str:
    prompt = _build_prompt(context_chunks, user_query)

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": prompt},
    ]

    options = {"num_ctx": config.NUM_CTX}
    model = model or config.CHAT_MODEL
    kwargs = {"model": model, "messages": messages, "options": options}
    if think:
        kwargs["think"] = think

    if stream:
        # Print tokens as they arrive, but still return the full text so
        # callers can use the answer the same way as the non-streaming path.
        parts = []
        for chunk in ollama.chat(**kwargs, stream=True):
            piece = chunk["message"]["content"]
            parts.append(piece)
            print(piece, end="", flush=True)
        print()
        return "".join(parts)

    response = ollama.chat(**kwargs)
    return response["message"]["content"]


def cloud_chat(
    system_prompt: str,
    context_chunks: list[str],
    user_query: str,
    stream: bool = True,
) -> str:
    """Escalate one question to Claude in the cloud (--deep). Retrieval has
    already happened locally -- only the retrieved excerpts and the question
    leave the machine, and only because the user explicitly asked."""
    import anthropic

    prompt = _build_prompt(context_chunks, user_query)
    client = anthropic.Anthropic()

    parts = []
    with client.messages.stream(
        model=config.CLOUD_MODEL,
        max_tokens=16000,
        thinking={"type": "adaptive"},
        system=system_prompt,
        messages=[{"role": "user", "content": prompt}],
    ) as response_stream:
        for text in response_stream.text_stream:
            parts.append(text)
            if stream:
                print(text, end="", flush=True)
    if stream:
        print()
    return "".join(parts)
