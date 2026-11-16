# Worker browser workspace

Open the worker URL in a browser to upload documents, follow queue progress, cancel work, preview chunks, and choose job settings. The workspace uses the same port and API as the macOS app. Evaluation, RAG chat, and reranking remain in the app.

![Worker browser chunk preview](images/web-workspace.png)

Captured by the macOS browser unit tests with explicitly labeled fixture chunks; this image is not a live conversion result.

## Build and start

From the repository root, use Node.js 24.22.1 and the committed npm lockfile:

```bash
make build-web
python3 -m venv worker/.venv
worker/.venv/bin/pip install -e 'worker[dev]'
worker/.venv/bin/chunky-worker --host 127.0.0.1 --port 8080
```

Install the worker's [Docling dependencies and model services](worker-host.md) before processing real documents. The frontend build writes `worker/chunky_worker/web_dist/`. Build before making a wheel or installing a non-editable worker package so it includes those assets. An API-only installation keeps its API available and returns a helpful HTTP 503 at `/` until assets are built.

The [Compose image](../worker/deploy/README.md) builds the frontend in a pinned Node stage and copies only its generated assets into the worker image. Node is not needed in the running worker. No additional port is published.

For a remote worker, keep the existing token file, private bind address, firewall, and VPN or HTTPS setup. Use HTTPS or a trusted private tunnel for the browser session. Enter the worker bearer token on the login screen. The token stays in page memory; reload or sign out to clear it. It is never placed in URLs, cookies, browser storage, or generated assets. The login shell and static assets are public; job lists, results, settings, and events require the existing API authorization. Configure a token even on loopback to use the workspace. A loopback worker may start without one, but protected API routes still return HTTP 401.

## Jobs and settings

Choose files or drop them into the upload area. Choose chunk-only processing, chunks with downloadable vectors, or ingestion into Worker Qdrant when the worker has a configured target. Model and job choices apply to new uploads. They do not change the macOS app's saved preferences or existing jobs.

Worker embedding backends are Ollama and OpenAI-compatible embeddings. Choose the exact model identifier, and use an explicit worker-reachable endpoint when changing backend. The endpoint is resolved from the worker, not the browser. FastEmbed CPU models belong to Local Mac processing and are not offered as worker models. Worker VLM choices are Standard, Granite-Docling Transformers, and SmolDocling Transformers; CPU/GPU availability still depends on the host.

Queue pages have an explicit size and navigation. Progress is streamed with the authorization header. Chunk previews show a bounded number of chunks with their page and headings; the full result can be downloaded explicitly. Preview requests omit vectors without deleting them from the job result. Treat downloads as document data. A failed upload response may still mean a job was accepted: refresh the queue before resubmitting. The browser does not automatically replay an uncertain upload.

The queue is the worker's in-memory job store, shared with app/API submissions. Restarting the process clears that queue. This feature does not introduce durable job recovery or resumable uploads.

## Worker Qdrant credentials

Configure `CHUNKY_QDRANT_URL` and `CHUNKY_QDRANT_API_KEY` in the worker runtime environment to enable browser ingestion. The Compose worker forwards these optional variables. Inject the actual key through your deployment's private runtime configuration; do not commit it or put it into a frontend `VITE_*` variable. The configured URL must be HTTP(S) without embedded credentials, query parameters, or fragments.

The browser sends a collection name and `use_worker_qdrant=true`. It never receives or supplies the Qdrant URL/key. The server rejects target overrides for that mode, and refuses ingestion when the server target is incomplete. Worker ingestion currently requires an API key, including when the optional local Compose Qdrant profile is used. Keyless local Qdrant search through the existing API is a separate capability.

## Collection compatibility

For a new browser-managed collection, the worker records `chunky_embedding` metadata with the embedding backend, exact model identifier, a hash of the effective worker endpoint, dimensions, distance, and dense/hybrid layout. The raw endpoint is not stored in that identity. A model identifier assumes the operator keeps that model's contents stable; replacing weights under the same identifier requires a new collection.

An existing collection must have the same identity and actual vector layout, width, and distance. These checks run before document embedding and again before writes. A same-width model change is incompatible. Collections with unknown metadata, including legacy app-created collections, are refused for browser ingestion. Choose a new collection instead. The browser does not adopt, recreate, reconfigure, or overwrite an existing collection, and does not silently change its indexes or memory settings. Existing app/API ingestion without the browser-managed flag keeps its prior behavior.

## Validation

```bash
make test-worker
make test-web
```

Frontend checks cover Svelte/TypeScript, unit tests, a production build, and Playwright browser component tests with mocked worker responses. The macOS CI job captures the actual production frontend, rejects blank screenshots, and uploads the queue, chunks, settings, and mobile views. Fixtures are test data, not evidence of live PDF extraction. Worker tests use fake conversion, embedding, and Qdrant clients. CI does not start live model services, GPUs, or Qdrant.

Live conversion, real model inference, and Qdrant integration are separate operator checks outside CI. The ROCm image and physical worker still require the deployment validation tracked in PER-53.

## Collections and semantic search

Open Collections to browse the worker's configured Qdrant target. This is the server target from `CHUNKY_QDRANT_URL`; a Qdrant API key is optional for reads when that server permits keyless access. The browser never receives the target URL or key. Browse pages request 50 points without vectors and follow the server's continuation cursor. There is no client-side 1,000-point filter or implicit truncation.

Collections with unknown embedding identity remain available for read-only browsing. Semantic search requires trusted embedding metadata and matching actual collection configuration. Choose an indexed model/provider and, when the collection used a custom worker-side embedding endpoint, enter that same endpoint. Changing a query model, endpoint, collection, or search mode clears the previous hits. A same-width model substitution is refused.

Search uses the existing authenticated `/v1/search` engine with `use_worker_qdrant=true`. This pins Qdrant access to the configured server and validates model identity, endpoint fingerprint, dimensions, distance, and vector layout before querying. Dense search also works in a matching hybrid collection; hybrid search requires an existing hybrid layout. Browser reads and searches do not create indexes, adopt metadata, or change collection settings. Legacy app/API search retains its existing behavior.

Results show semantic scores, chunk text, source, and page metadata when present. Each search page requests 10 hits with an explicit offset and continuation; paging is a fresh query against the current collection, so concurrent writes can change rankings. This workspace does not promise a frozen search snapshot or modify stored points.
