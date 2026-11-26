# Vector stores

Chunky writes chunk embeddings and searches them. Qdrant is the store the Mac app and the worker already implement. The worker also has a vector-store contract so another database can take the same write and query path. The Mac app still talks to Qdrant through the vendored `qdrant-swift` client.

## What the app does with Qdrant today

The Mac app and the worker both know how to put chunks into Qdrant and read them back. They do not share one client.

**Mac app.** Local processing embeds on the Mac and upserts with `QdrantService` over gRPC (`LocalPackages/qdrant-swift`). Preferences stores the gRPC URL (default `http://localhost:6334`) and the API key in the Keychain. The same service creates collections, payload indexes, and the BM25 text index, and it deletes or moves points. Paper libraries are a tenant keyword index on `library_id`. Collections can snapshot, download, and restore the server. A Colima profile can run a local Qdrant without changing the selected URL. Dataset benchmarks and dataset cloud ingest also target this Qdrant connection.

**Retrieval in the app.** Search, eval, RAG chat, and `Chunky --mcp` call the active collection. Dense search is the default. Hybrid search fuses the dense vector with Qdrant BM25 using reciprocal rank fusion. Filters cover year, author, DOI, title, heading, and element type. Empty filters do not change the query. A document summary is a point with `record_type=document`. Papers-first search returns those summaries and can expand them to chunks. Expand-to-section concatenates sibling chunks that share a heading path. An optional reranker runs in the app. The worker does not call it.

**Worker.** With processing host Devbox, the app either asks the worker to return vectors for a local Qdrant or to upsert Qdrant itself (`ingest_target=qdrant_cloud`). The worker creates the collection, checks the embedding width, and can store a collection embedding identity for the browser. Browser jobs set `use_worker_qdrant=true` and use only `CHUNKY_QDRANT_URL` and `CHUNKY_QDRANT_API_KEY`. Search is `POST /v1/search` (dense or hybrid). The browser lists collections and scrolls points without vectors. Hybrid ingest creates a BM25 text index on `embedding_text` and does not store a batch-local sparse vector.

Payload fields are shared: `text`, `source`, `page`, `page_end`, `headings`, `bboxes` when Docling recorded them, and `doc_title`, `authors`, `year`, and `doi` when the document has them.

## Which stores

The worker contract is for a self-hosted chunking tool: the operator runs the database, chunks carry metadata filters, and the worker can upsert and run a dense query without a live service in unit tests. Qdrant stays in the set. The other four are the closest fit from the usual candidates (pgvector, Milvus, Weaviate, Chroma, Pinecone, LanceDB, Elasticsearch/OpenSearch, Redis).

| Store | Why it is in the set |
| --- | --- |
| Qdrant | Already the app's store. In November 2026 it was the most-searched dedicated vector database in the Brandwave index (42% of tracked searches) and the second most-downloaded Python client in the Soba Labs count (`qdrant-client`, 15.5M downloads that month). Payload filters, hybrid BM25, snapshots, and tenant indexes match the features above. |
| pgvector | Highest adoption in that same download count (`pgvector`, 41.7M) and the most-pulled image among the server images they compared. Postgres is the database operators already run, and chunk metadata is ordinary columns and JSON. |
| Milvus | The self-hosted engine operators reach for when one Postgres is not enough. Its image had about 80M Docker Hub pulls in that comparison, second only to pgvector, and it exposes an HTTP API the worker can call. |
| Chroma | Fourth in the download count (`chromadb`, 8.6M) and the vector database most often named for agent memory in the 2025 Stack Overflow survey (19.7% of those respondents). The HTTP API is small and matches "embed these chunks and search them." |
| Weaviate | Native hybrid query (vector plus BM25), which is the same shape as Chunky's dense and hybrid modes. About 35M image pulls in the same comparison, and a self-hosted HTTP API. |

Not selected, from the same candidate list:

- **Pinecone** leads paid SaaS adoption in Ramp's November 2026 vendor sample (44% of businesses buying in the category). It is managed only, so it is a poor fit for a worker that is meant to sit next to a database the operator runs.
- **LanceDB** is a strong embedded library (about 7.1M downloads that month) and a plausible later store for the Mac app's local files. It is in-process rather than a server the worker already fronts, and it trails pgvector, Qdrant, and Chroma on those client downloads.
- **Elasticsearch and OpenSearch** are search clusters first. Brandwave's vector-database search share for Elastic was 0.19% in October 2026. Standing one up for chunk ingest is a lot of machinery.
- **Redis** is common as a cache (42.9% in that Stack Overflow agent-memory question) but vector search is a module, and the payload model is thinner than Postgres or Qdrant for these chunks.

Sources: [Soba Labs, 17 November 2026](https://sobalabs.ai/blog/most-used-vector-databases/), [Brandwave, October 2026](https://gobrandwave.com/demand/global-en/categories/vector-databases), [Ramp, November 2026](https://ramp.com/vendors/categories/vector-databases), [Stack Overflow Developer Survey 2025](https://survey.stackoverflow.co/2025/). Download and pull counts describe clients and images, not production installs.

## Worker contract

Qdrant is the registered store. pgvector, Milvus, Chroma, and Weaviate register on this same contract.

`chunky_worker.vector_store` is the seam. A store describes a collection, upserts points (`id`, dense vector, payload), runs a dense query, lists collections, and scrolls a page of payloads. Hybrid query is optional. Filters use the same shape as `POST /v1/search`: match, text, any, empty, range, negate, and should. Qdrant implements the contract by delegating to the existing ingestor and searcher. The production Qdrant job and search path still calls those clients directly, so quantization, on-disk tiers, BM25 indexes, collection identity, papers-first, and section expansion are unchanged.

Selection:

| Control | Effect |
| --- | --- |
| Omit `vector_store` | Qdrant, including existing `qdrant_url` jobs and searches. |
| `CHUNKY_VECTOR_STORE` or `--vector-store` | Store used for browser ingest and search (`use_worker_qdrant=true`). |
| Job or search field `vector_store` | Direct API selection. Browser requests cannot override the server store. |
| `CHUNKY_VECTOR_STORE_URL` / `vector_store_url` | `postgresql://` for pgvector. HTTP(S) without userinfo, query, or fragment for the others. |
| `CHUNKY_VECTOR_STORE_API_KEY` / `vector_store_api_key` | Sent as a bearer token. Not written to job responses. |

`ingest.target` stays `qdrant_cloud` for every worker upsert so existing clients keep their enum. `ingest.store` names the database when it is not Qdrant.

## Qdrant-only behavior

These stay on Qdrant until a store grows an equivalent that the app can trust:

- Mac app reads and writes, including snapshots, Colima, dataset ingest, eval, RAG, and MCP.
- Collection embedding identity, quantization, and memory tiers.
- BM25 text indexes and hybrid search where the store does not set `supports_hybrid`.
- Papers-first search, document summaries as a query mode, and section expansion.
- Element-type alias expansion and the tenant payload index.
- Verification's stored-point read and retrieval self-test.

Unit tests inject a client. They do not start Postgres, Weaviate, Milvus, Chroma, or Qdrant.
