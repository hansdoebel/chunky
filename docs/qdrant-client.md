# Qdrant Swift client provenance

Chunky uses its local Swift package so an upstream release cannot silently change a built app. `tools/vendor/qdrant-swift.json` pins the standalone repository commit. `tools/vendor/qdrant-swift.patch` records the compatibility changes needed by the app. Generated Swift comes directly from the upstream snapshot and is not patched by hand.

To verify a checkout of the standalone repository against the vendored client:

```bash
python3 tools/vendor/sync_qdrant.py /path/to/qdrant-swift
```

After reviewing a new upstream revision, update the manifest and compatibility patch, then run the command with `--update`. Run the vendored unit suite, Chunky unit suite, and integration checks before merging. The command only replaces the paths named in the manifest; it preserves Chunky's existing package documentation and CI configuration.

The app's five direct consumers are QdrantService, QdrantModels, DocumentProcessor, RetrievalService and SparseVectorService. The compatibility patch retains collection vector dimensions/names, scalar/binary/product quantization, named dense plus sparse IDF ingest, and tenant keyword index creation. Collection metadata with several unknown named vectors must remain ambiguous instead of selecting an arbitrary dimension. Dense and sparse query inputs use the upstream VectorInput representation. Saved settings, worker profiles and collection contents require no migration.

Hybrid BM25 requests, embedding identity metadata, collection health and snapshots also have app-owned HTTP paths. Those remain app-owned and must be covered when validating a client update. No client sync should create, reconfigure or overwrite a user's collection.

Synchronization refuses modified, untracked, and ignored files under managed paths before replacing anything. Run guard regressions with `python3 -m unittest discover -s tools/vendor -p "test_*.py"`.

Strict-mode limits require explicit `StrictModeConfig(enabled: true, ...)`. The nil default preserves server defaults and explicit false disables enforcement. The upstream fix ([PER-211](https://linear.app/hansdoebel/issue/PER-211)) is included in the pinned snapshot; both transports preserve omitted/false/true values.

Options-based gRPC collection creation preserves the same typed `QdrantError` contract as the legacy overload; REST creation retains its `RESTError` contract, and the upstream fix ([PER-214](https://linear.app/hansdoebel/issue/PER-214)) is included in the pinned snapshot.

The pinned snapshot includes standalone PR #12 (`8a5e3076d52dc48646be7dd70214f46e2800a2f5`), including the mock reset fix ([PER-204](https://linear.app/hansdoebel/issue/PER-204)) and compatible gRPC NIO transport 2.13.0. Upstream now owns strict-mode, typed creation errors and mock-reset regressions; the local patch retains only Chunky compatibility adapters and its hybrid ingest regression.

Payload edits and point deletion preserve both Qdrant point-ID kinds: unsigned 64-bit integers and UUID strings. They use the same stored-ID parser as paper-library moves, including IDs above the signed 64-bit range. Network-free mutation regressions inspect the IDs and payload passed to the client; they do not modify a live collection.

Connection attempts close their candidate client on failure, cancellation or a newer endpoint/disconnect decision. Index readiness is scoped to that connection and collection lifetime, and is recorded only after confirmed field-index responses. A failed best-effort retrieval-index setup remains retryable and exposes a redacted diagnostic in Preferences → Qdrant. Existing incompatible indexes are not automatically replaced; operator review is required. Collection creation can report an index-setup failure after creating the collection, so inspect the existing collection before retrying or removing it.
