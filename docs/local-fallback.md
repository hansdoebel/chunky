# Optional Local Mac fallback

In Preferences → Document, select Devbox and enable **Use Local Mac if the worker is unreachable**. The switch is off by default. With it off, worker failures stay errors and no local conversion starts.

With fallback enabled, Chunky checks worker health before submitting a document. A connection failure can start that job locally. A reachable worker that rejects authentication, returns an HTTP error, or is blocked by transport security remains an error. Cancellation never starts fallback. A failed upload, lost event stream, or failed submitted job is never retried locally, because the worker may already be processing it.

The Queue keeps a notice naming Local Mac and its runtime for any fallback job. Analytics records Local Mac as the processing host. Your saved Processing host, models, endpoints, worker profiles, tokens and collection plans stay unchanged.

Set up the local Python environment and models using `make setup-venv` first. Known Granite-Docling and SmolDocling Transformers conversion presets use their matching MLX runtime locally; the standard pipeline stays standard. The fallback uses the Mac accelerator default. If picture description uses the API preset, its VLM endpoint must already be loopback. Unused embedding and VLM endpoints do not block Chunk Only. Local model downloads still require network access on their first use.

For Chunk & Ingest, fallback currently requires:

- The Ollama embedding provider, with the existing Ollama URL pointing to `localhost`, `127.0.0.1`, or `::1`. The embedding model and dimensions are preserved.
- A local loopback Qdrant server without a Qdrant Cloud API key configured. No Cloud key is copied into fallback settings or sent to local services.
- A saved **Local Docker** collection plan whose backend, model and dimensions match the selected embeddings. Existing collection dimensions are checked before upserts. Cloud plans and incompatible plans fail clearly; Chunky never changes their destination or recreates collections to make fallback work.

Other embedding providers and remote endpoints remain configured for worker use; automatic fallback fails clearly until compatible local settings are selected. Chunk Only can use local conversion and the configured export folder without an embedding or Qdrant service.

Fallback uses its own Qdrant connection and temporary settings/cache so concurrent worker jobs cannot reuse its credentials or destination. It generates fresh embeddings rather than reusing worker vectors. Optional remote summary generation and worker-based verification are skipped. The usual local pipeline errors still apply if a required local model or service is unavailable.
