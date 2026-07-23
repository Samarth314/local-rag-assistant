"""Model wrappers: local Ollama for embeddings + chat, and an explicit cloud
escalation path (Claude) for questions the local model can't handle well."""

import time

import ollama

import config
# Pure, dependency-free logic now lives in the graduation modules; re-exported
# here so existing callers (cli.py, tests) keep importing from `llm`.
from privacy import redact_credentials, sanitize_for_cloud, summarize  # noqa: F401
from routing import looks_incomplete  # noqa: F401
from routing import retrieval_supports_escalation as _rse


def retrieval_supports_escalation(matches: list[dict]) -> bool:
    """Harness wrapper: applies the config-tuned distance threshold."""
    return _rse(matches, config.ESCALATE_DISTANCE_THRESHOLD)


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


def preprocess_query(question: str) -> tuple[str, list[str]]:
    """One call on the small model does both pre-generation jobs at once:
    classify the question (tier routing) AND rewrite it into alternative
    search queries. Routing and expansion used to be two separate calls, but
    on a single GPU they serialize anyway -- one merged prompt costs one
    prefill instead of two (~half the fixed overhead per query).

    Returns (tier, variants) where tier is:
      'fast'  - simple lookup, small model answers
      'good'  - synthesis/reasoning, stronger local model answers
      'meta'  - a question about the indexed collection itself (file counts,
                inventory); the caller should answer from the index directly,
                since generation over a partial retrieval sample can only
                guess at collection-level facts
      'world' - a question the user's files could never answer (current
                time/weather/news/live facts); the caller may send JUST the
                question to the cloud. Deliberately biased against: when in
                doubt, stay local -- a misroute here leaks the question text
                off the machine, unlike every other tier.
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
        "WORLD = the question is about the live outside world or general "
        "public facts that a person's own files could never contain: the "
        "current time or date, weather, news, live prices, sports scores. "
        "STRICT RULE: if the question could plausibly be answered by the "
        "user's own files (their recipes, notes, records, plans, purchases, "
        "projects), it is NOT WORLD. When unsure, never pick WORLD.\n"
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
        "  'what time is it in chennai right now' -> WORLD\n"
        "  'what is the weather in toronto today' -> WORLD\n"
        "  'how do I make dosa batter' -> SIMPLE (their own recipes may cover it)\n"
        "  'how many files are indexed' -> META\n"
        "  'list every document I have' -> META\n"
        "  'does the document mention X' -> SIMPLE\n"
        "  'what is the refund policy if a student drops out' -> SIMPLE\n"
        "  'what setting does X need and why' -> SIMPLE\n"
        "  'walk me through every step of the recipe' -> COMPLEX\n"
        "  'compare A and B across documents' -> COMPLEX\n"
        "  'what would break if I used Y instead of Z' -> COMPLEX\n\n"
        "The search queries (2-3 lines; skip for WORLD and META; use "
        "different wording, synonyms, and any abbreviations or codes the "
        "source documents might use -- e.g. a university subject like "
        "'philosophy' often appears only as a course code like 'PHIL338'):\n\n"
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
        if "WORLD" in label:
            tier = "world"
        elif "META" in label:
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


def cloud_world(question: str, stream: bool = True) -> str:
    """Answer an out-of-scope world-knowledge question (current time, weather,
    news, live facts) directly with the cloud model. No retrieval happens and
    no document content is sent -- ONLY the question text leaves the machine.
    Web search is enabled because a plain model call has neither a clock nor
    the internet: without it, 'what time is it in Chennai' gets a confident
    stale guess instead of an answer."""
    import anthropic

    question, counts = sanitize_for_cloud(question)
    if counts:
        print(f"[redact] removed before sending to cloud: {summarize(counts)}")

    client = anthropic.Anthropic()

    parts = []
    with client.messages.stream(
        model=config.CLOUD_MODEL,
        max_tokens=4000,
        thinking={"type": "adaptive"},
        system=(
            "Answer the user's question directly and concisely. Use web "
            "search whenever the answer depends on current information "
            "(time, weather, news, prices)."
        ),
        messages=[{"role": "user", "content": question}],
        tools=[{"type": "web_search_20260209", "name": "web_search", "max_uses": 3}],
    ) as response_stream:
        for text in response_stream.text_stream:
            parts.append(text)
            if stream:
                print(text, end="", flush=True)
    if stream:
        print()
    return "".join(parts)


def cloud_chat(
    system_prompt: str,
    context_chunks: list[str],
    user_query: str,
    stream: bool = True,
) -> str:
    """Escalate one question to Claude in the cloud (--deep). Retrieval has
    already happened locally -- only the retrieved excerpts and the question
    leave the machine, and only because the user explicitly asked. Credentials
    AND structured PII in those excerpts are stripped by the privacy gate
    first (see privacy.sanitize_for_cloud)."""
    import anthropic

    prompt = _build_prompt(context_chunks, user_query)
    prompt, counts = sanitize_for_cloud(prompt)
    if counts:
        print(f"[redact] removed before sending to cloud: {summarize(counts)}")
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


def _cloud_plain(system_prompt: str, user_content: str, max_tokens: int = 4000) -> str:
    """One non-streaming, tool-less cloud call. Used by the delegation path."""
    import anthropic

    client = anthropic.Anthropic()
    with client.messages.stream(
        model=config.CLOUD_MODEL,
        max_tokens=max_tokens,
        thinking={"type": "adaptive"},
        system=system_prompt,
        messages=[{"role": "user", "content": user_content}],
    ) as s:
        return "".join(s.text_stream)


def delegate_deep(
    system_prompt: str,
    context_chunks: list[str],
    user_query: str,
    stream: bool = True,
) -> str:
    """PAPILLON-style privacy-conscious delegation for --deep (Task B/c).

    Instead of shipping raw excerpts to the cloud (what cloud_chat does), the
    LOCAL model turns the private evidence into a sanitized, self-contained
    sub-task; only that sub-task goes to the cloud; the LOCAL model then
    recombines the cloud's reasoning with the private evidence that never left.

    Flow:
      1. LOCAL: (question + excerpts) -> a generalized sub-task with no names,
         numbers, or verbatim spans from the documents.
      2. GATE:  sanitize_for_cloud() on the sub-task, belt-and-suspenders.
      3. CLOUD: solve only the abstract sub-task.
      4. LOCAL: recombine the cloud answer with the ORIGINAL excerpts.
      5. GATE:  scan_output() before returning.

    Gated behind config.DELEGATE_DEEP (default off) until validated end-to-end
    on the Orin -- quality preservation is a behavioral property that needs a
    live local model to measure, not a code property. When off, callers use
    cloud_chat (raw-excerpt path) as before.
    """
    from privacy import scan_output

    context = "\n\n---\n\n".join(context_chunks) or "(no documents)"

    # 1. LOCAL: write a sanitized sub-task from the private evidence.
    rewrite_system = (
        "You turn a user's private question + their private document excerpts "
        "into a SINGLE self-contained sub-task for an external assistant that "
        "must NOT see any private data. Strip every name, email, account "
        "number, date, dollar amount, address, and any verbatim phrase from "
        "the documents. Keep only the abstract reasoning or general-knowledge "
        "question that, once answered, lets a local model finish using the "
        "private data it already has. Output only the sub-task."
    )
    subtask = chat(
        rewrite_system,
        [],
        f"Question:\n{user_query}\n\nPrivate excerpts:\n{context}",
        stream=False,
    )

    # 2. GATE: never trust the rewrite blindly.
    subtask, counts = sanitize_for_cloud(subtask)
    print(f"[delegate] local model wrote a sanitized sub-task; "
          f"{'redacted ' + summarize(counts) if counts else 'no residual PII'}\n"
          f"[delegate] sending to cloud (no document content):\n  {subtask}\n")

    # 3. CLOUD: solve only the abstraction.
    cloud_answer = _cloud_plain(
        "Answer the sub-task directly and concisely.", subtask
    )

    # 4. LOCAL: recombine with the private evidence that never left.
    answer = chat(
        system_prompt,
        context_chunks,
        f"{user_query}\n\n[Reference reasoning from an external assistant, which "
        f"never saw your files:]\n{cloud_answer}",
        stream=stream,
    )

    # 5. GATE: output scan before display.
    scanned, out_counts = scan_output(answer)
    if out_counts:
        print(f"\n[output-scan] flagged in the answer: {summarize(out_counts)}")
    return answer
