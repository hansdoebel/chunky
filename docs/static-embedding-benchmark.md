# Static CPU embedding comparison (PER-181)

Status: measurement and runner integration pending. The Benchmark screen can import
and inspect a version 1 JSON comparison report. It does not run the comparison or
verify the truth of externally collected measurements. No Mac Studio/R9700 results
have been collected in the Linux coding workspace, and static embeddings remain
opt-in. Do not use the ordinary PDF conversion benchmark to claim an embedding-only
speed comparison: its conversion/chunking workload can differ across providers.

## Reproducible measurement protocol

1. Export one frozen set of existing PER-129 cached Docling chunks. Keep stable
   point IDs and the exact `embedding_text` bytes. Record Docling version, tokenizer,
   chunk sizes, overlap and options in `chunking`. SHA-256 the frozen JSON file;
   copy those exact bytes to both machines. Never convert/chunk again per model.
2. Prepare a manually labeled query set in the existing Eval JSON format (`name`,
   `queries` with stable UUID `id`, `question`, `relevantIDs`). Use stable point IDs
   as relevance labels and the same query UUIDs, labels and text in every run.
   Synthetic questions are useful for smoke tests, not evidence of paper-RAG quality.
3. Resolve the exact supported Potion identifier through PER-179's model catalog.
   Record its immutable model revision, FastEmbed/package version, CPU runtime,
   machine/OS, and measured dimensions. On the R9700 record the equivalent immutable
   Qwen3-Embedding-0.6B artifact revision, backend version and accelerator runtime.
   Confirm each provider's document and query paths share its own vector space.
4. Use a fresh `chunky-benchmark-*` collection per model configuration. Never reuse
   production collections or a collection belonging to the other model. Use existing
   dimension/model checks, named dense vectors, Qdrant BM25 sparse vectors and RRF
   from PER-51/PER-84. Record Qdrant version and settings with the raw results.
   Run dense and hybrid queries against the same indexed collection for each model.
   This first comparison excludes reranking; hold filters, RRF weights and top-k at
   identical settings. Do not substitute a handwritten BM25 or RRF implementation.
5. Download models before measuring. Stop the provider process, measure model load
   plus first embedding as cold startup (state explicitly whether OS caches are
   cold). Then measure the same request in that persistent process as warm startup.
   Disable vector cache reads. Time document embedding alone, then ingestion through
   successful upsert/visibility; `indexingSeconds` is total embedding plus ingestion
   time, not just the Qdrant RPC. Use identical batching and record its size.
6. Run all labeled queries at k=10 in both modes using the existing retrieval path.
   Record end-to-end per-query latency in milliseconds and ranked stable point IDs.
   Repeat paired trials; include each complete trial as a separate run with a new ID.
   Measure process-tree peak resident memory **on the embedding host**, including
   the resident inference server; a client's memory is not the R9700 server's memory.
   Save OS tool output and timing logs with the report. Do not infer remote RSS.
7. Import the combined JSON using **Benchmark → Import embedding comparison…**.
   The existing Eval scoring functions calculate recall@10, MRR@10, nDCG@10, hit rate
   and mean query latency from the ranked results. Throughput is chunk count divided
   by embedding time. No collection is created/modified by importing a report, and
   no provider/default settings change. Retain the raw report alongside the logs.

## Report schema

The report has `schemaVersion: 1`, `corpusSHA256` (64 hex digits), `chunkCount`,
`chunking`, `set` (existing Eval JSON), and `runs`. Every run contains:

| Field | Value |
| --- | --- |
| `id` | Unique UUID per measured trial and retrieval mode |
| `corpusSHA256` | Hash matching the frozen common corpus |
| `model`, `modelRevision` | Exact model identifier and immutable artifact revision |
| `dimensions` | Probed embedding width |
| `machine`, `runtime` | Actual embedding machine/OS and provider version/runtime; include batch size |
| `collection` | Separate throwaway collection per model configuration |
| `hybrid` | `false` for dense, `true` for existing BM25 RRF |
| `coldStartupMs`, `warmStartupMs` | Measured startup latencies |
| `embeddingSeconds`, `indexingSeconds` | Positive embedding time and total indexing time |
| `peakMemoryBytes` | Measured peak RSS on embedding host |
| `results` | One object per query: `queryID`, unique ranked `retrievedIDs`, `latencyMs` |

At least two distinct models must each have dense and hybrid results. Import rejects
mismatched corpus hashes, incomplete/duplicate query IDs, missing provenance,
invalid timings, zero dimensions, production collection names, model configurations
sharing collections, and dense/hybrid pairs using different collections. These are
consistency checks on declared metadata, not independent model compatibility proof.

The view is session-only; raw JSON is the durable record. Do not label a report as
validated quality until a human has reviewed relevance labels, raw timings and model
compatibility. A real screenshot is generated by `comparisonScreenshotIsNotBlank`
on the macOS test runner; no screenshot has been rendered in the Linux workspace.

## Remaining acceptance work

An automated measurement runner integrating PER-179, actual paired Mac Studio and
R9700 measurements, retrieval-quality review, macOS test execution and CI screenshot
review are still required. This change provides report validation and presentation;
it does not complete PER-181 or recommend making static embeddings the default.
