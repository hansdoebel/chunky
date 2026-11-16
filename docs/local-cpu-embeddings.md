# Local CPU embeddings

The opt-in FastEmbed provider uses `minishlab/potion-retrieval-32M`, 512 dimensions, MIT license. FastEmbed 0.9.1 registers this exact model in `fastembed/text/static_embedding.py`. `TextEmbedding.passage_embed` and `query_embed` select the document and query paths. Potion needs no prefixes. Static inference uses NumPy on CPU, not ONNX GPU or R9700 Vulkan.

Run `make setup-venv` to install the pinned FastEmbed dependency into the existing `~/.chunky-venv`. In Preferences select local CPU, then Download model while online. Model files are cached at `~/.cache/chunky/fastembed` (`CHUNKY_FASTEMBED_CACHE` overrides this directory). Health checks and normal embedding requests use `local_files_only=True`; a missing cache reports setup/download instructions. Only the explicit Download action permits a download. A cached model supports offline document and query inference; Qdrant must still be reachable.

One JSON-lines Python child persists across batches and queries. Cancellation terminates that child, and subsequent requests restart it. No worker embedding request is routed to the devbox for this provider: select Processing host Local Mac. Existing Ollama and OpenAI-compatible providers retain their endpoints and defaults.

Create a dedicated collection plan naming the exact provider, model, and 512 dimensions before ingest or search. Same dimensions alone do not establish vector-space compatibility. Local CPU operations refuse unknown or mismatching collection plans; they never resize, recreate, or convert an existing collection. The usual server dimension probe remains active. Plans describe intent and cannot prove the origin of externally populated collections: use a new empty collection for this model.

Tests: `cd Chunky/Resources/Scripts && python3 -m unittest test_fastembed_daemon`. macOS CI runs `FastEmbedTests` alongside the existing Swift suite. Live download/offline ingestion requires the Mac runtime and a separate test Qdrant collection; it is not run in unit CI. Static embeddings remain opt-in pending retrieval-quality measurements.
