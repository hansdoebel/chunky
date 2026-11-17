# Qdrant Swift client provenance

Chunky uses its local Swift package so an upstream release cannot silently change a built app. `tools/vendor/qdrant-swift.json` pins the standalone repository commit. `tools/vendor/qdrant-swift.patch` records the compatibility changes needed by the app. Generated Swift comes directly from the upstream snapshot and is not patched by hand.

To verify a checkout of the standalone repository against the vendored client:

```bash
python3 tools/vendor/sync_qdrant.py /path/to/qdrant-swift
```

After reviewing a new upstream revision, update the manifest and compatibility patch, then run the command with `--update`. Run the vendored unit suite, Chunky unit suite, and integration checks before merging. The command only replaces the paths named in the manifest; it preserves Chunky's existing package documentation and CI configuration.

The app's five direct consumers are QdrantService, QdrantModels, DocumentProcessor, RetrievalService and SparseVectorService. The compatibility patch retains collection vector dimensions/names, scalar/binary/product quantization, named dense plus sparse IDF ingest, and tenant keyword index creation. Collection metadata with several unknown named vectors must remain ambiguous instead of selecting an arbitrary dimension. Dense and sparse query inputs use the upstream VectorInput representation. Saved settings, worker profiles and collection contents require no migration.

Hybrid BM25 requests, embedding identity metadata, collection health and snapshots also have app-owned HTTP paths. Those remain app-owned and must be covered when validating a client update. No client sync should create, reconfigure or overwrite a user's collection.

Synchronization refuses modified, untracked, and ignored files under managed paths before replacing anything. The compatibility patch also fixes upstream mock reset tracking until that fix is adopted upstream ([PER-204](https://linear.app/hansdoebel/issue/PER-204)). Run guard regressions with `python3 -m unittest discover -s tools/vendor -p "test_*.py"`.

Strict-mode limits require explicit `StrictModeConfig(enabled: true, ...)`. The nil default preserves server defaults and explicit false disables enforcement. This upstream fix is tracked in [PER-211](https://linear.app/hansdoebel/issue/PER-211); both transports preserve omitted/false/true values.
