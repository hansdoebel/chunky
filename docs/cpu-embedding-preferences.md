# Local CPU embedding settings

In Preferences → Embedding, select **FastEmbed (local CPU)**. The first model is `minishlab/potion-retrieval-32M`, producing 512-dimensional vectors with FastEmbed's NumPy CPU runtime. It is opt-in; existing installations keep their saved provider, model, dimensions and worker profiles. Switching providers through Preferences remembers each provider's previous model and dimensions.

**Check readiness** checks the existing Python environment and cached model without downloading it. **Download model** explicitly prepares the model while online. The status displays missing dependencies, missing cache files or other runtime errors. After preparation, cached models can run offline. See [local CPU provider setup](local-cpu-embeddings.md) for the Python environment and model cache paths.

Processing host and embedding host are separate labels. FastEmbed always runs on the Local Mac CPU. Select **Local Mac** in Documents before indexing with this provider. A Devbox processing job combined with FastEmbed is blocked; Chunky does not silently move its embeddings to the worker. Existing Ollama and OpenAI-compatible settings remain available.

The queue's job settings summary shows processing host, embedding host, provider, model, dimensions and CPU readiness before Start. Retrieval exposes the same CPU provider and fixed model. Choose a collection created for this exact provider/model. A matching vector width alone does not make different embedding models compatible.

A CPU collection with no saved model identity, or a saved collection plan with a different model, provider or dimension, produces a warning and blocks indexing or retrieval. Runtime validation additionally checks the actual collection before writing/searching. Chunky never resizes, replaces, or re-embeds an existing collection automatically. Create a separate collection to try the CPU model and keep the original collection for its original embeddings.
