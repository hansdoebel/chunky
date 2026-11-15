# Chunky worker

HTTP worker for running Docling conversion, HybridChunker, and optional Ollama
embeddings on a Linux host (the Ubuntu devbox). The macOS app will call this
API when the Devbox processing host is selected (see Linear PER-43).

This package wraps the existing scripts in `Chunky/Resources/Scripts/`
(`convert_document`, `_chunk_document`, and the daemon command fields). It does
**not** install or import `mlx-vlm` (Apple-only).

GPU / model backends are pluggable. Unit tests inject fakes and do not need
Docling, Ollama, or a GPU.

## API

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/v1/jobs` | Multipart upload (`file`) plus a `settings` JSON field |
| `GET` | `/v1/jobs/{id}` | Job status and result (chunks, optional embeddings) |
| `GET` | `/v1/jobs/{id}/events` | SSE progress `{type, message, percent}` |
| `POST` | `/v1/jobs/{id}/cancel` | Request cancellation |
| `GET` | `/v1/health` | Docling import and embedding-backend reachability |
| `GET` | `/v1/models` | Embedding model names and known VLM ids |

`settings.mode` is `chunk_only` (default) or `chunk_and_embed`. Other fields
match the `docling_daemon.py` convert command (for example `vlm_model`,
`accelerator`, `chunk_max_tokens`, `ollama_url`, `embedding_model`).

Bearer-token auth and binding to the 10GbE interface are PER-47. Qdrant ingest
is PER-48 — this worker returns artifacts (and embeddings) only.

## Run

```bash
cd worker
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
# On the devbox, also install docling (not mlx-vlm):
# .venv/bin/pip install docling
.venv/bin/chunky-worker --host 127.0.0.1 --port 8080
```

Logs go to `$XDG_STATE_HOME/chunky/logs` (default `~/.local/state/chunky/logs`),
not `~/Library/Logs/Chunky`. Override with `CHUNKY_LOG_DIR`.

Ollama is expected on loopback (`http://127.0.0.1:11434`) unless you set
`CHUNKY_OLLAMA_URL` or pass `ollama_url` in job settings.

## Tests

```bash
cd worker
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
.venv/bin/pytest -q
```

Or from the repo root: `make test-worker`.
