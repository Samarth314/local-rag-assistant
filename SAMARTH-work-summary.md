# Local LLM Routing + Privacy Subsystem — Work Summary

**Author:** Samarth
**Repo:** `github.com/Samarth314/local-rag-assistant` (private)
**Target hardware:** Jetson AGX Orin 64GB ("orin" / ATARU node), containerized
**Date of this summary:** July 2026
**Intended destination:** ATARU checkpoint 9 (API server) — validated model picks + a portable routing/privacy module

---

## 0. What this is (and isn't)

This is a **research harness**, not a product. Its job is to produce two deliverables for ATARU:

1. **Validated model choices**, measured on real workloads on the actual Orin hardware.
2. **A routing + privacy module** clean enough to import into the ATARU API server.

The CLI exists to generate evidence for those two things. It is deliberately not a parallel assistant.

**Read this section before trusting anything below:** the gateway described in the original plan (LiteLLM front door) is **not built**. There is no OpenAI-compatible server, no per-request guardrail middleware, no PII detection, and no PAPILLON-style delegation. What exists is a CLI with a tiered router, a narrow credential redactor, and trace logging. Everything else in the plan is still ahead.

---

## 1. Architecture

### 1.1 What actually runs

Two containers on the Orin, via `docker-compose.yml`:

```
┌─────────────────────────────────────────────────────────┐
│ Orin host (no host installs; nothing outside /opt/ataru) │
│                                                          │
│  ┌──────────────┐         ┌────────────────────────┐    │
│  │ rag          │────────▶│ ollama                 │    │
│  │ (cli.py)     │         │ runtime: nvidia        │    │
│  │ non-root     │         │ KEEP_ALIVE=-1          │    │
│  │ /docs :ro    │         │ NUM_PARALLEL=2         │    │
│  │ /data volume │         │ models in named volume │    │
│  └──────┬───────┘         └────────────────────────┘    │
│         │                                                │
└─────────┼────────────────────────────────────────────────┘
          │ (only on explicit --deep, or WORLD tier)
          ▼
   Anthropic API (claude-opus-4-8, web search enabled for WORLD)
```

Isolation properties (these were a hard requirement — the box is shared, locked-down hardware):
- Documents mounted **read-only**; the app cannot modify or delete source files.
- App runs as a **non-root** user inside the container.
- All state (index, trace log, models) lives in **named volumes**; `docker compose down -v` removes every trace.
- No host installs, no sudo, nothing written outside `/opt/ataru/llm`.

### 1.2 Request flow

```
question
   │
   ├─▶ [1] TIER DECISION
   │      explicit flag? (--fast / --good / --deep)  → use it
   │      else heuristic pre-router (regex, ~0ms)    → fast | good | meta | world | None
   │      else LLM preprocess call (small model)     → fast | good | meta | world
   │                                                    (+ query expansion, same call)
   │
   ├─▶ meta  → answer from the INDEX directly, no model call, return
   ├─▶ world → send QUESTION TEXT ONLY to cloud + web search, return (no documents)
   │
   ├─▶ [2] RETRIEVAL (always local, all tiers)
   │      embed variants → hybrid search (vector + BM25, RRF fused) → dedupe → top-k
   │      if heuristic-routed and retrieval is weak → buy LLM query expansion, retry once
   │
   ├─▶ [3] GENERATION
   │      fast → qwen2.5:7b-instruct
   │      good → gpt-oss:20b
   │      deep → claude-opus-4-8 (credential-redacted excerpts, explicit flag only)
   │
   ├─▶ [4] ESCALATE-ON-FAILURE (auto-routed fast tier only)
   │      answer looks like a refusal AND retrieval had a strong match
   │        → retry once on gpt-oss:20b (never the cloud)
   │      strong match absent → trust the refusal, skip the retry
   │
   └─▶ [5] TRACE LOG (local JSONL: tier, path, latency, escalation outcome)
```

The key structural decision: **retrieval is identical across all tiers; only generation routes.** That keeps the tier choice cheap and reversible, and means a misroute costs seconds, never correctness of evidence.

---

## 2. Models — chosen, rejected, and why

### 2.1 Final lineup

| Role | Model | Size / residency | Rationale |
|---|---|---|---|
| Fast tier | `qwen2.5:7b-instruct` | 5.1 GB, 100% GPU | Fastest correct answers on lookups; well-grounded |
| Thorough tier | `gpt-oss:20b` | 12 GB, 100% GPU | MoE — 21B total but ~3.6B active/token; better synthesis, still fast on 64GB |
| Query expansion / classification | `qwen2.5:7b-instruct-64k` | 4.7 GB, 100% GPU | Trivial rewrite task; keep the big model free for answering |
| Embeddings | `nomic-embed-text` | 323 MB, 100% GPU | 768-dim, cheap |
| Cloud | `claude-opus-4-8` | — | Explicit `--deep` + WORLD tier only |

All four local models stay resident simultaneously (`OLLAMA_KEEP_ALIVE=-1`) — ~22 GB, comfortable on the 64 GB Orin. `ollama ps` confirms **100% GPU** for every model; nothing spills to CPU.

### 2.2 Rejected: `qwen2.5:14b-instruct`

Eliminated in a 5-query A/B/C bake-off (14B vs gpt-oss:20b vs 7B) on the Orin. The 14B was slower than the MoE gpt-oss while not being better at synthesis, and slower than the 7B while not being enough better at lookups to justify the tier. Outcome: **two tiers, not three** — 7B for lookups, gpt-oss for synthesis.

> Note: the full per-query table from that bake-off lives in the earlier working transcript, not in this repo. The verdict is solid and reproducible; the detailed numbers should be regenerated into `stress-tests.md` if they're needed as a formal deliverable.

### 2.3 Rejected: `qwen3:8b` (measured this session)

The plan suggested Qwen3-8B as a replacement for the dead 14B tier. **Tested and rejected** — it was slower on 3 of 4 queries *and* less grounded:

| Query | `qwen2.5:7b-instruct` (generate) | `qwen3:8b` (generate) |
|---|---|---|
| Dosa ingredients | 7.0 s | 15.6 s |
| VEX reduced-track cost | 7.2 s | 8.1 s |
| Gluten-free (absence check) | 6.1 s | 11.9 s |
| Rasam steps (multi-step) | 8.9 s | **25.1 s** |

Worse, on the rasam query Qwen3-8B **fabricated cooking steps not in the source**, and labelled them itself: *"(Implied step based on typical rasam preparation, though not explicitly stated in the text.)"* — a direct violation of the grounding instruction. The 7B handled the same query correctly and faster.

**Lesson worth carrying forward:** a research doc's model recommendation lost to hardware-grounded measurement. This is exactly why the Phase-0 bracket exists.

### 2.4 Tested and left at default: gpt-oss reasoning effort

Hypothesis (from the plan): gpt-oss's first-pass numbers may be inflated by hidden reasoning tokens; try `reasoning effort: low`.

Wired `RAG_GOOD_THINK` through to Ollama's `think` param and tested through the **real pipeline** (same document, same retrieval, same system prompt) on "summarize the vex academy faq":

| Setting | generate | total | All 4 required facts correct? |
|---|---|---|---|
| `low` | 24.5 s | 31.2 s | Yes |
| `high` | 18.7 s | 20.9 s | Yes |
| unset (default) | **10.5 s** | **12.6 s** | Yes |

Default won. Results are partly confounded (the `low` run paid a cold-model reload), but there is **no evidence for setting it**, so it stays unset. `ollama ps` also disproved the CPU-spillover theory — gpt-oss is 100% GPU resident. The knob remains available via `RAG_GOOD_THINK` if a future workload justifies it.

---

## 3. Routing logic

### 3.1 Two-stage router (heuristic → LLM)

Routing happens in two stages, cheapest first:

**Stage 1 — `router.py`, pure regex, ~0 ms, dependency-free.** Classifies unambiguous questions instantly and returns `None` for anything uncertain. Precedence: `meta → world → good → fast`. It is deliberately conservative: it can only make routing *faster*, never more wrong, because ambiguity falls through to stage 2.

**Stage 2 — `preprocess_query()` in `llm.py`, one LLM call on the small model.** Does classification **and** query expansion in a single prompt. These were originally two separate calls (~5.3 s + ~6.1 s); merging them halved the fixed cost, because two calls serialize on a single GPU anyway — concurrency via threads was tried and **did not help** (both calls are GPU-bound; `OLLAMA_NUM_PARALLEL=2` was verified live and the wall time stayed at the sum).

Latency evolution of the pre-generation stage:

| Stage | Cost per query |
|---|---|
| Separate `route` + `expand` calls | ~11.4 s |
| Merged `preprocess` call | 1.5 – 6.5 s |
| Heuristic hit (39/50 of real queries) | **~0.0 s** |

End-to-end effect on the Orin:

| Query type | Before | After |
|---|---|---|
| Simple lookup ("who are the co-founders") | 18.7 s | **2.5 s** |
| Personal lookup ("what did i pay") | 9.7 s | **3.2 s** |
| Collection question ("how many files indexed") | 20.9 s (and wrong) | **1.6 s** (and correct) |
| World question (weather) | 20.5 s | **14.2 s** |

### 3.2 The four tiers

- **`fast`** — `qwen2.5:7b-instruct`. Single-fact lookups, short summaries, absence checks.
- **`good`** — `gpt-oss:20b`. Multi-step instructions, comparisons, cross-document synthesis.
- **`meta`** — *no model call at all.* Questions about the collection itself (how many files, what's indexed) are answered **deterministically from the index**. This was added after observing the 7B confidently report "3 files indexed" by counting the files that happened to appear in its retrieved chunks — correct only by accident on a 3-file corpus, and catastrophically wrong at vault scale.
- **`world`** — out-of-scope questions (current time, weather, news, live prices) that personal files can never answer. Sends **question text only** to the cloud with web search enabled, and **never any document content**. Disableable via `RAG_AUTO_CLOUD=0`.

### 3.3 Escalate-on-failure (the cascade backstop)

Under auto-routing only (explicit flags are honored as-is), if a fast-tier answer matches a narrow list of refusal phrases (`looks_incomplete()`), the system considers retrying once on `gpt-oss:20b`. It **never** escalates to the cloud — `good` is the ceiling.

The important refinement: **a refusal alone is not enough to trigger a retry.** Escalation additionally requires that retrieval surfaced a *strong* semantic match (cosine distance ≤ `RAG_ESCALATE_DISTANCE`, default 0.4). Rationale: a refusal next to weak retrieval is almost always a genuine "not in the docs" case, and retrying costs 5–13 s to produce the same answer. A refusal next to a *strong* match is the suspicious case worth paying for.

This is a cheap answer to what the routing literature names as the central bottleneck — quality estimation. It uses a signal we already have (retrieval distance) rather than an extra LLM judge call.

### 3.4 Learned vs heuristic — current state

**There is no learned router.** Routing today is heuristic + LLM classification only. `traces.py` writes one JSON line per query (question, tier, heuristic-vs-LLM path, per-stage latency, escalation outcome, match count) to a local JSONL — this is the **foundation** for a learned router (RouteLLM-style similarity-weighted ranking, then matrix factorization) once a few hundred real queries accumulate. That work has not started.

### 3.5 Measured routing accuracy — 50-query evaluation

A 50-query eval was run on the Orin with tier predictions **committed in advance**:

| Metric | Result |
|---|---|
| Heuristic-vs-LLM path | **50/50** exactly as predicted (39 instant, 11 deferred) |
| Tier accuracy | 47/50 exact; the 3 differences were the LLM choosing `fast` where `good` was predicted — all defensible |
| **Personal questions kept local** | **5/5 — zero cloud leaks** |
| World tier | 8/8 correctly reached the cloud, all returned live data |
| Meta tier | 4/4 answered instantly from the index |
| Escalation | fired 4×, skipped 5× — every refusal correct |

The two hardest adversarial cases both held: *"how much are my stocks worth **right now**"* and *"what's the **weather** where **i** live"* contain live-world trigger words but stayed **100% local** because of the personal-pronoun guard.

---

## 4. Privacy / redaction gate

### 4.1 What is built

**Boundary discipline (the load-bearing design property).** Retrieval is *always* local. Only two paths reach the cloud:
- `--deep` — explicit user flag; sends retrieved excerpts + question; prints exactly which files' excerpts are leaving.
- `world` tier — sends **question text only**, never document content.

Auto-routing and escalate-on-failure are hard-capped at the local `good` tier and can never silently reach the cloud.

**Credential redaction.** `redact_credentials()` in `llm.py` runs on every string bound for the cloud (both `cloud_chat` and `cloud_world`), replacing credential-shaped substrings with `[REDACTED:<type>]` and printing a notice. Patterns: `sk-…`, `AKIA…`, `gh[pos]_…`, `xox[baprs]-…`, `Bearer …`, PEM private-key headers. High-precision by design (token *formats*, not words like "password") so it never mangles prose.

**Router-level privacy guard.** The `world` tier — the only tier where a misroute leaks text off the machine — requires a live-world topic **AND** a live-time marker **AND** no first-person possessive. Any `my`/`i`/`our`/`we` forces the question local. A world-topic word without a confident live marker defers to the LLM rather than guessing. Two unit tests encode this rule specifically so a future regex tweak fails loudly instead of silently.

### 4.2 What is NOT built

Stated plainly, because this is the biggest gap between the current state and the plan:

- **No PII detection.** No Presidio, no GLiNER, no named-entity redaction. Names, addresses, account numbers, medical details, and dates pass through `--deep` untouched.
- **No PAPILLON-style delegation.** `--deep` still sends **raw retrieved excerpts** to the cloud. The validated pattern — local model writes a sanitized sub-task → cloud solves only that → local model recombines with private evidence that never left — is designed but not implemented.
- **No secret scanner beyond regex.** Code/config leakage (the 31.3% finding in the literature) is not addressed; the credential regexes are a first increment, not a solution.
- **No output scanning.** Responses are not scanned before display.
- **No cumulative-disclosure budget.** Each query is evaluated independently; nothing tracks what has already been exposed across many "individually safe" prompts.

### 4.3 Known verification gap

⚠️ **The credential redaction has passed offline unit tests but has never been exercised end-to-end on the Orin.** The `--deep` test with a synthetic key was not run. It should be, before anyone relies on it.

---

## 5. Code structure

~2,050 lines of Python, 13 commits. Flat layout, no package nesting.

### 5.1 Reusable / importable (the ATARU handoff candidates)

| File | Dependencies | What it is |
|---|---|---|
| **`router.py`** | **none** (stdlib `re` only) | Heuristic pre-router. Deliberately dependency-free so it can be imported into any host system without dragging in ollama or this harness. **This is the cleanest graduation candidate.** |
| **`traces.py`** | `config` | Local JSONL trace logger. Fails silently by design — logging must never break a query. |
| `config.py` | stdlib | All tunables, every one overridable by env var. |

### 5.2 Mixed — reusable logic living in a module with an ollama import

`llm.py` holds several pure functions that are good graduation candidates but currently sit next to the Ollama wrappers:
- `redact_credentials(text) -> (clean, count)` — pure
- `looks_incomplete(answer) -> bool` — pure
- `retrieval_supports_escalation(matches) -> bool` — pure
- `preprocess_query(question) -> (tier, variants)` — needs Ollama
- `chat` / `cloud_chat` / `cloud_world` / `embed` / `expand_query` — model wrappers

**Recommended refactor before handoff:** extract the four pure functions into the same importable module as `router.py`. That would give ATARU a single dependency-free `routing + privacy` module — which is precisely the deliverable the plan asks for.

### 5.3 CLI-only / harness

| File | Role |
|---|---|
| `cli.py` | `index` / `query` / `list` / `serve`. **Monolithic** — the tier logic is inline in `main()`, which is the main obstacle to a clean lift-and-drop. |
| `indexer.py`, `chunker.py`, `extractors.py` | Incremental indexing, chunking, PDF/docx/xlsx + OCR extraction |
| `store.py` | LanceDB: vector + BM25 full-text, RRF fusion, chunk dedup |
| `rerank.py` | Optional cross-encoder reranker (**off by default** — regressed structured lookups) |
| `agent.py`, `tools.py` | Tool-calling agent with risk-gated tools |
| `app.py`, `mcp_server.py` | FastAPI `/query` endpoint; MCP server |

### 5.4 Tests

`test_router.py` + `test_helpers.py` — **30 offline unit tests**, stdlib `unittest`, no Ollama or network, run in ~50 ms:

```
python -m unittest          # 30 tests, OK
```

Coverage: heuristic routing across all four tiers, the world-tier privacy guards, refusal detection, the escalate distance gate, query dedup, trace logging. Verified passing both on macOS and inside the container on the Orin.

**Note:** `docker compose build rag` is mandatory after any code change — `git pull` alone does not update the running container (the Dockerfile bakes code in at build time). The test suite is the natural pre-deploy gate.

---

## 6. Status

### Done and verified on the Orin

- Containerized deployment (read-only docs, non-root, named volumes, GPU passthrough)
- Phase 0 model bracket: 14B eliminated, Qwen3-8B rejected, 7B + gpt-oss:20b validated, reasoning-effort knob tested and left default
- Four-tier routing (fast / good / meta / world) with manual override flags
- Two-stage router: regex pre-filter → LLM classifier, ~7× faster on simple lookups
- Escalate-on-failure with retrieval-distance gate
- World-tier auto-cloud with web search, question-text-only
- Credential redaction before cloud calls *(unit-tested; **not** verified end-to-end)*
- Local query-trace logging
- 30-test offline regression suite
- 50-query evaluation: zero routing errors, zero privacy leaks

### In progress / immediate next

1. **Verify credential redaction end-to-end on the Orin** (one `--deep` command with a synthetic key).
2. **Whole-collection retrieval mode** — the highest-impact issue the 50-query eval surfaced (see §7).

### Planned, not started

3. Extract `router.py` + the pure helpers into one importable module for checkpoint 9.
4. PII detection (Presidio or GLiNER) as a separate, stricter gate than credentials.
5. PAPILLON-style delegation for `--deep` (sanitized sub-task → cloud → local recombination).
6. Output scanning before display.
7. Learned router trained on accumulated traces.
8. Energy/cost accounting (`tegrastats` gives real watts on the Jetson).

---

## 7. Deviations from the plan, and open questions

### Deviations

| Plan said | What happened | Why |
|---|---|---|
| Phase 1: LiteLLM gateway | **Not built.** CLI only. | Routing/privacy logic was the actual deliverable; a gateway adds a dependency without producing evidence. Still the right move before multi-client use. |
| Qwen3-8B replaces the dead 14B | **Rejected on measurement.** | Slower on 3/4 queries and fabricated content. Kept `qwen2.5:7b-instruct`. |
| Re-run gpt-oss at reasoning effort = low | **Tested; no win.** Left at default. | Default was fastest and equally correct. |
| Start router with similarity-weighted ranking, move to matrix factorization | **Neither.** Regex + LLM classification. | No trace data existed to train on. Trace logging now exists; SW-ranking/MF is the natural next step. |
| Router doubles as the redaction guard | **Partially.** | The router gates *cloud eligibility* (world tier, personal-pronoun guard), but there is no redaction pipeline behind it beyond credentials. |

### Open questions

1. **Whole-collection retrieval.** The 50-query eval exposed a real defect: "summarize every document" retrieved chunks clustered in 1–2 files, so the model summarized only what it received (one query summarized 2 of 3 docs; another honestly refused, saying it only had one file). Routing was correct; **top-k retrieval structurally cannot serve breadth queries.** Needs a mode that pulls ≥1 chunk per indexed document before synthesis. This is the same insight as the meta tier, one level up.

2. **Nearby-fact substitution on the small model.** Asked "what did *I* pay for the vex academy," the 7B answers with the published tuition prices as if that's what the user paid. Asked which college of engineering is affiliated, it answers "UC Berkeley" (the location, not a college). gpt-oss handles both correctly. Prompt-level guardrails were tried and **did not bind the 7B** — this needs either routing (send these to `good`) or a verifier pass, not more prompt text.

3. **How conservative should the WORLD tier be?** It is the only automatic path to the cloud. Currently: topic + live-marker + no personal pronoun. Zero leaks across 50 queries, but the guard is regex, and a 7B classifier handles the fallback. Does ATARU want auto-cloud at all, or should `--deep` remain the only cloud path?

4. **No greeting/chitchat path.** "hi" gets treated as a document query and awkwardly refused.

5. **Escalation false-positive tax.** The distance gate cut most of it, but escalation still occasionally fires on correct refusals (~6–13 s for an identical answer). Acceptable today; worth revisiting with a better quality estimator.

6. **Citation noise.** The 7B occasionally cites the wrong file inline while the Sources list is correct.

---

## 8. Mapping against OpenJarvis

Reviewed at commit depth-1 clone: **2,033 files, ~273K lines of Python**, plus Rust (PyO3) and a Tauri desktop app. Stanford-affiliated (Hazy Research / Scaling Intelligence Lab), arXiv paper, Apache 2.0.

Their thesis independently validates ours: *local models already handle 88.7% of single-turn chat and reasoning queries.* They optimize **quality × cost × energy**. We optimize **quality × latency × privacy**. That difference is the whole story of this comparison.

### 8.1 `engine/` — multi-engine routing, cloud cost tracking

**What they have:** 10+ backends (`ollama.py`, `cloud.py`, `litellm.py`, `multi.py`, `gemma_cpp.py`, `apple_fm_shim.py`, `nexa_shim.py`, `openai_compat_engines.py`), auto GPU detection and engine recommendation, plus real cost/energy accounting (`evals/core/pricing.py`, `agents/hybrid/_prices.py`, `_energy.py`, and `bench/energy.py` measuring joules-per-token at thermal equilibrium).

**Us:** Ollama + Anthropic only. No cost tracking, no energy measurement, no engine abstraction.

**Verdict:** **OpenJarvis is far deeper.** Nothing of ours to contribute here.

**But — the notable gap:** I grepped `engine/cloud.py` for redaction/sanitization and found **none**. Their cloud path sends whatever it's given. Their entire multi-engine router has **no privacy dimension at all** — model selection is quality/cost/preference only. That is the seam where our work is genuinely additive.

**Worth adopting from them:** energy/cost accounting per query. On the Jetson, `tegrastats` provides real watts, which would make our routing tri-objective (latency × quality × privacy × energy) instead of dropping the fourth axis.

### 8.2 `intelligence/` — model catalog

**What they have:** thin — `model_catalog.py` and an `__init__.py`. A registry of model specs (parameter counts etc.) feeding the router's size comparisons.

**Us:** `config.py` env-var constants. Simpler, less general — but it holds *validated* picks with benchmark evidence behind them, whereas a catalog holds *declared* capabilities.

**Verdict:** roughly equivalent in ambition; theirs is more general, ours is more evidence-backed for one specific box. **Neither contributes to the other.**

### 8.3 `learning/` — trace-based optimization

**What they have:**
- `routing/complexity.py` — a zero-cost weighted-signal complexity scorer (length 0–0.20, code/math domain 0–0.25, reasoning 0–0.25, multi-part 0–0.15, creative 0–0.15) mapping to five tiers with token budgets.
- `routing/router.py` — `HeuristicRouter` with ordered rules (urgency → code → math → low complexity → high complexity → default).
- `routing/learned_router.py` — `LearnedRouterPolicy`: query-class → model map learned from traces, confidence-gated at `min_samples = 5`, with `update_from_traces()`.
- `traces/` (collector, store, analyzer), plus `optimize/`, `spec_search/`, `training/`.

**Us:** their heuristic-scorer *pattern* is what inspired our `router.py` — that borrowing is explicit and acknowledged. Our trace log records a compatible shape (question, tier, model, latency, outcome). We have **no learned router**.

**Verdict:** **OpenJarvis is deeper on learning.** Their learned router is roughly two steps ahead of us, and it's the direction we should follow.

**Where ours goes deeper — two genuinely novel pieces:**

1. **The `meta` tier.** I found no OpenJarvis equivalent. Questions *about the collection* (how many documents, what's indexed) are answered deterministically from the index with **no model call** — because we measured a small model confidently miscounting by tallying whatever files appeared in its retrieved chunks. This is a routing class their taxonomy (trivial→very_complex) doesn't express: a query that shouldn't reach a model at all.

2. **Retrieval-distance-gated escalation.** Their own cited literature names quality estimation as the central bottleneck of cascade routing. We use retrieval distance — a signal already computed, costing nothing — as a cheap proxy for "is a refusal trustworthy?" I saw no equivalent in their cascade code.

### 8.4 `security/` + guardrails — prompt sanitization

**What they have:** the most developed module of the four — `injection_scanner.py` (regex threat patterns with severity levels), `credential_stripper.py` (6 token-format regexes), `taint.py`, `ssrf.py`, `subprocess_sandbox.py`, `file_policy.py`, `capabilities.py`, `rate_limiter.py`, `signing.py`, `audit.py`, `boundary.py`, `guardrails.py`.

**Us:** container isolation (read-only mounts, non-root, named volumes) plus `redact_credentials()` — which is a direct port of their credential-stripper idea, acknowledged as such.

**Verdict:** **OpenJarvis is much deeper on breadth of hardening.** We should adopt their injection scanner — a poisoned document in a vault could carry prompt injections through retrieval, and we have no defense against that today.

**Where ours goes deeper — the one real moat:** their security module protects the *host and the agent*. It does not protect the *user's data from the cloud provider*. There is no sanitize-before-cloud gate, no cloud-eligibility policy, no boundary preventing raw vault content from reaching a third-party API. Ours has: a hard architectural boundary (retrieval always local; auto-routing capped below cloud), a cloud-eligibility gate at the router (WORLD tier), a question-text-only cloud path that never attaches documents, and a personal-pronoun guard with regression tests.

That is a **different axis of security than anything in their `security/`** — and given they're building a *personal* AI over private data, it's arguably a gap in their design, not just a difference in scope.

### 8.5 Upstream contribution candidates

Ranked by how likely they'd be accepted and how little they'd disturb OpenJarvis's architecture:

1. **Privacy-aware cloud-eligibility routing.** A routing label that gates *whether the cloud is permissible*, distinct from *which model is best* — with the personal-pronoun guard as the conservative default. Small, self-contained, and fills a real hole: their router has no privacy dimension and their cloud engine has no sanitization. Highest-value contribution.
2. **The collection-meta routing class.** Queries about the corpus answered from the index rather than a model. Small, general, and prevents a confident-wrong failure mode that gets worse as corpora grow.
3. **Retrieval-distance-gated escalation.** A near-free quality estimator for cascade routing, addressing a bottleneck their own literature review names.
4. **The credential redactor as an *egress* gate.** They have the stripper; applying it on the cloud path (not only to tool output) is a one-line placement change with real benefit.

### 8.6 Why not just adopt OpenJarvis

Three practical blockers for this deployment, all of which are *policy or configuration* rather than technical impossibilities — worth stating precisely so the decision can be revisited:

- **Install model:** their `curl … | bash` installer writes uv, a venv, Ollama, and models onto the host. The Orin's rule is that nothing is installed on the host; everything runs in containers under `/opt/ataru/llm`. (Changeable if Arya decides to.)
- **Telemetry on by default:** anonymous usage events (install/lifecycle counts, timings, feature names — one random UUID, no chat content) ship to a PostHog instance operated by the OpenJarvis team: currently PostHog Cloud US, with a stated production target of `analytics.openjarvis.ai` on Hetzner US-East, 365-day retention. There is an opt-out and an ID-reset command. The issue isn't malice — it's default outbound traffic from a deliberately firewalled box.
- **Privileged setup:** desktop app and native-Windows service paths expect elevated system access; the `samarth` account has no sudo by design. (Also changeable.)

Beyond policy: 273K lines is the opposite of the clean, importable checkpoint-9 module ATARU needs. **Recommendation: borrow ideas, not the framework** — which is what has been done.

---

## 9. One-paragraph summary for someone in a hurry

A containerized, local-first RAG assistant on a Jetson Orin with a four-tier answer router (7B fast / gpt-oss:20b thorough / index-only collection questions / cloud for out-of-scope world questions). Model picks were decided by measurement on the real hardware, not by spec sheets — the 14B and Qwen3-8B were both tested and rejected. Routing is two-stage: a zero-cost regex pre-filter handles ~78% of real queries instantly, and only ambiguous ones pay for an LLM classification call, which cut simple lookups from ~19 s to ~2.5 s. A retrieval-distance-gated backstop retries weak local answers one tier up but never reaches the cloud. Privacy is enforced architecturally rather than by policy: retrieval is always local, auto-routing is hard-capped below the cloud, the only automatic cloud path sends question text with no document content, and a personal-pronoun guard (with regression tests) keeps "my"/"i" questions local — verified across a 50-query evaluation with zero routing errors and zero leaks. Credential redaction runs before any cloud call. **Still ahead: PII detection, PAPILLON-style delegation, whole-collection retrieval, and a learned router trained on the trace log that is now being collected.**
