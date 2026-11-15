# Chunky worker

HTTP worker for Docling conversion, HybridChunker, embeddings, Qdrant ingest,
and search on a Linux host (the Ubuntu devbox). Model ids for that host are in `docs/models.md`. The macOS app calls this API
when the Devbox processing host is selected and a saved worker profile is in use.

This package wraps the existing scripts in `Chunky/Resources/Scripts/`
(`convert_document`, `_chunk_document`, and the daemon command fields). It does
**not** install or import `mlx-vlm` (Apple-only). Granite-docling on the
devbox uses the `granite_docling` DocTags preset through vLLM
(`CHUNKY_VLM_ENGINE=vllm`, the default) or Transformers on CUDA
(`CHUNKY_VLM_ENGINE=transformers`). Flash Attention 2 stays off.
`/v1/health` reports the engine and whether the GPU is visible. See
`docs/devbox-setup.md`.

GPU / model backends are pluggable. Unit tests inject fakes and do not need
Docling, Ollama, or a GPU.

## API

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/v1/jobs` | Multipart upload (`file`) plus a `settings` JSON field |
| `GET` | `/v1/jobs/{id}` | Job status and result (chunks, optional embeddings) |
| `GET` | `/v1/jobs/{id}/events` | SSE progress `{type, message, percent}` |
| `POST` | `/v1/jobs/{id}/cancel` | Request cancellation |
| `GET` | `/v1/health` | Docling import, embedding reachability, and the granite VLM engine plus GPU visibility. **No token.** |
| `GET` | `/v1/models` | Embedding model names and known VLM ids. **Bearer token.** |
| `POST` | `/v1/search` | Embed a query and search Qdrant. **Bearer token.** No web UI. |

`settings.mode` is `chunk_only` (default) or `chunk_and_embed`. Other fields
match the `docling_daemon.py` convert command (for example `vlm_model`,
`accelerator`, `chunk_max_tokens`, `ollama_url`, `embedding_model`).

## Ingest targets

`settings.ingest_target` is one of:

| Value | Behavior |
|-------|----------|
| `none` | Default. `chunk_only` returns chunks. `chunk_and_embed` also returns embeddings. Nothing is written to Qdrant. |
| `return_vectors` | Embeds even when `mode` is `chunk_only`, and puts `chunks` plus `embeddings` on the job result so the Mac can upsert into local Docker Qdrant. |
| `qdrant_cloud` | Embeds, then upserts directly with `qdrant-client`. The result is a receipt (`collection`, `upserted`, `vector_size`, `distance`) and does **not** echo the vectors. |

For `qdrant_cloud`, send `qdrant_url`, `qdrant_api_key`, and optional `qdrant_collection` (default `documents`), `qdrant_distance` (`cosine`, `dot`, `euclid`), and `qdrant_batch_size` (default 250). The API key is held in memory only for that job, stripped from `GET /v1/jobs`, and never written to the log. The worker creates the collection when it is missing, using the embedding width and the requested distance. Before upsert the worker embeds the probe string `chunky` once per model, caches that width, and compares it with an existing collection. A mismatch fails the job with `error_type: dimension_mismatch` before the rest of the chunks are embedded. The same check runs again at upsert time.

Payload fields match the Mac app: `text`, `source`, `page` (int), `year` (int), `headings` (string array), and string metadata `chunk_index`, `content_type`, `section`, `doc_title`, `authors` (joined with `"; "`), `doi`, `document_id`, `url`, `language`, `ingested_at`, `content_hash` (SHA-256 of embedding text, `|`, and model). Metadata flags on the job default to on, same as the Mac app.

## Search

`POST /v1/search` embeds one query with the configured embedding backend (Ollama
by default, or OpenAI-compatible `/v1/embeddings` when `embedding_backend` is
`openai`) and runs a Qdrant query. The worker has no web UI. Rerank, eval
metrics, and RAG chat run in the Mac app. The app may rerank these hits with
its own `/v1/rerank` client. This process does not call a reranker.

The Qdrant target is the request's `qdrant_url` and optional `qdrant_api_key`,
or `CHUNKY_QDRANT_URL` / `CHUNKY_QDRANT_API_KEY` when the body omits the URL.
The configured key is attached only for that configured URL. A different
`qdrant_url` never receives it: send `qdrant_api_key` with that URL, or omit
the key for a local server. The key is not returned and is stripped from
error text and the log.

`limit` is required to be explicit in the response (default 10, maximum 100;
larger values are rejected). `offset` pages through results. A full page sets
`next_offset` to `offset + limit`; a short page sets it to `null`. There is no
silent 1,000-point cap.

`mode` is `dense` (default) or `hybrid`. Hybrid prefetches the dense vector and a
Qdrant 1.20 BM25 `TextQuery` on the `text` payload field, then fuses them with
RRF. Optional `rrf_weights` is two non-negative numbers, dense then BM25.
Hybrid ingest creates a BM25 text index on `text` and does not store
batch-local TF-IDF sparse vectors.

`filters` is a list of payload conditions, combined with AND. Each item has
`key` plus `match` (string, integer, or boolean) and/or a range (`gt`, `gte`,
`lt`, `lte`). Example keys are `source`, `page`, and `content_type`.

A collection whose dense vector width does not match the query vector is
refused with HTTP 409 and `error_type: dimension_mismatch` before the query.
A missing collection is HTTP 404. The response `results` are `{id, score, payload}`.

## Authentication and bind address

Every `/v1` route except `GET /v1/health` requires:

```
Authorization: Bearer <token>
```

`/v1/health` stays open so a reachability probe and systemd can see that the
process is up before the token is checked. `/v1/models` and the job routes
return **401** when the token is missing, wrong, or not configured. A token in
the query string is ignored (it would show up in access logs). The token is
never written to the worker log.

The token comes from, in order:

1. `CHUNKY_WORKER_TOKEN` (non-empty). An empty value disables the file fallback.
2. `CHUNKY_WORKER_TOKEN_FILE` (the file must exist).
3. `$XDG_CONFIG_HOME/chunky/worker.token`, or `~/.config/chunky/worker.token` when that file exists.

Generate one (printed to stdout only; optional file is mode `0600`):

```bash
.venv/bin/chunky-worker --generate-token
.venv/bin/chunky-worker --generate-token --token-file /etc/chunky/worker.token
```

Put that value in the Mac Keychain. Do not commit it.

**Bind address.** The default is `127.0.0.1:8080` (`CHUNKY_WORKER_HOST` /
`CHUNKY_WORKER_PORT`, or `--host` / `--port`). On the devbox, set
`CHUNKY_WORKER_HOST` to the static address of the 10GbE NIC, `0.0.0.0`, or the
Tailscale address. Do not hardcode that address in the repo. Any bind other
than `127.0.0.1`, `localhost`, or `::1` refuses to start until
`CHUNKY_WORKER_TOKEN` or `CHUNKY_WORKER_TOKEN_FILE` is set. Binding `0.0.0.0`
logs a warning; prefer one interface plus a firewall that allows the worker
port only from the Mac:

`0.0.0.0` is the supported way to accept the Mac Studio on 10GbE, the MacBook on
the LAN, and a Tailscale address (`tailscale ip -4`) in one process. A single
address is enough when only one path is needed. Do not hardcode those
addresses. Example firewall, using your own values:

```bash
sudo ufw allow from MAC_10GBE_IP to any port 8080 proto tcp
sudo ufw allow from LAN_SUBNET to any port 8080 proto tcp
sudo ufw allow from 100.64.0.0/10 to any port 8080 proto tcp
sudo ufw deny 8080/tcp
```

**Model servers stay on loopback.** Ollama defaults to
`http://127.0.0.1:11434` (`CHUNKY_OLLAMA_URL`). vLLM defaults to
`http://127.0.0.1:8000` (`CHUNKY_VLLM_URL`). Do not publish them on the LAN.
A non-loopback URL logs a warning at startup.

## systemd

`deploy/chunky-worker.service` is a plain-venv unit (no Docker). Install the
venv under `/opt/chunky/worker/.venv`, write the token file, set
`CHUNKY_WORKER_HOST` to the 10GbE address, then:

```bash
sudo cp deploy/chunky-worker.service /etc/systemd/system/chunky-worker.service
sudo systemctl daemon-reload
sudo systemctl enable --now chunky-worker
curl -sS "http://127.0.0.1:8080/v1/health"
curl -sS -H "Authorization: Bearer $(sudo cat /etc/chunky/worker.token)" \
  "http://127.0.0.1:8080/v1/models"
```

## Run

```bash
cd worker
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
# On the devbox, also install docling (not mlx-vlm):
# .venv/bin/pip install -r requirements-docling.txt
.venv/bin/chunky-worker --host 127.0.0.1 --port 8080
# On the devbox, bind the 10GbE address instead of loopback:
# CHUNKY_WORKER_HOST=<devbox-10gbe-ip> .venv/bin/chunky-worker
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
