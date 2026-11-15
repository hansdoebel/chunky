# Models for the Mac and the ROCm devbox

Checked 15 Nov 2026. The two machines are an M4 Max MacBook Pro (MLX, unified memory) and the Ubuntu devbox (AMD R9700, 32 GB, `gfx1201`, ROCm). Nothing here assumes an NVIDIA GPU. Weights sizes are the published download sizes, not a measurement of resident VRAM on the R9700.

Docling itself is **v2.150.1** (14 Nov 2026). The VLM pipeline defaults to the `granite_docling` preset. Chunk export defaults to the hybrid chunker. Sources are listed at the bottom.

Changing the embedding model, or its width, does not rewrite an existing Qdrant collection. Create a new collection. The app probes one vector before upsert and refuses a mismatch.

## What to run

| Role | Target | Default | Alternative | Width | Why this default |
| --- | --- | --- | --- | --- | --- |
| Embedding | Both | `qwen3-embedding:0.6b` (`Qwen/Qwen3-Embedding-0.6B`) | `qwen3-embedding:4b` (`Qwen/Qwen3-Embedding-4B`) | 1024, or 2560 for the 4B | Apache 2.0, 32K context, German and English. The 0.6B fits beside granite-docling on 32 GB. The 4B is the better German retriever and needs a new collection. |
| Page VLM | Devbox | `ibm-granite/granite-docling-258M` via vLLM | Standard pipeline (Heron layout, TableFormer, Tesseract `de-Latn`+`en-Latn`) | n/a | Docling's own VLM preset. DocTags, about 0.5 GB of weights, and it stays on loopback. |
| Page VLM | Mac | `granite-docling-mlx` (`ibm-granite/granite-docling-258M-mlx`) | `smoldocling-mlx` | n/a | MLX build of the same 258M model. SmolDocling is the smaller fallback and is weaker on real pages. |
| Chart VLM | Devbox | `ibm-granite/granite-vision-4.1-4b` on its own vLLM port | Leave chart extraction off | n/a | Apache 2.0. Docling's default chart preset. Do not share the granite-docling port. |
| Chart VLM | Mac | Docling preset `granite_vision_v4_mlx` (same 4.1 repo, MLX) | Preset `granite_vision_v3_3` (older 2B CSV model) | n/a | The 4.1 model is the current Docling default on Apple Silicon when `mlx-vlm` is new enough. |
| Picture description | Devbox | `granite_vision` (`ibm-granite/granite-vision-3.3-2b`) | `qwen` (`Qwen2.5-VL-3B`) | n/a | The 2B Granite Vision preset is the one Docling can serve with vLLM. Turn it on only when the 4.1 chart model is not also resident. |
| Picture description | Mac | `smolvlm` (SmolVLM-256M MLX) | `qwen` (Qwen2.5-VL-3B MLX) | n/a | 256M leaves room for granite-docling MLX. The 3B is the quality step up. |
| Reranker | Either | `BAAI/bge-reranker-v2-m3` | `Qwen/Qwen3-Reranker-0.6B` | n/a | MIT, about 0.6B, strongest small multilingual score in the Jina comparison (MIRACL 69.32). Qwen3-Reranker-0.6B is Apache 2.0 and weaker on MIRACL (57.70). Jina v3 is CC BY-NC, so it is not the default. |

The app's new-install defaults match the first column: embedding `qwen3-embedding:0.6b` at 1024 dimensions, layout Heron, page VLM granite-docling MLX on the Mac and the transformers/vLLM id on the devbox, picture description SmolVLM on the Mac and Granite Vision 3.3-2B on the devbox.

## Embedding

Qwen3-Embedding, from the [model card](https://github.com/QwenLM/Qwen3-Embedding) and the [paper](https://arxiv.org/abs/2506.05176):

| Tag | Hugging Face id | Params | Dimensions | Context | MTEB English v2 mean | License | Ollama download |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `qwen3-embedding:0.6b` | `Qwen/Qwen3-Embedding-0.6B` | 0.6B | 1024 (MRL down to 32) | 32K | 70.70 | Apache 2.0 | 639 MB |
| `qwen3-embedding:4b` | `Qwen/Qwen3-Embedding-4B` | 4B | 2560 | 32K on the card, 40K in the Ollama tag | 74.60 | Apache 2.0 | 2.5 GB |
| `qwen3-embedding:8b` | `Qwen/Qwen3-Embedding-8B` | 8B | 4096 | 32K on the card, 40K in the Ollama tag | 75.22 | Apache 2.0 | 4.7 GB |

The multilingual MMTEB mean for the 8B, as published by Qwen on 5 Jun 2025 and still the figure cited on 7 Nov 2026, is 70.58. Larger 2026 models such as harrier-oss-v1-27b score higher and do not fit next to a VLM on 32 GB.

German retrieval, [compared on 4 Nov 2026](https://christophkind.de/blog/embedding-modelle-deutsch-vergleich) (MIRACL-de nDCG@10): 4B 63.0, 8B 61.9, 0.6B 54.2. The 4B is the alternative when the collection can be rebuilt and the GPU is not also holding granite-docling plus a chart model. EmbeddingGemma 2 and bge-m3 are behind the 4B on that German number.

Queries are instruction-aware. Documents are not. Forgetting `Instruct: …\nQuery: …` on the query costs quality. The app sends the raw query string today.

Ollama, checked on the library tags page 15 Nov 2026: `ollama pull qwen3-embedding` and `:latest` install the **8B**. The app default is the explicit 0.6B tag so a new collection stays 1024 wide.

```bash
ollama pull qwen3-embedding:0.6b
```

On the devbox, Ollama stays on `127.0.0.1:11434`. A pooling vLLM is the alternative when you want the OpenAI embeddings API. Keep it on loopback and on a different port from granite-docling:

```bash
vllm serve Qwen/Qwen3-Embedding-0.6B \
  --runner pooling \
  --host 127.0.0.1 --port 8002 \
  --gpu-memory-utilization 0.15
```

Then set `CHUNKY_EMBEDDING_BACKEND=openai`, `CHUNKY_EMBEDDING_URL=http://127.0.0.1:8002`, and `CHUNKY_EMBEDDING_MODEL=Qwen/Qwen3-Embedding-0.6B`. Use a ROCm build of vLLM. The generic CUDA wheel will not see `gfx1201`.

On the Mac the same Ollama tag is the one the app calls. MLX embedding runtimes exist, and the app does not call them. It calls Ollama or an OpenAI-compatible `/v1/embeddings` URL.

The HybridChunker tokenizes with the same family as the embedding model (`Qwen/Qwen3-Embedding-0.6B` for the default tag). A 4B or 8B job uses that size's tokenizer. The bare name `qwen3-embedding` still maps to the 0.6B tokenizer so older jobs keep their chunk widths. `:latest` maps to the 8B tokenizer.

## Docling pipeline

As of the [CLI reference](https://docling-project.github.io/docling/reference/cli/) fetched 15 Nov 2026:

- `--pipeline` is `standard` unless `--vlm-model` is set, in which case it is `vlm`. `granite_docling` is the default VLM preset.
- `--chunks-type` defaults to `hybrid`. The hierarchical chunker is the base. HybridChunker splits a chunk that exceeds the tokenizer limit and merges small neighbors that share headings. Table headers repeat on each piece unless that would overflow the row.
- Layout default in the [model catalog](https://docling-project.github.io/docling/usage/model_catalog/) is `docling-layout-heron`. The app default is Heron. Egret Large and Egret XLarge are the accuracy alternatives.
- Tables: TableFormer accurate mode. Granite Vision can replace TableFormer. The standard pipeline is the one to use for a dense numeric table. A whole-page VLM is the one to use for a scan, a formula, or code.
- OCR engines in the catalog: Tesseract, EasyOCR, RapidOCR, macOS Vision, SuryaOCR. For German and English on the devbox, Tesseract with `de-Latn` and `en-Latn`. On the Mac, the native Vision OCR is available. The worker does not run MLX.
- Picture classification is `document_figure_classifier_v2`. Chart extraction turns classification on by itself.
- `docling-serve` 1.38.2 (27 Oct 2026) is the HTTP wrapper. Chunky does not call it. The Mac app calls the local Docling scripts, or the Chunky worker.

Page conversion on the devbox:

```bash
vllm serve ibm-granite/granite-docling-258M \
  --host 127.0.0.1 --port 8000 \
  --max-num-seqs 512 \
  --max-num-batched-tokens 8192 \
  --enable-chunked-prefill \
  --gpu-memory-utilization 0.6
```

`0.6` leaves room for `qwen3-embedding:0.6b` on the same 32 GB card. The [GPU guide](https://docling-project.github.io/docling/usage/gpu/) shows `0.9` when the card is dedicated to this server. Flash Attention 2 stays off. `device="cuda"` is correct on a ROCm PyTorch. ONNX has no ROCm execution provider.

On the Mac, Docling selects the MLX weights (`ibm-granite/granite-docling-258M-mlx` or the bf16 MLX id in the vision-model table) when the preset is `granite_docling` and `mlx-vlm` is installed. The app's Mac preset is `granite-docling-mlx`.

Newer whole-page presets in the catalog (LightOnOCR-3, Unlimited-OCR 2, Nemotron Parse) are not the default. Unlimited-OCR 2's own server path is NVIDIA SGLang. Nemotron's best published numbers are not the guarded merge Docling actually runs.

## Chart and picture description

Chart extraction uses Granite Vision 4.1 4B, released 29 Apr 2026, Apache 2.0 ([model card](https://huggingface.co/ibm-granite/granite-vision-4.1-4b)). Docling's preset is `granite_vision_v4` on the devbox and `granite_vision_v4_mlx` on the Mac. The Mac preset reads the same Hugging Face repo through MLX when `mlx-vlm>=0.7.0`.

Give it a second port. Do not point it at the granite-docling server:

```bash
vllm serve ibm-granite/granite-vision-4.1-4b \
  --host 127.0.0.1 --port 8001 \
  --max-num-seqs 64 \
  --max-num-batched-tokens 8192 \
  --gpu-memory-utilization 0.3
```

`CHUNKY_CHART_VLLM_URL=http://127.0.0.1:8001` makes the worker call that server. An empty URL keeps chart extraction in-process on Transformers, and only while a chart job is running. If the card cannot hold granite-docling, the 0.6B embedder, and this 4B model, leave chart extraction off.

Picture description is a different preset. `granite_vision` is Granite Vision 3.3-2B and is the devbox default. `smolvlm` is the Mac default. `qwen` is Qwen2.5-VL-3B, with an MLX build, and is the alternative on the Mac. Qwen2.5-VL-3B is not marked as a vLLM preset in the catalog table fetched 15 Nov 2026, so it is not the devbox default.

## Rerankers

The app does not download a reranker. Retrieval posts this JSON to the URL you type:

```json
{"model": "BAAI/bge-reranker-v2-m3", "query": "...", "documents": ["..."], "top_n": 8}
```

It reads `results[].index` and `results[].relevance_score` (or `score`). That is the Cohere and Jina shape. Hugging Face Text Embeddings Inference uses `texts` and `score` on `/rerank`, so a TEI URL is not a drop-in.

| Model | Size | License | BEIR nDCG@10 | MIRACL | Where it runs |
| --- | --- | --- | --- | --- | --- |
| `BAAI/bge-reranker-v2-m3` | 0.6B | MIT | 56.51 | 69.32 | CPU or ROCm. Best small German and English reranker in this set. |
| `Qwen/Qwen3-Reranker-0.6B` | 0.6B | Apache 2.0 | 56.28 | 57.70 | Ollama GGUF or an MLX server that speaks `/v1/rerank`. |
| `Qwen/Qwen3-Reranker-4B` | 4B | Apache 2.0 | 61.16 | 67.52 | Same family, when the card has room after the embedder. |
| `jinaai/jina-reranker-v3` | 0.6B | CC BY-NC 4.0 | 61.94 | 66.83 | An MLX port exists. The license excludes it as the default. |

The BEIR and MIRACL numbers are the table on the [jina-reranker-v3 model card](https://huggingface.co/jinaai/jina-reranker-v3), fetched 15 Nov 2026. Qwen lists the same three reranker sizes, 32K context, Apache 2.0, on the embedding GitHub page.

Point Preferences, Retrieval, Rerank URL at a server that speaks the JSON above. The model field is the id that server expects. Leave rerank off for the first devbox test.

## Sources

- [Docling v2.150.1](https://github.com/docling-project/docling/releases) (14 Nov 2026)
- [Docling CLI](https://docling-project.github.io/docling/reference/cli/)
- [Chunking](https://docling-project.github.io/docling/concepts/chunking/)
- [Model catalog](https://docling-project.github.io/docling/usage/model_catalog/)
- [GPU support, including the ROCm note](https://docling-project.github.io/docling/usage/gpu/)
- [Vision models](https://docling-project.github.io/docling/usage/vision_models/)
- [docling-serve v1.38.2](https://pypi.org/project/docling-serve/) (27 Oct 2026)
- [Qwen3-Embedding](https://github.com/QwenLM/Qwen3-Embedding) and [arXiv:2506.05176](https://arxiv.org/abs/2506.05176)
- [Ollama qwen3-embedding tags](https://ollama.com/library/qwen3-embedding/tags) (15 Nov 2026: `:latest` is the 8B, 4.7 GB)
- [German embedding comparison](https://christophkind.de/blog/embedding-modelle-deutsch-vergleich) (4 Nov 2026)
- [Open embedding ranks](https://gpuwerk.com/blog/best-open-embedding-models/) (7 Nov 2026)
- [granite-docling-258M-mlx](https://huggingface.co/ibm-granite/granite-docling-258M-mlx)
- [granite-vision-4.1-4b](https://huggingface.co/ibm-granite/granite-vision-4.1-4b)
- [jina-reranker-v3](https://huggingface.co/jinaai/jina-reranker-v3)
