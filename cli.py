"""Command-line entry point.

Usage:
    python cli.py index <directory> [--limit N]
    python cli.py query "<question>" [--deep] [--timing]
    python cli.py list
    python cli.py serve

--deep escalates the question to Claude in the cloud: retrieval still runs
locally, but the retrieved excerpts and question are sent to the Anthropic API
(requires ANTHROPIC_API_KEY).
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

        from llm import chat, cloud_chat, embed, expand_query
        import store
        import config

        flags = {"--deep", "--timing"}
        args = [a for a in sys.argv[2:] if a not in flags]
        deep = "--deep" in sys.argv[2:]
        timing = "--timing" in sys.argv[2:]
        if not args:
            print('Usage: python cli.py query "<question>" [--deep] [--timing]')
            sys.exit(1)
        question = args[0]
        if store.count_rows() == 0:
            print("No indexed content yet. Run `python cli.py index <directory>` first.")
            return

        stages: list[tuple[str, float]] = []
        t = time.perf_counter()

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
        if deep:
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
            answer = chat(system_prompt, context_chunks, question, stream=True)
            gen_model = config.CHAT_MODEL
        stages.append((f"generate ({gen_model})", time.perf_counter() - t))

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
