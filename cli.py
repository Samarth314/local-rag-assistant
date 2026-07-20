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

        from llm import (chat, cloud_chat, embed, expand_query, looks_incomplete,
                         route_query)
        import store
        import config

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

        # Decide the tier. Explicit flags win; otherwise auto-route between the
        # fast and thorough local models (never the cloud -- that's --deep only).
        if deep:
            tier = "deep"
        elif good:
            tier = "good"
        elif fast:
            tier = "fast"
        elif config.AUTOROUTE:
            tier = route_query(question)  # "fast" or "good"
            stages.append(("route", time.perf_counter() - t)); t = time.perf_counter()
            print(f"[auto] {tier} tier "
                  f"({config.GOOD_MODEL if tier == 'good' else config.CHAT_MODEL})\n")
        else:
            tier = "fast"

        # The escalate-on-failure backstop only catches auto-routed fast answers:
        # an explicit --fast/--good/--deep is honored as-is, and it never crosses
        # to the cloud (good is the ceiling for auto-escalation).
        escalatable = (
            config.ESCALATE_ON_FAILURE and config.AUTOROUTE
            and not (deep or good or fast) and tier == "fast"
        )

        variants = expand_query(question)
        stages.append(("expand", time.perf_counter() - t)); t = time.perf_counter()

        query_variants = [(embed(q), q) for q in variants]
        stages.append(("embed", time.perf_counter() - t)); t = time.perf_counter()

        matches = store.search(query_variants, config.TOP_K, rerank_query=question)
        stages.append(("search", time.perf_counter() - t)); t = time.perf_counter()

        context_chunks = [f"[{m['path']}]\n{m['text']}" for m in matches]
        system_prompt = (
            "You are a personal search assistant with access to the user's own "
            "files. Answer only from the excerpts provided."
        )
        if tier == "deep":
            files = sorted({Path(m["path"]).name for m in matches})
            print(f"[deep] Escalating to {config.CLOUD_MODEL} -- sending excerpts "
                  f"from {len(files)} file(s): {', '.join(files)}\n")
            try:
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
            t = time.perf_counter()
            print(f"\n[escalate] fast answer looked incomplete -- retrying on "
                  f"{config.GOOD_MODEL}\n")
            gen_model = config.GOOD_MODEL
            answer = chat(system_prompt, context_chunks, question, stream=True,
                          model=gen_model, think=config.GOOD_MODEL_THINK)
            stages.append((f"escalate ({gen_model})", time.perf_counter() - t))

        print("\nSources:")
        for m in matches:
            print(f"  - {m['path']} (chunk {m['chunk_index']})")

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
