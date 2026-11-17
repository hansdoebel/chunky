# First run on a MacBook

The native app requires macOS 27 or newer, Xcode 27.2 or newer with Swift 6.4, and Python 3.12 for local document processing. These requirements also apply to the vendored Swift client. Updating Xcode alone does not make the app run on an older macOS release.

## Build and open the app

From a fresh checkout:

```sh
git clone https://github.com/hansdoebel/chunky.git
cd chunky
make first-launch
make doctor
make run
```

Python is optional for building and opening the app. Install Python 3.12 before local document processing: `brew install python@3.12`. If Xcode is not selected, use `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`, adjusting the path to your installed Xcode. `make first-launch` completes Xcode's first-launch setup; it may request administrator authentication.

`make run` builds and opens this checkout's `build/DerivedData/Build/Products/Debug/Chunky.app`. It does not search other checkouts' DerivedData. Builds disable code signing, so no Apple Developer account is required. This is a source-build workflow, not a notarized release installer.

The first launch does not need Docker, a GPU worker, Ollama, or downloaded models. Open Preferences and verify that the processing host is Local Mac before trying a local job. Saved settings and credentials are retained; a new build does not reset them.

## Try a small local document

```sh
make setup-venv
```

This installs the pinned Mac script dependencies into `~/.chunky-venv` using `python3.12`. If that directory already contains a venv made with another Python version, choose a separate venv through the app's Python configuration or move the old environment aside yourself before recreating it. Do not delete an environment that another checkout uses. Package installation and first model use require network access and can download substantial model data.

For the first smoke test, choose Standard (no VLM), Local Mac, and chunk-only processing. Submit one short document and verify that the queue completes and the chunk preview contains its text. This separates document conversion from model downloads and database setup. Then test a VLM or embedding provider deliberately. The default local VLM is Granite-Docling MLX on Apple Silicon; a successful build does not prove that a model fits available memory or can download.

## Optional local Qdrant and embeddings

Install `colima` and the Docker CLI with `brew install colima docker`, then open **Preferences → Qdrant** and choose **Start Qdrant**. The app uses its dedicated `chunky` Colima profile and explicit socket, without switching your Docker context. It starts the `chunky-qdrant` container with persistent volume `chunky-qdrant-data`. First start downloads a VM and Qdrant image. **Stop Qdrant** and **Stop VM** require confirmation and retain stored data. See [local Qdrant controls](local-qdrant.md) for ownership checks and conflicts.

The panel does not select a connection for you: explicitly choose the local Qdrant endpoint in the existing connection controls, then check the connection. Native CI validates command fixtures and the rendered controls; a real Colima VM start still needs a manual Mac smoke test.

Alternatively, use the CLI helper below with your intended Docker engine. It uses a separate container and volume from the app-managed profile. Do not start both on ports 6333/6334 at once.

```sh
docker context show
make qdrant
make ollama
```

The CLI helper uses the selected Docker context. Confirm that it is your intended local engine first. It starts a detached Qdrant 1.20.2 container named `chunky-qdrant-cli`, binds ports 6333/6334 to loopback, and retains the existing `chunky-qdrant` volume. It does not recreate an existing container or delete any volume. If the named container already exists, inspect it with `docker inspect chunky-qdrant-cli`; start a stopped compatible container with `docker start chunky-qdrant-cli`. An older or conflicting container needs an explicit operator decision before replacement. `docker stop chunky-qdrant-cli` stops it without deleting stored vectors.

`make ollama` runs Ollama in the foreground. If Ollama is already running, use that instance. Pull the model selected in Preferences; the documented default is `qwen3-embedding:0.6b` with 1024 dimensions. A different model or dimension requires a compatible collection. Chunky must not silently reconfigure an existing collection. CPU FastEmbed and OpenAI-compatible providers remain available alternatives.

For an ingest smoke test, use a new disposable collection with an explicit name, ingest one small document, then search for a phrase it contains. Verify the selected provider, model and dimensions before ingest. Keep real libraries out of benchmark/fixture collections.

## Download a dataset and benchmark a small sample

Open **Window → Datasets**, search a public dataset such as `BeIR/scifact`, select a configuration and split, and review its card/license. For a first benchmark, use **Legacy row sample (benchmark-compatible)** with a small row limit. The Wikipedia recommendations also offer **Small**, **Medium** and **Large** JSONL budgets of 10 MiB, 100 MiB and 1 GiB; these are bounded first-row samples, not full Wikipedia or estimates of Qdrant storage. The default destination is `~/Downloads/Chunky Datasets`. **Choose folder…** remembers another location; **Use default folder** changes future downloads without moving existing snapshots. Downloads require Dataset Viewer support and a matching immutable revision on every page; private/gated datasets and truncated rows are rejected. See [dataset snapshots](datasets.md).

Open Benchmark and choose **Use downloaded dataset…**. Select the saved snapshot folder, choose a nonempty string field, and set 10–100 rows for a first test. The snapshot hash and revision are checked again. Benchmark accepts snapshots of at most 50 MiB and 10,000 rows, including byte-budget downloads within those bounds. Runs allow at most 1,000 rows, 32 KiB per row and 8 MiB selected text. They use the Mac's current embedding settings even if document processing is set to Devbox; a configured embedding endpoint may still be remote.

Run embedding-only first. After Qdrant is reachable, optionally enable **Also fill a new Qdrant test collection**. It creates a unique `chunky-dataset-test-<UUID>` dense-cosine collection and verifies dimensions before writing real embeddings. Existing collection/provider settings remain selected. Choose the Default paper library when browsing the test points. Cancellation or failure may leave partial test data; inspect it and remove it deliberately when no longer needed. Save the measured report to compare runs with the same snapshot hash. The workflow measures throughput, not retrieval quality without relevance labels. See [dataset benchmarks](dataset-benchmarks.md).

## Try a planned Cloud dataset import

Use **Window → Dataset Cloud Ingest** for larger snapshots or long text that exceeds Benchmark’s limits. Start with a small saved text sample; importing a snapshot processes its complete selected text, not the Benchmark row count. The existing download folder is reused without moving or deleting files.

1. In Preferences, configure the Cloud HTTPS URL, database API key and embedding provider/model. Embeddings run from the Mac through that provider; the worker profile stays unchanged. Open Dataset Cloud Ingest, choose **Choose downloaded dataset…**, and select the snapshot folder. Choose a top-level text field and chunk size appropriate for the model.
2. Choose the Cloud tier explicitly and enter the currently available RAM and disk on the least-free node, in decimal GB. Free Cloud ceilings are 1 GB RAM and 4 GB disk, not assumed free space. Paid capacity depends on provisioned resources. The app also requires matched live per-node metrics and retains 20% capacity headroom; missing metrics stop the plan. No cluster resize is performed.
3. Choose **Prepare import plan**. Review the chunk count, dimensions and resource estimates before choosing **Create new collection and ingest**. Planning checks source integrity and document/query encoders without creating a collection. For Cloud imports, Ollama rejects text beyond its model context and the CPU Potion provider rejects input above 512 actual tokens. Other gateways may impose their own token limits. Existing embedding calls outside Cloud imports retain their defaults. Estimates and server byte safeguards are approximate and cannot guarantee that every storage overhead or concurrent write fits.
4. Inspect the reported new `chunky-dataset-test-…` collection, select Default library when browsing its points, and choose **Save import report…**. A failed or cancelled import can leave partial data, including writes whose acknowledgment was interrupted. There is no automatic deletion, retry or resume; inspect before any deliberate cleanup. Existing collections and selected provider/worker settings are preserved.

For pre-embedded DBpedia, use the curated source and pinned revision described in [pre-embedded compatibility](preembedded-datasets.md), then enable **Use curated pre-embedded vectors**. Configure an OpenAI-compatible query gateway serving exactly `text-embedding-3-small` with 1,536 dimensions and returning that exact model identity. Matching dimensions alone are insufficient. Chunky does not add OpenAI authentication or silently change the endpoint. This mode retains original rows/vectors without rechunking or document re-embedding; queries must use Local Mac routing, even when the database is remote. Worker query routing and ordinary document appends are refused for these registered collections.

These are manual smoke instructions, not a claim of a successful live Cloud import or live OpenAI inference. Native screenshots and unit tests use labelled fixtures/mocks. Local Qdrant API fixtures verify collection options separately from Cloud capacity. See [Cloud ingestion details](dataset-cloud-ingest.md) for accounting, metrics requirements and partial-write behavior. A real Colima VM start also remains a manual Mac check as described above.

## Checks and cleanup

```sh
make test-setup
make test-python
make clean
```

`make clean` targets only this checkout's Xcode build directory. It does not remove global DerivedData, Python environments, model caches, datasets, saved settings, Keychain entries, containers or database volumes. Native app tests run in macOS CI; `make test` additionally includes UI tests. The worker and browser have separate commands in [the README](../README.md).

See [the version audit](version-audit.md) for verified dependency versions and the distinction between a pinned server version and the separately versioned Python client.
