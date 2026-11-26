# Chunky worker

HTTP worker for Docling conversion, HybridChunker, embeddings, Qdrant ingest,
and search on a Linux host. Model ids are in `docs/models.md`. The app calls this API
when the Devbox processing host is selected and a saved worker profile is in use.

This package wraps the existing scripts in `Chunky/Resources/Scripts/`
(`convert_document`, `_chunk_document`, and the daemon command fields). It does
**not** install or import `mlx-vlm` (Apple-only). Granite-docling on a
worker host uses the `granite_docling` DocTags preset through vLLM
(`CHUNKY_VLM_ENGINE=vllm`, the default) or Transformers on CUDA
(`CHUNKY_VLM_ENGINE=transformers`). Flash Attention 2 stays off.
`/v1/health` reports the engine and whether the GPU is visible. See
`docs/worker-host.md`.

GPU / model backends are pluggable. Unit tests inject fakes and do not need
Docling, Ollama, or a GPU.

## Browser workspace

The optional [browser workspace](../docs/web-ui.md) is served at `/` on the same worker port. Build `worker/web` with Bun 1.4.4 and its committed lockfile before installing the worker package; the Compose image builds it automatically. Its login shell is public, while job data and configuration use the existing bearer-token policy. Tokens stay in browser memory and Qdrant credentials stay on the worker.

## API

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/v1/collections` | Configured worker Qdrant collection names; no credentials |
| `GET` | `/v1/collections/{name}/points` | Read-only points without vectors; explicit limit and cursor |
| `GET` | `/v1/ui/config` | Safe browser configuration; no endpoint credentials |
| `GET` | `/v1/jobs` | Job summaries with explicit `limit` (1–100) and `offset` |
| `POST` | `/v1/jobs` | Multipart upload (`file`) plus a `settings` JSON field |
| `GET` | `/v1/jobs/{id}` | Job status and result; `include_embeddings=false` omits vectors without changing the stored result |
| `GET` | `/v1/jobs/{id}/events` | SSE progress `{type, message, percent}` |
| `POST` | `/v1/jobs/{id}/cancel` | Request cancellation |
| `GET` | `/v1/jobs/{id}/verification` | Per-document verification report written next to the job |
| `POST` | `/v1/jobs/{id}/verify` | Run the checks again. Optional JSON may include `qdrant_url`, `qdrant_api_key`, and `qdrant_collection` |
| `POST` | `/v1/verify` | Verify an uploaded PDF. `settings` JSON may include `chunks`; otherwise the PDF-hash chunk cache is used |
| `GET` | `/v1/health` | Docling import, embedding reachability, and the granite VLM engine plus GPU visibility. **No token.** |
| `GET` | `/v1/models` | Embedding model names and known VLM ids. **Bearer token.** |
| `POST` | `/v1/search` | Embed a query and search Qdrant. **Bearer token.** |
| `POST` | `/v1/cache/lookup` | Return cached chunks, and vectors when the model and dimension match. **Bearer token.** |
| `PUT` | `/v1/cache` | Store a Docling document JSON and its chunk records. **Bearer token.** |
| `PUT` | `/v1/cache/vectors` | Store vectors for one embedding model and dimension. **Bearer token.** |
| `GET` | `/v1/cache` | Cache entry count and byte size. **Bearer token.** |
| `DELETE` | `/v1/cache` | Remove every cached entry. **Bearer token.** |

`settings.mode` is `chunk_only` (default) or `chunk_and_embed`. Other fields
match the `docling_daemon.py` convert command (for example `vlm_model`,
`accelerator`, `chunk_max_tokens`, `ollama_url`, `embedding_model`).

## Chunk cache

Cached conversions live under `CHUNKY_WORKER_CACHE_DIR` (default
`$XDG_STATE_HOME/chunky/cache`, or `~/.local/state/chunky/cache`). The Mac app
uses `~/Library/Application Support/Chunky/Cache` with the same layout.
`CHUNKY_WORKER_CACHE_LIMIT_BYTES` evicts the least recently used entries when
the directory is over that size. `0` means no limit.

An entry is keyed by the SHA-256 of the PDF bytes, the Docling version, the
pipeline or VLM preset, the chunk tokenizer, and `max_tokens`. The directory
is `entries/<sha256 of that key>/`:

| File | Contents |
|------|----------|
| `document.json` | The DoclingDocument JSON |
| `chunks.json` | Chunk records, including `page`, `page_end`, `pages`, `page_labels`, `headings`, `bboxes`, `doc_title`, `authors`, `year`, `doi`, and `source` |
| `vectors/<id>.json` | Vectors for one embedding model id and dimension |
| `manifest.json` | Entry ids, byte sizes, and last-used times, written atomically |

A lookup with a different embedding model still returns the chunks. Vectors
are included only when `embedding_model` and `embedding_dim` match a stored set.

## Ingest targets

`settings.ingest_target` is one of:

| Value | Behavior |
|-------|----------|
| `none` | Default. `chunk_only` returns chunks. `chunk_and_embed` also returns embeddings. Nothing is written to Qdrant. |
| `return_vectors` | Embeds even when `mode` is `chunk_only`, and puts `chunks` plus `embeddings` on the job result so the app can upsert into local Docker Qdrant. |
| `qdrant_cloud` | Embeds, then upserts directly with `qdrant-client`. The result is a receipt (`collection`, `upserted`, `vector_size`, `distance`) and does **not** echo the vectors. |

For `qdrant_cloud`, send `qdrant_url`, `qdrant_api_key`, and optional `qdrant_collection` (default `documents`), `qdrant_distance` (`cosine`, `dot`, `euclid`), and `qdrant_batch_size` (default 250). The API key is held in memory only for that job, stripped from `GET /v1/jobs`, and never written to the log. The worker creates the collection when it is missing, using the embedding width and the requested distance. Before upsert the worker embeds the probe string `chunky` once per model, caches that width, and compares it with an existing collection. A mismatch fails the job with `error_type: dimension_mismatch` before the rest of the chunks are embedded. The same check runs again at upsert time.

Browser jobs use `use_worker_qdrant=true` with `mode=chunk_and_embed` and `ingest_target=qdrant_cloud`. They reject client Qdrant URL/key overrides and use only `CHUNKY_QDRANT_URL` plus `CHUNKY_QDRANT_API_KEY`. New collections record the embedding identity in Qdrant metadata; existing collections must match that identity, vector layout, width, and distance before writing. Unknown collections are refused without changing their configuration. See [browser collection compatibility](../docs/web-ui.md#collection-compatibility). Existing app requests retain their original API behavior.

Payload fields match the app: `text`, `source`, `page` (int), `year` (int), `headings` (string array), and string metadata `chunk_index`, `content_type`, `section`, `doc_title`, `authors` (joined with `"; "`), `doi`, `document_id`, `url`, `language`, `ingested_at`, `content_hash` (SHA-256 of embedding text, `|`, and model). Metadata flags on the job default to on, same as the app.

## Vector stores

Qdrant remains the default, and a request that omits `vector_store` keeps the existing Qdrant behavior. `CHUNKY_VECTOR_STORE` or `--vector-store` selects the store used when browser ingest and search set `use_worker_qdrant=true`. Those requests still reject client URLs and keys. A direct API call names `vector_store`, `vector_store_url`, and an optional `vector_store_api_key`. Unknown names are rejected. Qdrant itself continues to use `CHUNKY_QDRANT_URL` and `CHUNKY_QDRANT_API_KEY`.

Registered stores are `qdrant`, `pgvector`, `weaviate`, `milvus`, and `chroma`. pgvector and Weaviate answer hybrid search. Milvus and Chroma answer dense search. A pgvector URL is `postgresql://` and the worker needs `psycopg[binary]` installed. A non-Qdrant write keeps `ingest.target=qdrant_cloud` (the worker upserted) and sets `ingest.store`. Paper summaries, section expansion, snapshots, quantization, and Qdrant payload indexes stay on the Qdrant path. See [vector stores](../docs/vector-stores.md).

## Verification

After a successful job the worker writes `verification.json` beside the upload. The report has a green, yellow, or red status per page. Checks are text coverage (pypdfium2, or pypdf when that is not installed; not Docling), page attribution from `page` through `page_end`, a Qdrant store check, a re-embedded cosine sample, and a retrieval self-test. Chunk text stays in the job result or the PDF-hash chunk cache (`chunky_worker.chunk_cache`). The report stores scores and short previews only. The Qdrant API key is not written to the report or the log.

## Search

`POST /v1/search` embeds one query with the configured embedding backend (Ollama
by default, or OpenAI-compatible `/v1/embeddings` when `embedding_backend` is
`openai`) and runs a Qdrant query. Rerank, eval metrics, and RAG chat run in the app. The app may rerank these hits with
its own `/v1/rerank` client. This process does not call a reranker.

Browser searches set `use_worker_qdrant=true`, which rejects Qdrant URL/key overrides and uses only the configured server. Those searches require verified collection embedding identity and matching actual vector configuration; they do not create or update indexes. Unknown collections can still be browsed through the read-only points route. See [browser search](../docs/web-ui.md#collections-and-semantic-search). Existing requests without that flag keep their original behavior.

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

`filters` is a list of payload conditions. Required items are combined with AND.
An item with `should` is one alternative inside a required group. Each item has
`key` plus `match` (string, integer, or boolean), `text` (substring), `any`
(one of several values), `empty`, and/or a range (`gt`, `gte`, `lt`, `lte`).
`negate` excludes a match. Example keys are `source`, `page`, `year`, `doi`,
`content_type`, and `library_id`. `papers_first` returns document summaries.
`expand_section` replaces a hit with the stored sibling chunks that share its
heading path when the sibling ratio is met. The ratio defaults to 0.5.

Element-type aliases use the shared `element_types.py` from
`CHUNKY_SCRIPTS_DIR` when configured. Installed workers should point that
directory at the deployed `Chunky/Resources/Scripts`; repository checkouts
keep the existing default.

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

Put that value in the app Keychain. Do not commit it.

**Bind address.** The default is `127.0.0.1:8080` (`CHUNKY_WORKER_HOST` /
`CHUNKY_WORKER_PORT`, or `--host` / `--port`). On a worker host, set
`CHUNKY_WORKER_HOST` to one interface address, `0.0.0.0`, or a VPN address.
Do not hardcode that address in the repo. Any bind other than `127.0.0.1`,
`localhost`, or `::1` refuses to start until `CHUNKY_WORKER_TOKEN` or
`CHUNKY_WORKER_TOKEN_FILE` is set. Binding `0.0.0.0` logs a warning. Prefer
one interface plus a firewall that allows the worker port only from the app
machines.

`0.0.0.0` is the supported way to accept a wired LAN, Wi-Fi, and a VPN address
in one process. A single address is enough when only one path is needed.
Example firewall, using your own values:

```bash
sudo ufw allow from APP_MACHINE_IP to any port 8080 proto tcp
sudo ufw allow from LAN_SUBNET to any port 8080 proto tcp
sudo ufw allow from 100.64.0.0/10 to any port 8080 proto tcp
sudo ufw deny 8080/tcp
```

**Model servers stay on loopback.** Ollama defaults to
`http://127.0.0.1:11434` (`CHUNKY_OLLAMA_URL`). vLLM defaults to
`http://127.0.0.1:8000` (`CHUNKY_VLLM_URL`). Do not publish them on the LAN.
A non-loopback URL logs a warning at startup.

## Docker Compose

[ROCm Compose setup](deploy/README.md) starts the worker and loopback-only
Ollama with pinned images, persistent volumes, and optional vLLM and Qdrant
profiles. Only the worker port is published on the selected private interface.
The existing plain-venv deployment remains available below.

## systemd

`deploy/chunky-worker.service` is a plain-venv unit (no Docker). Install the
venv under `/opt/chunky/worker/.venv`, write the token file, set
`CHUNKY_WORKER_HOST` to the worker address, then:

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
# On a worker host, also install docling (not mlx-vlm):
# .venv/bin/pip install -r requirements-docling.txt
.venv/bin/chunky-worker --host 127.0.0.1 --port 8080
# Bind one reachable address instead of loopback:
# CHUNKY_WORKER_HOST=<worker-ip> .venv/bin/chunky-worker
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

Paper DOI queries use exact stored strings: case and DOI URL prefixes are not normalized. New worker summaries inherit DOI from prepared passages, including imported bibliography overrides and the `metadata_include_doi` setting. Their `summary_metadata_version=1` marks DOI coverage as known even when DOI is unavailable or intentionally disabled. Summary text, embedding identity, vectors and point IDs are unchanged by this metadata addition.

Before a paper DOI query, the worker makes a read-only, one-result lookup for older summaries that lack both DOI and the coverage marker. It keeps the same library and other document filters, excluding the DOI condition itself. When DOI is an OR alternative (`should`), coverage drops that entire OR group rather than requiring its remaining alternatives; mandatory library and document filters still apply. If such a record exists, the API returns HTTP 409 with `summary_doi_coverage_incomplete`, for both summary-only and expanded searches. This prevents a matching passage DOI from being misreported as no matching paper. Older summaries with a stored DOI remain searchable; known DOI-less new summaries do not block queries. A failed coverage lookup fails the request rather than returning a false empty result.

No existing point, payload index, collection configuration or embedding is migrated or backfilled. This also applies to older or Mac-created summaries without the marker. Use passage DOI search or remove the DOI filter to search these collections; no re-ingest is performed automatically. The browser retains its paper DOI guard until it can establish compatible coverage for the selected scope. Passage DOI filtering is unchanged.
