# AGENTS.md

Chunky is a macOS app that turns documents into chunks and Qdrant vectors. Heavy conversion can run on this Mac or on an Ubuntu worker. The worker exposes an HTTP API and an optional browser workspace for upload, queue progress, cancellation, chunk preview, job configuration, and collection browsing with semantic search. Evaluation and RAG chat stay in the app.

## Layout

- `Chunky/` is the macOS app. `Sources/Models` holds settings, jobs, and eval records. `Sources/Services` holds Docling, Ollama, Qdrant, the worker client, retrieval, pi, and the MCP server. `Sources/Views` is SwiftUI. `Resources/Scripts` is the local Docling pipeline.
- `worker/` is the FastAPI worker (`chunky_worker`). It converts, chunks, embeds, ingests to Qdrant Cloud, and searches. It serves the built browser workspace on its existing port and does not call a reranker.
- `worker/web/` is the Svelte/Vite browser workspace. Its build writes generated assets to `worker/chunky_worker/web_dist/`; those assets are packaged with the worker and are not committed. The browser calls the same-origin worker API and never connects directly to Qdrant.
- `LocalPackages/qdrant-swift` is the vendored gRPC and REST client. `Sources/QdrantProto` is generated. Leave those files generated.
- `docs/` is the operator guide. `docs/models.md` is the model choice for an Apple Silicon app machine and a ROCm worker host. `docs/worker-use-cases.md` is the topology list. `worker/README.md` is the HTTP API.

The app windows are Queue, Collections, Retrieval, Eval, Analytics, and Benchmark. Processing host is Local Mac or Devbox. Devbox means a worker URL. Profiles start as Wired LAN, Wi-Fi, and Tailscale. A profile is a name, a base URL, and a Keychain token. Use applies it. Check reachability calls `GET /v1/health`, then `GET /v1/models`, and reports unreachable, HTTP 401, App Transport Security, success, and latency.

Retrieval searches the active collection. A chunk payload keeps `page` and `page_end` (PDF page index, not a printed journal label), `headings`, `bboxes` when Docling recorded them, and `doc_title`, `authors`, `year`, and `doi` when the document description has them. Dense is the default. Hybrid fuses the dense vector with Qdrant BM25 using RRF. An optional rerank step posts Cohere-style JSON (`model`, `query`, `documents`, `top_n`) to the URL in Preferences and reads `results[].relevance_score`. The worker does not call a reranker. Filters can restrict year, author, DOI, title, heading, and element type. Empty filters do not change the query. A document summary is stored in the same collection as `record_type=document`. Papers-first search returns those summaries and can expand them to chunks. Expand to section concatenates sibling chunks that share a heading path when enough of that section was retrieved. Eval scores a JSON set with recall@k, MRR, nDCG, and hit rate. RAG chat in the Retrieval tab turns the hits into numbered citations and answers with pi or an OpenAI-compatible chat API. `Chunky --mcp` exposes `search` and `list_collections` on stdio for pi and other MCP clients and honors the same filters.

A paper library is a name plus a stable `library_id` on each point. The payload index is a Qdrant tenant keyword index. Ingest uses the active library. Points with no library stay in the default library. Search, RAG, eval, and MCP stay on the active library unless the request names a set or all libraries. Moving points updates `library_id` and does not re-embed. Collections can create, download, and restore a Qdrant snapshot of the server shown in the browser. The API key stays in the Keychain.

## Toolchain

- Xcode 27.2 on the `xcode-27` runner. The SDK is macOS 27. The deployment target is macOS 27.0.
- Swift 6.4. The app target sets `SWIFT_VERSION` to 5.0 and `SWIFT_DEFAULT_ACTOR_ISOLATION` to `MainActor`. Do not change that language mode as a drive-by.
- Python 3.12 for the worker and for `Chunky/Resources/Scripts`.
- Node.js 24.22.1 for `worker/web`; use its committed npm lockfile.
- Qdrant `v1.20.1` when a local server is needed. Unit tests do not start it.

## Commands

```bash
make first-launch
make setup-venv
make build
make test-python
make test-worker
make build-web
make test-web
```

`make test` runs the whole Xcode scheme, so it includes `ChunkyUITests` as well as `ChunkyTests`. `make test-all` runs that scheme, the Python helper tests, the worker tests, and `make test-integration`. The integration target needs the Docling venv and is not part of CI.

The unit-only macOS command CI uses is:

```bash
xcodebuild test \
  -project Chunky.xcodeproj \
  -scheme Chunky \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ChunkyTests \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

`make test-python` runs `test_docling_convert` and `test_fastembed_daemon` without live Docling or embedding models. `make test-worker` is `pytest` in `worker/`.

`make build-web` installs the locked frontend dependencies, checks Svelte/TypeScript, and builds the worker assets. `make test-web` also runs frontend unit tests and browser component tests with mocked worker responses. Browser tests need Playwright Chromium; they do not run Docling, a GPU, or a live Qdrant server.

From a Linux checkout, `python3 -m pytest -q worker` is the suite that can run here. Swift tests need the macOS runner.

## Conventions

- Unit tests only. Integration tests stay outside CI. Do not add a live network, a GPU, or a Qdrant server to CI.
- Do not add code comments. Do not add doc comments. Tool directives that change compilation or lint stay: `noqa`, `type: ignore`, and generated `swiftlint` or `swift-format-ignore` lines.
- A UI change needs a real screenshot from the macOS runner, usually `ImageRenderer` or an `NSHostingView` in a unit test. Browser UI changes use Playwright captures of the production frontend on that runner. The test must fail when the PNG is blank. Put the image in the pull request.
- Tickets are Linear team PER, project Chunky. Name the branch for the ticket, link the issue from the pull request, and move the status when the work starts and when it merges.
- No behavior change belongs in a cleanup diff. Do not create release tags.
- Secrets stay in the Keychain or in worker token files. Do not commit tokens, Qdrant keys, or machine addresses.

## CI

`.github/workflows/ci.yml` runs on pull requests and on `main`.

- Python 3.12: `pytest` for `worker/` and `unittest` for `test_docling_convert` and `test_fastembed_daemon`.
- macOS: Xcode 27.2, `xcodebuild test` with `-only-testing:ChunkyTests`. UI tests are excluded. Codesigning is off.
- The macOS job is skipped when a change is only Python, `worker/`, `docs/`, or other markdown. A skipped required check still counts as success. A failed path filter does not skip the job.
- `swift test --skip IntegrationTests` in `qdrant-swift` runs only when that package or the workflow changes.
- Screenshot artifacts are uploaded from `/tmp/chunky-*.png`.
- `.github/workflows/web-ui.yml` checks the frontend, builds worker assets and their wheel package, runs mocked browser component tests on the macOS runner, and uploads `/tmp/chunky-web-*.png`. API requests remain protected by the existing bearer-token policy; the public login/static shell contains no job data or credentials.

Squash-merge when that CI is green and review comments are addressed.
