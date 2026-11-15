# AGENTS.md

Chunky is a macOS app that turns documents into chunks and Qdrant vectors. Heavy conversion can run on this Mac or on an Ubuntu worker. Retrieval, evaluation, and RAG chat stay in the app. The worker is an HTTP API, not a second UI.

## Layout

- `Chunky/` is the macOS app. `Sources/Models` holds settings, jobs, and eval records. `Sources/Services` holds Docling, Ollama, Qdrant, the worker client, retrieval, pi, and the MCP server. `Sources/Views` is SwiftUI. `Resources/Scripts` is the local Docling pipeline.
- `worker/` is the FastAPI worker (`chunky_worker`). It converts, chunks, embeds, ingests to Qdrant Cloud, and searches. It does not ship a web UI and it does not call a reranker.
- `LocalPackages/qdrant-swift` is the vendored gRPC and REST client. `Sources/QdrantProto` is generated. Leave those files generated.
- `docs/` is the operator guide. `worker/README.md` is the HTTP API.

The app windows are Queue, Collections, Retrieval, Eval, Analytics, and Benchmark. Processing host is Local Mac or Devbox. Devbox URLs are named profiles (Mac Studio 10GbE, Wi-Fi LAN, Tailscale). A profile is a name, a base URL, and a Keychain token. Use applies it. Check reachability calls `GET /v1/health`, then `GET /v1/models`, and reports unreachable, HTTP 401, App Transport Security, success, and latency.

Retrieval searches the active collection. Dense is the default. Hybrid fuses the dense vector with Qdrant BM25 using RRF. An optional rerank step calls an OpenAI-compatible `/v1/rerank` endpoint from the Mac. Eval scores a JSON set with recall@k, MRR, nDCG, and hit rate. RAG chat in the Retrieval tab turns the hits into numbered citations and answers with pi or an OpenAI-compatible chat API. `Chunky --mcp` exposes `search` and `list_collections` on stdio for pi and other MCP clients.

## Toolchain

- Xcode 27.2 on the `xcode-27` runner. The SDK is macOS 27. The deployment target is macOS 27.0.
- Swift 6.4. The app target sets `SWIFT_VERSION` to 5.0 and `SWIFT_DEFAULT_ACTOR_ISOLATION` to `MainActor`. Do not change that language mode as a drive-by.
- Python 3.12 for the worker and for `Chunky/Resources/Scripts`.
- Qdrant `v1.20.1` when a local server is needed. Unit tests do not start it.

## Commands

```bash
make first-launch
make setup-venv
make build
make test
make test-python
make test-worker
make test-all
```

`make test` is the macOS unit suite (`ChunkyTests` only). `make test-python` is `test_docling_convert` and does not need Docling. `make test-worker` is `pytest` in `worker/`. `make test-integration` needs the Docling venv and is not part of CI.

From a Linux checkout, `python3 -m pytest -q worker` is the suite that can run here. Swift tests need the macOS runner.

## Conventions

- Unit tests only. Hans runs integration tests. Do not add a live network, a GPU, or a Qdrant server to CI.
- Do not add code comments. Do not add doc comments. Tool directives that change compilation or lint stay: `noqa`, `type: ignore`, and generated `swiftlint` or `swift-format-ignore` lines.
- A UI change needs a real screenshot from the macOS runner, usually `ImageRenderer` or an `NSHostingView` in a unit test. The test must fail when the PNG is blank. Put the image in the pull request.
- Tickets are Linear team PER, project Chunky. Name the branch for the ticket, link the issue from the pull request, and move the status when the work starts and when it merges.
- No behavior change belongs in a cleanup diff. Do not create release tags.
- Secrets stay in the Keychain or in worker token files. Do not commit tokens, Qdrant keys, or machine addresses.

## CI

`.github/workflows/ci.yml` runs on pull requests and on `main`.

- Python 3.12: `pytest` for `worker/` and `unittest` for `test_docling_convert`.
- macOS: Xcode 27.2, `xcodebuild test` with `-only-testing:ChunkyTests`. UI tests are excluded. Codesigning is off.
- The macOS job is skipped when a change is only Python, `worker/`, `docs/`, or other markdown. A skipped required check still counts as success. A failed path filter does not skip the job.
- `swift test --skip IntegrationTests` in `qdrant-swift` runs only when that package or the workflow changes.
- Screenshot artifacts are uploaded from `/tmp/chunky-*.png`.

Squash-merge when that CI is green and review comments are addressed.
