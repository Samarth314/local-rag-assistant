import os
from pathlib import Path

# Where the LanceDB database and indexing state live. Overridable so a
# container can keep its index on a mounted volume.
DATA_DIR = Path(os.environ.get("RAG_DATA_DIR", Path(__file__).parent / "data"))
DB_PATH = str(DATA_DIR / "lancedb")
STATE_FILE = DATA_DIR / "index_state.json"
CHUNKS_TABLE = "chunks"

# Ollama models (pull with: ollama pull <model>)
EMBED_MODEL = "nomic-embed-text"   # 768-dim embeddings
EMBED_DIM = 768
# 14B is the deployment target (the Jetson AGX runs it comfortably); it's the
# default so we tune against production quality, not this dev machine. For fast
# local iteration, override without editing code:
#   RAG_CHAT_MODEL=qwen2.5:7b-instruct-64k python cli.py query "..."
CHAT_MODEL = os.environ.get("RAG_CHAT_MODEL", "qwen2.5:14b-instruct")

# Query expansion is a trivial rewrite task -- run it on a small model so the
# big model's time goes to answering. Right choice on the Jetson too, not just
# a dev-machine accommodation.
EXPAND_MODEL = os.environ.get("RAG_EXPAND_MODEL", "qwen2.5:7b-instruct-64k")

# Local "thorough" tier (--good, or auto-routed for complex questions): a
# stronger local model for synthesis/reasoning. gpt-oss:20b (MoE) is the pick
# on the Jetson -- faster than a dense 14B and better grounded. Doesn't fit a
# 24GB Mac well, so keep it Jetson-side via the compose env.
GOOD_MODEL = os.environ.get("RAG_GOOD_MODEL", "gpt-oss:20b")

# Reasoning effort for the good tier (gpt-oss supports low/medium/high via
# Ollama's `think` param). Unset uses the model's own default. Lower effort
# trades reasoning depth for speed -- only worth it if quality holds up on
# real grounded queries, not synthetic ones.
GOOD_MODEL_THINK = os.environ.get("RAG_GOOD_THINK") or None

# Cloud escalation (--deep): retrieval always stays local; only the retrieved
# excerpts + question are sent, and only when the user explicitly asks.
CLOUD_MODEL = os.environ.get("RAG_CLOUD_MODEL", "claude-opus-4-8")

# Auto-cloud for out-of-scope questions: when the router labels a question
# WORLD (current time/weather/news/live facts -- nothing the user's files
# could answer), send JUST the question text -- never any document content --
# to the cloud model with web search. This is the one exception to "cloud
# only via --deep"; set RAG_AUTO_CLOUD=0 to keep that boundary absolute.
AUTO_CLOUD = os.environ.get("RAG_AUTO_CLOUD", "1") == "1"

# Auto-routing (no flag): a cheap classification call on the small model decides
# fast tier (CHAT_MODEL) vs thorough tier (GOOD_MODEL). Never auto-routes to the
# cloud -- that stays explicit (--deep). Set RAG_AUTOROUTE=0 to always use the
# fast tier by default instead.
AUTOROUTE = os.environ.get("RAG_AUTOROUTE", "1") == "1"

# Escalate-on-failure backstop: when auto-routing chose the fast tier and the
# answer looks like the model couldn't answer from the context, retry once on
# the good tier. Only fires under auto-routing (an explicit --fast is honored
# as-is) and never escalates to the cloud -- that stays explicit (--deep).
ESCALATE_ON_FAILURE = os.environ.get("RAG_ESCALATE", "1") == "1"

# Escalate-on-failure only retries if at least one retrieved chunk is a
# strong semantic match (cosine distance at or below this). A refusal next to
# only weak/keyword-only matches is very likely a genuine "not in the docs"
# case -- retrying there just burns 10-15s for the same answer (validated:
# every escalate case on the sample corpus agreed with the fast-tier refusal).
# A refusal next to a *strong* match is the suspicious case worth retrying.
ESCALATE_DISTANCE_THRESHOLD = float(os.environ.get("RAG_ESCALATE_DISTANCE", "0.4"))
# Context window per chat call. A hybrid RAG query is ~3-4k tokens (TOP_K
# chunks + prompt + answer), so 8k gives 2x headroom while keeping the 14B's
# KV cache to ~1.5GB. 32k ballooned the cache to ~6GB and starved the machine
# (memory pressure -> compression -> slow tokens). Bump only if a future
# whole-document mode needs to stuff a full PDF into one call.
NUM_CTX = 8192

# Chunking (word-based, no tokenizer dependency needed)
CHUNK_SIZE_WORDS = 300
CHUNK_OVERLAP_WORDS = 50

# Retrieval
TOP_K = 8
MAX_DISTANCE = 0.55  # cosine distance cutoff; chunks farther than this are treated as noise

# Reranking: hybrid search casts a wide net (RERANK_CANDIDATES), then a
# cross-encoder rescores those against the query and keeps the true TOP_K.
# OFF by default: on this corpus the base cross-encoder regressed hard cases
# (it rewards prose that "sounds like" the query, hurting structured-table
# lookups, and gets fooled by ambiguous terms shared across documents).
# Kept behind a flag to revisit with a stronger model. Set RAG_RERANK=1 to try.
RERANK_ENABLED = os.environ.get("RAG_RERANK", "0") == "1"
RERANK_MODEL = os.environ.get("RAG_RERANK_MODEL", "BAAI/bge-reranker-base")
RERANK_CANDIDATES = 30

# Whole-document read: the max characters returned when reading a full document
# (rather than searching chunks). ~24k chars ≈ 6k tokens, safely under NUM_CTX
# with room for the prompt and answer. Larger documents are truncated with a
# note, and the agent is told to fall back to search for those.
READ_DOC_MAX_CHARS = 24000

# Cap on how many filenames list_documents returns in one call, so a large
# index can't flood the agent's context window. The agent is told to filter.
LIST_DOCS_LIMIT = 40

# Document extensions. Deliberately excludes code/config (.py/.js/.json/...):
# this is a personal-document assistant, and indexing source trees pulled in
# minified JS bundles, virtualenv assets, and JSON data dumps that polluted
# retrieval. Point it at a code folder on purpose if you ever want that.
SUPPORTED_EXTENSIONS = {
    ".pdf", ".docx", ".xlsx",
    ".txt", ".md", ".rst",
}

# Specific files to never index, by exact filename (noise we've chosen to
# exclude even though the extension is supported).
EXCLUDED_FILES = {
    "RealEstatePrinciples.pdf",
}

# Directories to never walk into
EXCLUDED_DIRS = {
    ".git", "node_modules", "__pycache__", ".venv", "venv", "env", "myenv",
    "dist", "build", ".next", ".cache", "site-packages", ".idea", ".vscode",
    "miniforge3", "miniconda3", "anaconda3", ".conda",
    "My Tableau Repository",
}

# Skip files larger than this (avoid choking on huge binaries/logs)
MAX_FILE_SIZE_BYTES = 20 * 1024 * 1024  # 20 MB
# Tighter cap for plain-text files (.txt/.md/.rst): real notes are small, so a
# multi-hundred-KB text file is almost always a dataset/log/training corpus
# (e.g. a 1MB Shakespeare input.txt), not a document. PDFs are exempt.
MAX_TEXT_FILE_BYTES = 256 * 1024  # 256 KB
PLAINTEXT_EXTENSIONS = {".txt", ".md", ".rst"}
