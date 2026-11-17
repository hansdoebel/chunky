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

Install Python 3.12 if the check requests it: `brew install python@3.12`. If Xcode is not selected, use `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`, adjusting the path to your installed Xcode. `make first-launch` completes Xcode's first-launch setup; it may request administrator authentication.

`make run` builds and opens this checkout's `build/DerivedData/Build/Products/Debug/Chunky.app`. It does not search other checkouts' DerivedData. Builds disable code signing, so no Apple Developer account is required. This is a source-build workflow, not a notarized release installer.

The first launch does not need Docker, a GPU worker, Ollama, or downloaded models. Open Preferences and verify that the processing host is Local Mac before trying a local job. Saved settings and credentials are retained; a new build does not reset them.

## Try a small local document

```sh
make setup-venv
```

This installs the pinned Mac script dependencies into `~/.chunky-venv` using `python3.12`. If that directory already contains a venv made with another Python version, choose a separate venv through the app's Python configuration or move the old environment aside yourself before recreating it. Do not delete an environment that another checkout uses. Package installation and first model use require network access and can download substantial model data.

For the first smoke test, choose Standard (no VLM), Local Mac, and chunk-only processing. Submit one short document and verify that the queue completes and the chunk preview contains its text. This separates document conversion from model downloads and database setup. Then test a VLM or embedding provider deliberately. The default local VLM is Granite-Docling MLX on Apple Silicon; a successful build does not prove that a model fits available memory or can download.

## Optional local Qdrant and embeddings

Use the app's local-container controls when available, or the CLI helper below. Do not start both on ports 6333/6334 at once.

```sh
docker context show
make qdrant
make ollama
```

The CLI helper uses the selected Docker context. Confirm that it is your intended local engine first. It starts a detached Qdrant 1.20.2 container named `chunky-qdrant-cli`, binds ports 6333/6334 to loopback, and retains the existing `chunky-qdrant` volume. It does not recreate an existing container or delete any volume. If the named container already exists, inspect it with `docker inspect chunky-qdrant-cli`; start a stopped compatible container with `docker start chunky-qdrant-cli`. An older or conflicting container needs an explicit operator decision before replacement. `docker stop chunky-qdrant-cli` stops it without deleting stored vectors.

`make ollama` runs Ollama in the foreground. If Ollama is already running, use that instance. Pull the model selected in Preferences; the documented default is `qwen3-embedding:0.6b` with 1024 dimensions. A different model or dimension requires a compatible collection. Chunky must not silently reconfigure an existing collection. CPU FastEmbed and OpenAI-compatible providers remain available alternatives.

For an ingest smoke test, use a new disposable collection with an explicit name, ingest one small document, then search for a phrase it contains. Verify the selected provider, model and dimensions before ingest. Keep real libraries out of benchmark/fixture collections.

## Checks and cleanup

```sh
make test-setup
make test-python
make clean
```

`make clean` targets only this checkout's Xcode build directory. It does not remove global DerivedData, Python environments, model caches, datasets, saved settings, Keychain entries, containers or database volumes. Native app tests run in macOS CI; `make test` additionally includes UI tests. The worker and browser have separate commands in [the README](../README.md).

See [the version audit](version-audit.md) for verified dependency versions and the distinction between a pinned server version and the separately versioned Python client.
