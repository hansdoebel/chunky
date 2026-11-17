# Dataset ingestion into Qdrant Cloud

Open **Window → Dataset Cloud Ingest** after downloading a dataset in Datasets. This is separate from the small embedding benchmark: it streams verified snapshots up to 1 GiB / one million source rows instead of loading the corpus into memory.

Choose the snapshot folder and a top-level text field. Choose 512, 2,048 or 8,192 UTF-8 bytes per chunk. Long rows split at Unicode scalar boundaries, without overlap or dropped bytes; these boundaries need not be sentences or grapheme boundaries. Every point records the original dataset revision, content hash, row, text field and byte offset. Missing or blank text fails the full plan rather than silently skipping rows. The selected embedding model must accept the chosen chunk size; provider errors stop the operation.

Configure the Cloud URL and database API key in Preferences, alongside the embedding provider/model. Embeddings run through that configured provider from this Mac. The worker processing profile is unchanged. Cloud connections require HTTPS; credentials remain in the existing Keychain settings. Choose the Cloud tier explicitly, then enter currently available RAM and disk on the least-free node from the Cloud Console. Values use decimal GB (1 GB = 1,000,000,000 bytes), not GiB.

**Prepare import plan** verifies all source blocks and scans every selected row. It probes both document and query encoders and checks dimensions. The plan includes every generated chunk; no collection is created during planning. Review the result, then choose **Create new collection and ingest**. Editing the field, chunk size, tier or capacity invalidates the plan. Changes to connection or embedding settings require another plan.

Free Cloud currently provides one node, 1 GB RAM and 4 GB disk. These are ceilings, not an assumption that your cluster is empty. Standard/Premium capacity depends on provisioned resources; there is no fixed paid storage allowance. The app does not resize or reconfigure a cluster. Current matched per-pod RAM and per-volume disk metrics must be available. The least remaining capacity is used, retaining 20% of each node/volume's total capacity. Missing, ambiguous or invalid metrics stop the import rather than treating the cluster as empty.

## What the estimate means

Compressed Parquet download size, local JSONL size and Qdrant resource use are different quantities. The plan counts float32 vector originals (four bytes per dimension), JSON text and provenance, HNSW with m=16, and ID tracking. Payload accounting rounds each JSON payload to 128-byte blocks with an extra block allowance, then applies a 1.5 storage factor. It gives no credit for compression or quantization. RAM conservatively includes vectors, graph/IDs and three times the payload-storage estimate, with 20% overhead plus 64 MiB. Disk reserves twice estimated persistent storage plus 64 MiB for temporary work. These are conservative planning choices, not guaranteed upper bounds.

Every import creates a new uniquely named `chunky-dataset-test-…` collection. Vectors, HNSW and payload use cold storage, with one shard and one replica. No payload indexes or quantization are added. Server vector/payload byte safeguards are set on creation and read back before upload; if the server rejects or does not preserve them, there is no unguarded fallback. These server limits use cached current-size accounting: they can overshoot, exclude graph/WAL and other structures, and do **not** guarantee a disk-volume ceiling. App-side cumulative planning, bounded batches and fresh capacity checks remain necessary.

The import embeds/uploads at most 16 chunks per batch. It rechecks remaining capacity before embedding and before uploading. A model dimension change, quota refusal, unavailable metrics, cancellation or changed source block stops the operation. Verified earlier chunks may remain. The report counts only acknowledged writes; an interrupted request may have written additional points. No automatic deletion, resume or retry occurs. Existing collections and active model/worker settings are preserved. Points have no `library_id`; select Default library when browsing them.

No live benchmark result or successful Cloud import is implied by the UI screenshots, which use labelled rendering fixtures. Native unit tests use mocked operations. A live Cloud deployment must expose the documented metrics labels and support the verified collection options.

## Curated pre-embedded rows

Enable **Use curated pre-embedded vectors** for the pinned Qdrant DBpedia profile. The source repository, immutable revision, configuration and split must match the built-in profile. The configured provider must be OpenAI-compatible with the exact `text-embedding-3-small` model and 1,536 dimensions. The selected gateway must confirm that model in its response; the app does not add authentication or silently configure the official OpenAI endpoint.

This mode reads only `text-embedding-3-small-1536-embedding` and `combined_text`; the older `openai` column is never substituted. Every row's vector is checked during the complete planning pass and again while ingesting. Unknown profiles, wrong model identity, booleans, missing vectors, zero/nonfinite values or changed dimensions fail closed. Original rows are neither rechunked nor re-embedded. The strict query model probe runs before planning completes and again before collection creation. A verified embedding identity is registered only for the new collection, allowing retrieval to enforce the same model. See the curated-profile documentation for its exact source revision and compatibility constraints.

## Sources checked 2026-11-17

- [Cloud cluster resources](https://qdrant.tech/documentation/cloud/create-cluster/)
- [Capacity planning](https://qdrant.tech/documentation/capacity-planning/)
- [Cloud scaling](https://qdrant.tech/documentation/cloud/cluster-scaling/)
- [Cloud metrics reference](https://qdrant.tech/documentation/cloud/cluster-metrics-reference/)
- [Collection strict-mode safeguards](https://qdrant.tech/documentation/ops-configuration/administration/)

The Qdrant 1.20.2 create/readback schema was separately exercised against an isolated local fixture, including atomic refusal when a collection name already exists. That fixture is API evidence, not a Cloud capacity or production benchmark.
