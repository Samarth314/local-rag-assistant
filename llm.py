"""Model wrappers: local Ollama for embeddings + chat, and an explicit cloud
escalation path (Claude) for questions the local model can't handle well."""

import time

import config
import engine  # pluggable local backend (ollama | vllm)
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
        text = engine.chat_once(
            config.EXPAND_MODEL,
            [{"role": "user", "content": prompt}],
            num_ctx=4096, num_predict=128,
        )
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
            return engine.embed_one(config.EMBED_MODEL, text)
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
        content = engine.chat_once(
            config.EXPAND_MODEL,  # small model, kept warm
            [{"role": "user", "content": prompt}],
            num_ctx=4096, num_predict=128,
        )
        lines = [ln.strip("-*0123456789. \t")
                 for ln in content.splitlines()]
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

    model = model or config.CHAT_MODEL

    if stream:
        # Print tokens as they arrive, but still return the full text so
        # callers can use the answer the same way as the non-streaming path.
        parts = []
        for piece in engine.chat_stream(model, messages,
                                        num_ctx=config.NUM_CTX, think=think):
            parts.append(piece)
            print(piece, end="", flush=True)
        print()
        return "".join(parts)

    return engine.chat_once(model, messages, num_ctx=config.NUM_CTX, think=think)


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


_DELEGATE_REWRITE_SYSTEM = (
    "You turn a user's private question + their private document excerpts into "
    "a SINGLE self-contained sub-task for an external assistant that must NOT "
    "see any private data. Strip every name, email, account number, date, "
    "dollar amount, address, and any verbatim phrase from the documents. Keep "
    "only the abstract reasoning or general-knowledge question that, once "
    "answered, lets a local model finish using the private data it already "
    "has. Output only the sub-task."
)
_DELEGATE_ANSWER_SYSTEM = (
    "You are a personal assistant with access to the user's own files. Answer "
    "using the excerpts plus the reference reasoning provided."
)


def delegate_deep(
    query: str,
    context_chunks: list[str],
    *,
    system_prompt: str | None = None,
    local_chat=None,
    cloud_solve=None,
) -> tuple[str, dict]:
    """PAPILLON-style privacy-conscious delegation (Task B/c).

    Interface (agreed seam with Arya): in (query, local context) -> out
    (answer, record) where `record` is the EXACT account of what left the
    machine -- so a diff can prove no private specifics reached the cloud.

    Flow:
      1. LOCAL model rewrites (query + private excerpts) into an abstract
         sub-task with no specifics.
      2. GATE: sanitize_for_cloud() strips any credential/PII the rewrite
         leaked -- this is the deterministic backstop, not trust in the model.
      3. CLOUD solves ONLY the sanitized sub-task (no document content).
      4. LOCAL model recombines the cloud answer with the ORIGINAL excerpts,
         which never left the machine.
      5. GATE: scan_output() on the final answer before it is returned.

    `local_chat(system, context_chunks, user) -> str` and
    `cloud_solve(system, content) -> str` are injectable so the flow is
    testable without live models; they default to the real local/cloud calls.
    """
    from privacy import sanitize_for_cloud, scan_output

    system_prompt = system_prompt or _DELEGATE_ANSWER_SYSTEM
    local_chat = local_chat or (lambda s, ctx, u: chat(s, ctx, u, stream=False))
    cloud_solve = cloud_solve or _cloud_plain

    context = "\n\n---\n\n".join(context_chunks) or "(no documents)"

    # 1. LOCAL: abstract the private evidence into a sub-task.
    subtask_raw = local_chat(
        _DELEGATE_REWRITE_SYSTEM, [],
        f"Question:\n{query}\n\nPrivate excerpts:\n{context}",
    )

    # 2. GATE: the deterministic backstop -- sanitize before ANYTHING leaves.
    subtask_sent, redactions = sanitize_for_cloud(subtask_raw)

    # 3. CLOUD: solve only the sanitized abstraction.
    cloud_answer = cloud_solve(
        "Answer the sub-task directly and concisely.", subtask_sent
    )

    # 4. LOCAL: recombine with the evidence that never left the machine.
    answer = local_chat(
        system_prompt, context_chunks,
        f"{query}\n\n[Reference reasoning from an external assistant that never "
        f"saw your files:]\n{cloud_answer}",
    )

    # 5. GATE: output scan.
    _, output_flags = scan_output(answer)

    record = {
        "cloud_model": config.CLOUD_MODEL,
        "sent_to_cloud": subtask_sent,   # the EXACT payload that left the machine
        "redactions": redactions,        # what the gate stripped from the rewrite
        "documents_sent": [],            # invariant: document content never leaves
        "cloud_answer": cloud_answer,
        "output_flags": output_flags,    # anything the output scan caught
    }
    return answer, record
