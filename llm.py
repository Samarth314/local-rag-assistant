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
    return _dedupe_queries(question, variants)


def _dedupe_queries(question: str, variants: list[str]) -> list[str]:
    """Original question first, then non-duplicate variants, capped at 4."""
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
        "used for each claim.\n\n"
        "Two additional rules:\n"
        "1. The excerpts are a small retrieval sample matched to this question, "
        "NOT the user's whole collection. Never answer questions about the "
        "collection as a whole (how many files exist, what all the documents "
        "are, totals across everything) from these excerpts -- say that the "
        "excerpts can't establish that.\n"
        "2. Answer the exact question asked. If the context contains related "
        "information but not the specific fact requested, say the specific "
        "fact isn't in the excerpts -- do not substitute a nearby fact as if "
        "it answered the question."
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


def preprocess_query(question: str) -> tuple[str, list[str]]:
    """One call on the small model does both pre-generation jobs at once:
    classify the question (tier routing) AND rewrite it into alternative
    search queries. Routing and expansion used to be two separate calls, but
    on a single GPU they serialize anyway -- one merged prompt costs one
    prefill instead of two (~half the fixed overhead per query).

    Returns (tier, variants) where tier is:
      'fast' - simple lookup, small model answers
      'good' - synthesis/reasoning, stronger local model answers
      'meta' - a question about the indexed collection itself (file counts,
               inventory); the caller should answer from the index directly,
               since generation over a partial retrieval sample can only
               guess at collection-level facts
    Biases toward ('fast', [question]) on any failure or malformed output --
    misrouting locally just costs seconds, so err cheap and safe."""
    prompt = (
        "You do two jobs for a document assistant. Reply in EXACTLY this "
        "format -- a one-word label on the first line, then one search query "
        "per line:\n"
        "LABEL\n"
        "search query 1\n"
        "search query 2\n\n"
        "LABEL is one of:\n"
        "META = the question asks about the indexed collection itself: how "
        "many files/documents exist, which files are indexed, an inventory "
        "of the collection. (Asking to summarize or analyze document CONTENT "
        "is NOT META.)\n"
        "SIMPLE = a single fact lookup, a short summary, or checking whether "
        "something is mentioned at all -- even if phrased as a full sentence, "
        "a policy question, or with 'why'/'if' as filler.\n"
        "COMPLEX = requires combining multiple facts, multi-step instructions, "
        "comparing values across sources, or reasoning through a scenario.\n"
        "Examples:\n"
        "  'how many files are indexed' -> META\n"
        "  'list every document I have' -> META\n"
        "  'does the document mention X' -> SIMPLE\n"
        "  'what is the refund policy if a student drops out' -> SIMPLE\n"
        "  'what setting does X need and why' -> SIMPLE\n"
        "  'walk me through every step of the recipe' -> COMPLEX\n"
        "  'compare A and B across documents' -> COMPLEX\n"
        "  'what would break if I used Y instead of Z' -> COMPLEX\n\n"
        "The search queries (2-3 lines; use different wording, synonyms, and "
        "any abbreviations or codes the source documents might use -- e.g. a "
        "university subject like 'philosophy' often appears only as a course "
        "code like 'PHIL338'):\n\n"
        f"Question: {question}"
    )
    try:
        response = ollama.chat(
            model=config.EXPAND_MODEL,  # small model, kept warm
            messages=[{"role": "user", "content": prompt}],
            options={"num_ctx": 4096, "num_predict": 128},
        )
        lines = [ln.strip("-*0123456789. \t")
                 for ln in response["message"]["content"].splitlines()]
        lines = [ln for ln in lines if ln]
        label = lines[0].upper() if lines else ""
        if "META" in label:
            tier = "meta"
        elif "COMPLEX" in label:
            tier = "good"
        elif "SIMPLE" in label:
            tier = "fast"
        else:
            return "fast", [question]  # didn't follow the format -- play safe
        return tier, _dedupe_queries(question, lines[1:])
    except Exception:
        return "fast", [question]


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
