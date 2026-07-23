# SamarthRouter — how it registers as an OpenJarvis RouterPolicy

Deliverable note for Task A. Target contract: `records/work/openjarvis/dispatch/ROUTER_INTERFACE.md` (commit `0cb22e6`).

## What ships

Two dependency-free (stdlib-only) modules:

- **`routing.py`** — `SamarthRouter(RouterPolicy)` (the agent-axis dispatcher) + the tier-axis helpers (`heuristic_route`, `looks_incomplete`, `retrieval_supports_escalation`).
- **`privacy.py`** — the cloud-eligibility gate (`sanitize_for_cloud`, `detect_pii`, `scan_output`).

> I split into two files by concern (dispatch vs. privacy) rather than the one file the brief mentioned, because that maps to your own §3 framing — the two things I own are the *dispatch* and the *cloud-eligibility* axes. Both are stdlib-only; concatenate them if you prefer a single drop.

## Integration — 3 steps on your end

1. **Swap the shim for your real contract.** `routing.py` has a block marked `INTEGRATION SHIM` (a local mirror of `RouteDecision` / `RouterPolicy` so it self-tests standalone). Delete it and use your real imports:
   ```python
   from policy import RouterPolicy, RouteDecision   # your b3 ABC + dataclass
   ```
   Nothing in `SamarthRouter` changes — it only ever referenced the documented fields.

2. **Drop `routing.py` where dispatch.py can import it**, then point `--policy` at it:
   ```bash
   $PY eval/contract_test.py --policy routing.SamarthRouter     # the green/red gate
   $PY dispatch.py --policy routing.SamarthRouter --route-only "What is my net worth?"
   $PY dispatch.py --policy routing.SamarthRouter "Any email from my landlord?"
   ```
   No install step — it's stdlib-only.

3. **That's the entire surface.** `SamarthRouter.route(query) -> RouteDecision` is the one method; agents/tools/skills are untouched.

## How it satisfies the contract + invariants

- **Reads the registry, never hardcodes.** `route()` scores the query against every agent's `route_keywords` / `route_examples` / `description` from `self.agents` (handed in by your base constructor). Add or rename an agent and it adapts with zero code change. Uses `getattr` with defaults, so minor `AgentSpec` field differences won't break it.
- **Invariant #1 (registry name / records fallback):** returns the top-scoring agent, or `records` when no agent scores. Tested (`test_samarth_router.py::TestInvariants`).
- **Invariant #2/#3 (no scope widening / no gated tools):** `route()` only picks a name; it never reads or attaches tools. Verified it doesn't mutate the registry.
- **Invariant #4 (model-agnostic):** no tier/model choice inside `route()`. My tier logic (`heuristic_route`, fast/good/meta/world) stays separate and downstream — it maps to your per-agent `model` / `model_ceiling`, applied by the runner, not the router.

## What I could NOT verify (needs your files)

I built against the contract you **pasted** in §7, not the actual `policy.py` / `registry.py` / `contract_test.py`. So:
- I can't run `contract_test.py` to confirm **≥90%** — send me the `b3/` tree (or `eval/` + `dispatch/` + `registry.py` + the 5 `*.agent.json`) and I'll tune `route()` against the real gate and the real `route_keywords`.
- The scoring weights (keyword 2.0 / example-overlap 0.5 / description 0.25) are sensible defaults; they'll want one tuning pass against your labeled set once I can run the gate.

## Open interface question (flagged in my file request)

Your §7 skeleton is `route(self, query: str)`. If `route()` also receives retrieval results, my `retrieval_supports_escalation` distance-gate can live inside the decision; if it's query-only, that stays in the downstream tier layer. Tell me which and I'll place it correctly.
