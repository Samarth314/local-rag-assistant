# Items done — router tuning, PAPILLON delegation, retrieval module

Hey Arya — router tuning, PAPILLON delegation, and the retrieval module are all done and on `main` (78 tests green). Rundown + what I need from you on each.

## 1. Router tuning (Task A) — `routing.py` @ `e1966be`

Added the three you flagged: stopword filtering, a confidence-floor + thin-margin → `records` fallback, and a deterministic tie-break (score desc, then name — never dict order). Your exact case is fixed: *"when was I admitted to Stanford"* now falls back to `records@0.25` instead of picking comms@0.286. Tests built from the manifest `route_examples` + synthetic hard/OOD/noise queries, and pure noise can't clear the floor.

**Need from you:** the `b3/` contract files (`policy.py`, `registry.py`, the 5 `*.agent.json`, `eval/contract_test.py`) so I can tune against the real registry and prove ≥90% — or run `contract_test.py --policy routing.SamarthRouter` on your side and promote. Seam unchanged: `RouterPolicy.route()`.

## 2. PAPILLON delegation (Task B) — `delegate_deep()` in `llm.py` + `privacy.py` @ `13e32ab`

Interface: in `(query, local_context)` → out `(answer, record)`, where `record.sent_to_cloud` is the exact sanitized payload that left the box. Flow: local model abstracts → gate strips any leaked credential/PII → cloud solves only the abstraction → local recombines with the evidence that never left → output scan. Proven with a payload-diff test over a synthetic secret corpus (keys, SSN, card, account, email, phone, IP): none reach the cloud. Models are injected in tests, so it runs with no live LLM.

**Need from you:** (a) sign off on that egress signature before you wire it behind ATARU's sanitizer; (b) pick the NER backend (GLiNER vs Presidio) — names/free-form like lab values go through a pluggable NER hook that isn't wired to a real backend yet; (c) heads-up that answer-quality preservation is behavioral, so it needs one real-model run on the deployment box to confirm.

## 3. Retrieval → ataru-search (Task 3) — `retrieval.py` @ `b07def8`

Dependency-light module (no vector DB — operates on candidate dicts): RRF fusion, dedup, query expansion, distance-gated escalation, and the **whole-collection breadth path** that fixes the top-k gap — "summarize every document" now returns one chunk per document instead of clustering in one file. Recall test proves it recovers every doc where naive top-k recovers one. Module docstring is the query→results spec.

**Need from you:** port the techniques into `ataru-search`; and confirm `ataru-search` exposes a per-result distance/score — the distance-gate graduation depends on it, and it's what decides whether my LanceDB store retires cleanly.

---

I've got opinions on the §8 items (keep WORLD/auto-cloud, retire LanceDB into ataru-search, whole-collection solved once in shared retrieval, energy accounting later, 7B/`native_react` stays default). Ping me and we can integrate + re-measure.
