# Constella query encoder investigation (PER-182)

Evidence retrieved 16 November 2026. Repository baseline: `f0f3ca9` on `main`.

## Recommendation

Keep Constella out of the selectable providers for now. The publisher explicitly establishes the exact asymmetric model pairing below, and the released FastEmbed registry contains it. That establishes a candidate vector space, not verified operation on Chunky's Mac Studio/R9700 topology or acceptable retrieval quality on its scientific corpus. This change records research only: it does not add a query encoder, change defaults, query existing collections, or modify user data. PER-182 remains incomplete pending the runtime, provenance, and evaluation gates below.

Do not close the experiment as not worthwhile yet. Published results suggest a material latency/quality tradeoff that needs measurement with Chunky's data.

## Verified publisher contract

| Property | Query path | Document path |
|---|---|---|
| Exact identifier | `Qdrant/constella-zero` | `Qdrant/stella-en-400M-v5-doc-onnx` |
| Inspected revision | `d06c1cc2b0cbf77be922459bfffe063873e69a3b` | `6f5fd8d461a6c09efdbbd206f8f10cd53c6f9f50` |
| Architecture | int8 token lookup, weighted pooling | Stella 400M transformer, masked mean, `2_Dense_1024` |
| Output | normalized fp32, 1024 dimensions | normalized fp32, 1024 dimensions |
| Language / length | English, truncated at 512 tokens | English, truncated at 512 tokens |
| Prefix | none | no query prefix; documents only |
| Intended index distance | cosine | cosine |
| Published artifact license | MIT | MIT |

The document artifact is an ONNX conversion of `NovaSearch/stella_en_400M_v5` at `ffeb2b7ee715c226d4ffe5e4619f7dbb48624c20`. The publisher identifies that source as MIT and its GTE ancestor as Apache-2.0. Preserve the applicable license and attribution files when redistributing artifacts; the model card also identifies training-data attribution obligations. License metadata was inspected; this is not a legal determination of every downstream distribution obligation.

The query card identifies int8-table SHA-256 `a7007b1a6af120b976f093fd69ddcb5001996ec0b84b5864b4fd25d7af878abf`. The document card identifies ONNX SHA-256 `fe31555e2b40767e17487885fb67dcdf0dcee11bef31f42478e55c1ec69a4ea9`. These are publisher declarations: the model binaries were not downloaded or independently hashed here. A future implementation must pin artifact revisions and verify downloaded files, including tokenizer and configuration assets.

`Qdrant/constella-nano` is a different, transformer-based query encoder for the same document space. It is not the static CPU encoder requested here. Generic Stella variants, alternate projection widths, Potion, and Qwen3 are outside the verified pairing. The default Qwen3 0.6B width is also 1024; matching that width does not establish compatibility.

## Runtime evidence and limits

The query card provides `TextEmbedding("Qdrant/constella-zero")`, and the document card provides `TextEmbedding("Qdrant/stella-en-400M-v5-doc-onnx")`. Their examples call `embed` for each respective role. The graph already pools and normalizes outputs. The document graph must not be used as an unprompted full-Stella query encoder: the original teacher query baseline requires its `s2p_query` prompt.

The cards retain research-preview/preview-branch wording while showing `pip install "fastembed>=0.9.0"`. To resolve the registry question, the published `fastembed-0.9.1-py3-none-any.whl` was downloaded and its Python sources inspected. `fastembed/text/onnx_embedding.py` registers both exact identifiers with `dim=1024`, MIT, and `model.onnx`. The wheel SHA-256 reported by PyPI is `95042ac7f685bda6697861066d49f8b119fbde8b75ed5162bbb7e84e2dad0e1d`. Registry inspection does not prove successful inference, dependencies, or accelerator support.

Both cards describe standard ONNX opset 17. The document graph is about 1.75 GB fp32; its card reports CPU/CUDA comparison, not ROCm or R9700 Vulkan validation. Do not infer R9700 acceleration from ONNX support. A NumPy reference encoder is also published for Zero, but dynamically downloading and executing its Python code is not proposed for Chunky.

No model inference, Mac CPU timing, R9700 timing, collection ingestion/search, or scientific retrieval evaluation was performed in this environment. No new runtime dependencies were introduced.

## Collection safety before an implementation

At this baseline `RetrievalService.searchLocal` probes width and checks the selected Qdrant collection width before search. `EmbeddingDimensions` and the ingest path also guard dimensions. Those checks must remain, but width alone cannot distinguish Stella from default Qwen3. Existing `content_hash` combines text with a model name; it does not establish collection-wide provenance or recover an artifact revision.

Before exposing an opt-in experimental query encoder:

1. Require trusted collection provenance recording the exact document artifact revision, tokenizer revision, projection/pooling/normalization contract, vector name, 1024 width, and cosine distance. Do not infer provenance from a sample point, collection name, width, or user-selected current model.
2. Allowlist the exact document/query pair and versions that have been tested together. Missing, mixed, or unknown provenance must refuse the experimental path with an actionable explanation. Never silently fall back to another encoder or processing host.
3. Keep the existing Ollama/OpenAI paths intact. Do not apply Constella to existing Qwen3/Potion collections. Use a separately named collection for the experiment; never overwrite, resize, relabel, or rebuild an existing collection automatically.
4. Test wrong-model/same-width rejection, wrong vector name/distance/width, unknown revision, mixed provenance, non-finite or malformed outputs, empty/long queries, cancellation, offline cache, and document/query role confusion before shipping.

## Evaluation needed for a ship decision

Reuse the existing cached chunks, fixed labeled Eval query set, `RetrievalEval` scoring and PER-181 benchmark work. Keep identical chunks, IDs, relevance labels and retrieval settings across encoders. Create a separate exact-pair Stella document collection, then compare Constella queries with the prompted full-Stella query path on that same collection. Compare Qwen3 against its own separately embedded collection, never against Stella vectors.

Record exact artifact/runtime versions, corpus and query hashes, truncation counts, machine, CPU threads, execution provider, cold startup, first query, warm p50/p95 query latency, peak RSS, search latency, recall@10, MRR, nDCG@10 and hit rate. Measure dense-only and Chunky's existing BM25/RRF separately. The Zero card recommends BM25/DBSF prefetch 100 and evaluated a particular `bm25s` lexical setup; that published result is not evidence for Chunky's BM25/RRF quality. Any DBSF comparison is a separate explicit experiment, not a silent change to existing hybrid semantics.

The Zero card reports exact-search nDCG@10 of 0.6101 on SciFact and 0.1677 on SCIDOCS versus 0.7796 and 0.2395 for the Stella query teacher. Its reported warm query p50 is 0.1119 ms, with a synthetic encoder-only benchmark. These are publisher results, not Chunky measurements, and are not comparable to end-to-end R9700 or Mac timings without a controlled run. ArguAna/FiQA results are additionally marked by the publisher for teacher training/evaluation contact.

A ship decision is blocked on access to the target machines, frozen scientific corpus and relevance labels, runtime smoke tests, collection provenance enforcement and agreed quality/latency thresholds. Until then keep the feature unavailable and PER-182 open. A research PR merge alone does not satisfy the issue's experimental encoder and comparison acceptance criteria.

## Sources

- [Reference Qdrant article](https://qdrant.tech/articles/embedding-at-the-speed-of-light/): asymmetric query/document proposal and static embedding tradeoff.
- [Pinned Zero model card](https://huggingface.co/Qdrant/constella-zero/blob/d06c1cc2b0cbf77be922459bfffe063873e69a3b/README.md): exact pair, query contract, license, provenance, performance and limitations.
- [Pinned Stella document model card](https://huggingface.co/Qdrant/stella-en-400M-v5-doc-onnx/blob/6f5fd8d461a6c09efdbbd206f8f10cd53c6f9f50/README.md): document computation, source revision, dimensions, conversion tests, license and artifact hash.
- [Zero repository metadata](https://huggingface.co/api/models/Qdrant/constella-zero) and [document metadata](https://huggingface.co/api/models/Qdrant/stella-en-400M-v5-doc-onnx): revisions recorded above; these API endpoints are mutable.
- [FastEmbed 0.9.1 release metadata](https://pypi.org/pypi/fastembed/0.9.1/json): wheel and checksum. Registry source inspected inside that release wheel, not an unpinned GitHub branch.
