"""Command-line entry point.

Usage:
    python cli.py index <directory> [--limit N]
    python cli.py query "<question>" [--fast|--good|--deep] [--timing]
    python cli.py list
    python cli.py serve

Answer tiers (all retrieval stays local; only --deep leaves the machine):
  (no flag)  auto-route: a cheap classifier picks fast vs good per question;
             if the fast answer looks incomplete, it auto-retries once on good
  --fast     force the small/fast local model (CHAT_MODEL)
  --good     force the stronger local model (GOOD_MODEL)
  --deep     escalate to Claude in the cloud (needs ANTHROPIC_API_KEY)
--timing prints a per-stage time breakdown.
"""

import sys


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    command = sys.argv[1]

    if command == "index":
        from indexer import index_directory

        if len(sys.argv) < 3:
            print("Usage: python cli.py index <directory> [--limit N]")
            sys.exit(1)

        limit = None
        if "--limit" in sys.argv:
            limit = int(sys.argv[sys.argv.index("--limit") + 1])

        stats = index_directory(sys.argv[2], limit=limit)
        print(f"\nDone. Scanned {stats['scanned']} files, "
              f"indexed {stats['indexed']} changed, "
              f"skipped {stats['duplicates']} duplicates, "
              f"removed {stats['removed']} deleted, "
              f"{stats['errors']} errors.")

    elif command == "query":
        import time
        from pathlib import Path

        from llm import (chat, cloud_chat, cloud_world, delegate_deep, embed,
                         expand_query, looks_incomplete, preprocess_query,
                         retrieval_supports_escalation)
        from routing import heuristic_route
        import store
        import config
        import traces

        flags = {"--deep", "--good", "--fast", "--timing"}
        args = [a for a in sys.argv[2:] if a not in flags]
        deep = "--deep" in sys.argv[2:]
        good = "--good" in sys.argv[2:]
        fast = "--fast" in sys.argv[2:]
        timing = "--timing" in sys.argv[2:]
        if not args:
            print('Usage: python cli.py query "<question>" [--fast|--good|--deep] [--timing]')
            sys.exit(1)
        question = args[0]
        if store.count_rows() == 0:
            print("No indexed content yet. Run `python cli.py index <directory>` first.")
            return

        stages: list[tuple[str, float]] = []
        t = time.perf_counter()
        t_start = t

        # Trace record, filled in as the query flows through and written on
        # every exit path. Strictly local (lives next to the index).
        trace = {"question": question, "route": "auto", "heuristic": False,
                 "escalated": False, "escalate_skipped": False}

        def _finish_trace(tier_final, gen_model=None, n_matches=0, answer=""):
            trace.update(
                tier=tier_final, model=gen_model,
                stages={name: round(d, 2) for name, d in stages},
                total_s=round(time.perf_counter() - t_start, 2),
                n_matches=n_matches, answer_words=len(answer.split()),
            )
            traces.log(trace)

        # Decide the tier. Explicit flags win. Otherwise try the instant
        # heuristic pre-router first (regex, ~0ms); only ambiguous questions
        # pay for the LLM preprocess call (which also does query expansion --
        # heuristic-routed queries search on the raw question and expand
        # on demand only if retrieval comes back weak).
        if deep:
            tier = "deep"
            trace["route"] = "flag"
        elif good:
            tier = "good"
            trace["route"] = "flag"
        elif fast:
            tier = "fast"
            trace["route"] = "flag"
        elif config.AUTOROUTE:
            tier = heuristic_route(question) if config.HEURISTIC_ROUTE else None
            if tier is not None:
                trace["heuristic"] = True
                variants = [question]
                stages.append(("route (heuristic)", time.perf_counter() - t)); t = time.perf_counter()
            else:
                tier, variants = preprocess_query(question)
                stages.append(("preprocess", time.perf_counter() - t)); t = time.perf_counter()

            # Out-of-scope world questions (current time/weather/news): the
            # user's files can't answer these, so retrieval is skipped and
            # ONLY the question text goes to the cloud -- no document content
            # ever attaches to this path. Falls back to the local fast tier
            # if auto-cloud is disabled or no API key is configured.
            if tier == "world":
                import os

                cloud_ok = False
                if config.AUTO_CLOUD and os.environ.get("ANTHROPIC_API_KEY"):
                    print(f"[auto] out-of-scope question -- asking "
                          f"{config.CLOUD_MODEL} with web search (question "
                          f"text only; no documents sent)\n")
                    try:
                        answer = cloud_world(question)
                        cloud_ok = True
                    except Exception as e:
                        msg = str(e).lower()
                        if "authentication" in msg or "api_key" in msg or "x-api-key" in msg:
                            print("\n[cloud unavailable] the Anthropic API key was "
                                  "rejected (invalid or expired). Update it in .env; "
                                  "answering locally for now.\n")
                            tier = "fast"  # graceful fall-through, no crash
                        else:
                            raise
                if cloud_ok:
                    stages.append((f"cloud ({config.CLOUD_MODEL})",
                                   time.perf_counter() - t))
                    if timing:
                        total = sum(d for _, d in stages)
                        parts = " | ".join(f"{name}: {d:.1f}s" for name, d in stages)
                        print(f"\n[timing] {parts} | total: {total:.1f}s")
                    _finish_trace("world", config.CLOUD_MODEL, 0, answer)
                    return
                # No cloud (disabled, no key, or key rejected) -- answer locally.
                # The local model will honestly say the docs don't cover it.
                if tier == "world":
                    tier = "fast"
                t = time.perf_counter()  # reset so the local stages time cleanly

            # Collection-level questions (file counts, inventory) are answered
            # from the index itself -- generation over a partial retrieval
            # sample can only guess at these, and small models guess badly.
            if tier == "meta":
                from indexer import list_indexed_paths

                print("[auto] collection question -- answering from the index "
                      "directly (no model call)\n")
                paths = list_indexed_paths()
                for p in paths:
                    print(f"  - {p}")
                print(f"\n{len(paths)} files indexed.")
                if timing:
                    total = sum(d for _, d in stages)
                    parts = " | ".join(f"{name}: {d:.1f}s" for name, d in stages)
                    print(f"\n[timing] {parts} | total: {total:.1f}s")
                _finish_trace("meta", None, len(paths))
                return

            via = " via heuristic" if trace["heuristic"] else ""
            print(f"[auto] {tier} tier "
                  f"({config.GOOD_MODEL if tier == 'good' else config.CHAT_MODEL})"
                  f"{via}\n")
        else:
            tier = "fast"

        # The escalate-on-failure backstop only catches auto-routed fast answers:
        # an explicit --fast/--good/--deep is honored as-is, and it never crosses
        # to the cloud (good is the ceiling for auto-escalation).
        escalatable = (
            config.ESCALATE_ON_FAILURE and config.AUTOROUTE
            and not (deep or good or fast) and tier == "fast"
        )

        if not config.AUTOROUTE or deep or good or fast:
            variants = expand_query(question)
            stages.append(("expand", time.perf_counter() - t)); t = time.perf_counter()

        query_variants = [(embed(q), q) for q in variants]
        stages.append(("embed", time.perf_counter() - t)); t = time.perf_counter()

        matches = store.search(query_variants, config.TOP_K, rerank_query=question)
        stages.append(("search", time.perf_counter() - t)); t = time.perf_counter()

        # Heuristic-routed queries searched on the raw question alone (no
        # LLM expansion). If that came back with no strong semantic match,
        # buy the expansion after all and search once more -- expansion on
        # demand instead of on every query.
        if trace["heuristic"] and tier in ("fast", "good"):
            has_strong = any(
                m.get("_distance") is not None and m["_distance"] <= config.MAX_DISTANCE
                for m in matches
            )
            if not has_strong:
                variants = expand_query(question)
                query_variants = [(embed(q), q) for q in variants]
                retried = store.search(query_variants, config.TOP_K,
                                       rerank_query=question)
                if retried:
                    matches = retried
                stages.append(("expand (weak retrieval)", time.perf_counter() - t))
                t = time.perf_counter()

        context_chunks = [f"[{m['path']}]\n{m['text']}" for m in matches]
        system_prompt = (
            "You are a personal search assistant with access to the user's own "
            "files. Answer only from the excerpts provided."
        )
        if tier == "deep":
            files = sorted({Path(m["path"]).name for m in matches})
            if config.DELEGATE_DEEP:
                print(f"[deep] Delegated mode: a sanitized sub-task (no document "
                      f"content) goes to {config.CLOUD_MODEL}; excerpts from "
                      f"{len(files)} file(s) stay local.\n")
            else:
                print(f"[deep] Escalating to {config.CLOUD_MODEL} -- sending excerpts "
                      f"from {len(files)} file(s): {', '.join(files)}\n")
            try:
                if config.DELEGATE_DEEP:
                    answer, record = delegate_deep(question, context_chunks,
                                                   system_prompt=system_prompt)
                    from llm import summarize
                    print(answer)
                    print(f"\n[delegate] sent to cloud (no documents): "
                          f"{record['sent_to_cloud']!r}")
                    if record["redactions"]:
                        print(f"[delegate] gate stripped: "
                              f"{summarize(record['redactions'])}")
                else:
                    answer = cloud_chat(system_prompt, context_chunks, question)
            except Exception as e:
                if "authentication" in str(e).lower() or "api_key" in str(e).lower():
                    print("Cloud escalation needs an Anthropic API key.\n"
                          "Set it with:  export ANTHROPIC_API_KEY=sk-ant-...\n"
                          "(Get a key at https://platform.claude.com -- then re-run "
                          "this same command.)")
                    sys.exit(1)
                raise
            gen_model = config.CLOUD_MODEL
        else:
            gen_model = config.GOOD_MODEL if tier == "good" else config.CHAT_MODEL
            think = config.GOOD_MODEL_THINK if tier == "good" else None
            answer = chat(system_prompt, context_chunks, question, stream=True,
                          model=gen_model, think=think)
        stages.append((f"generate ({gen_model})", time.perf_counter() - t))

        # Backstop: if auto-routing chose fast and the answer looks like the
        # small model couldn't answer -- but retrieval did surface relevant
        # excerpts (so the info is probably there) -- retry once on the good
        # tier. Bounded to a single local retry; never touches the cloud.
        if escalatable and matches and looks_incomplete(answer):
            if retrieval_supports_escalation(matches):
                t = time.perf_counter()
                print(f"\n[escalate] fast answer looked incomplete -- retrying on "
                      f"{config.GOOD_MODEL}\n")
                gen_model = config.GOOD_MODEL
                answer = chat(system_prompt, context_chunks, question, stream=True,
                              model=gen_model, think=config.GOOD_MODEL_THINK)
                stages.append((f"escalate ({gen_model})", time.perf_counter() - t))
                trace["escalated"] = True
            else:
                print(f"\n[escalate] fast answer looked incomplete, but no "
                      f"strong-relevance match was retrieved -- trusting the "
                      f"refusal instead of retrying\n")
                trace["escalate_skipped"] = True

        print("\nSources:")
        for m in matches:
            print(f"  - {m['path']} (chunk {m['chunk_index']})")

        _finish_trace(tier, gen_model, len(matches), answer)

        if timing:
            total = sum(d for _, d in stages)
            parts = " | ".join(f"{name}: {d:.1f}s" for name, d in stages)
            words = len(answer.split())
            print(f"\n[timing] {parts} | total: {total:.1f}s"
                  f"  ({words} words, ~{words / max(stages[-1][1], 0.001):.1f} words/s generation)")

    elif command == "list":
        from indexer import list_indexed_paths

        paths = list_indexed_paths()
        for p in paths:
            print(p)
        print(f"\n{len(paths)} files indexed.")

    elif command == "serve":
        import uvicorn

        uvicorn.run("app:app", host="0.0.0.0", port=8000, reload=False)

    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
