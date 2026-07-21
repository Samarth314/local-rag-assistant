"""Local query-trace log: one JSON line per query, appended under DATA_DIR.

Strictly local (the log lives on the data volume next to the index; nothing
is transmitted anywhere). This is the raw material for routing-accuracy
stats, latency tracking, and -- once a few hundred real queries accumulate --
training a learned router to replace the hand-tuned classifier prompt.

Logging must never break a query: every failure is swallowed.
"""

import json
import time

import config


def log(record: dict) -> None:
    """Append one trace record to the JSONL log (no-op if RAG_LOG=0)."""
    if not config.LOG_ENABLED:
        return
    try:
        record.setdefault("ts", round(time.time(), 3))
        config.LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(config.LOG_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:
        pass  # never let logging take down a query
