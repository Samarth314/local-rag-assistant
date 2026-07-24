# Local RAG Assistant

A private, local-first RAG (retrieval-augmented generation) assistant for your
personal documents. Everything runs on your own machine — indexing, embedding,
search, and answering — with an optional, explicit escalation path to Claude in
the cloud for hard questions.

## Features

- **Hybrid retrieval**: semantic (vector) + keyword (BM25) search, fused with
  reciprocal rank fusion, with LLM query expansion to bridge vocabulary gaps
  (e.g. "philosophy classes" → "PHIL338")
- **Incremental indexing**: only re-embeds new/changed files; content-hash
  dedup skips byte-identical copies; resumable (Ctrl+C safe)
- **OCR** for image-based/scanned PDFs (Apple Vision on macOS, RapidOCR on
  Linux/Jetson — picked automatically)
- **Tool-calling agent** (`agent.py`) that routes between searching chunks,
  reading whole documents, and listing files — with human confirmation gates
  on risky actions
- **Cloud escalation** (`--deep`): retrieval stays local; on explicit request,
  the retrieved excerpts + question go to Claude for harder reasoning. Prints
  exactly which files' excerpts are sent.
- **Streaming answers** with per-stage timing (`--timing`)

## Requirements

- Python 3.11+
- [Ollama](https://ollama.com) running locally, with:
  ```
  ollama pull qwen2.5:14b-instruct       # answer model
  ollama pull qwen2.5:7b-instruct-64k    # query-expansion model
  ollama pull nomic-embed-text           # embeddings
  ```

## Setup

```
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## Usage

```
python cli.py index ~/Documents            # index a folder (repeatable, incremental)
python cli.py list                         # show what's indexed
python cli.py query "..."                  # ask a question (local, private)
python cli.py query "..." --timing         # + per-stage time breakdown
python cli.py query "..." --deep           # escalate this question to Claude
python agent.py "..."                      # tool-calling agent (search/read/notes)
python cli.py serve                        # local FastAPI /query endpoint
```

`--deep` needs `ANTHROPIC_API_KEY` set; without the flag, nothing ever leaves
your machine.

### Useful environment variables

| Variable | Default | Purpose |
|---|---|---|
| `RAG_CHAT_MODEL` | `qwen2.5:14b-instruct` | local answer model (use the 7B for faster dev) |
| `RAG_EXPAND_MODEL` | `qwen2.5:7b-instruct-64k` | query-expansion model |
| `RAG_CLOUD_MODEL` | `claude-opus-4-8` | cloud escalation model |
| `RAG_RERANK` | `0` | set `1` to enable the cross-encoder reranker |
| `RAG_DATA_DIR` | `./data` | where the index lives |

## Docker (recommended for Jetson)

A sandboxed two-container setup (app + Ollama) where documents are mounted
read-only and all state lives in named volumes:

```
docker compose up -d ollama
docker compose exec ollama ollama pull qwen2.5:14b-instruct
docker compose exec ollama ollama pull qwen2.5:7b-instruct-64k
docker compose exec ollama ollama pull nomic-embed-text
DOCS_DIR=$HOME/Documents docker compose run --rm rag python cli.py index /docs
DOCS_DIR=$HOME/Documents docker compose run --rm rag python cli.py query "..." --timing
```

On a Jetson (JetPack), uncomment `runtime: nvidia` in `docker-compose.yml` for
GPU inference. `docker compose down -v` removes every trace.

## How it works

- `extractors.py` — turns PDFs/docx/xlsx/text into plain text (with OCR fallback)
- `chunker.py` — splits text into overlapping word-count chunks
- `indexer.py` — walks a directory, skips unchanged files and duplicates,
  embeds new/changed chunks (state in `data/index_state.json`)
- `store.py` — LanceDB store: vector + full-text search, RRF fusion, chunk dedup
- `llm.py` — local Ollama (chat, expansion, embeddings) + Claude escalation
- `rerank.py` — optional cross-encoder reranker (off by default)
- `agent.py` / `tools.py` — tool-calling agent loop with risk-gated tools
- `app.py` — FastAPI `/query` endpoint
- `cli.py` — `index` / `query` / `list` / `serve` commands

## Inference engine: Ollama or vLLM

Local inference goes through a pluggable backend (`engine.py`), selected with
`RAG_ENGINE`:

- `RAG_ENGINE=ollama` (default) — the Ollama server, unchanged.
- `RAG_ENGINE=vllm` — any OpenAI-compatible server (vLLM, etc.), via
  `RAG_VLLM_URL` (default `http://localhost:8000/v1`).

Only *local* inference (chat / embeddings / routing) switches; the cloud
escalation path (Anthropic) is unaffected. Model **names** differ between
engines — Ollama uses tags (`qwen2.5:7b-instruct`), vLLM uses HF ids
(`Qwen/Qwen2.5-7B-Instruct`) — so when using vLLM, set `RAG_CHAT_MODEL`,
`RAG_GOOD_MODEL`, `RAG_EXPAND_MODEL`, and `RAG_EMBED_MODEL` to what your server
serves. A starting Compose template is in `docker-compose.vllm.yml` (read its
header — the stock image is x86-only; the Jetson needs an ARM/Jetson build).

## Tests

Offline unit tests for the routing and logic helpers (no Ollama or network
needed — pure functions only):

```
python -m unittest
```

Covers the heuristic pre-router (including the world-tier privacy guards),
refusal detection, the escalate distance gate, query dedup, and trace logging.

## Configuration

Tunables live in `config.py`: chunk size, retrieval depth (`TOP_K`), relevance
cutoff, supported file types, and excluded directories. The indexer skips git
repos, virtualenvs, `node_modules`, and other code/tool directories by design —
point it at document folders.
