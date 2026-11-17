# Hugging Face dataset snapshots

Open **Window → Datasets** in the Mac app. Search a public dataset name or topic (for example, `BeIR/scifact`), select a result, then choose a configuration/split and row limit. Review the linked dataset card and license before downloading.

The default destination is `~/Downloads/Chunky Datasets`. **Choose folder…** remembers another destination using a security-scoped bookmark. **Use default folder** restores the default for future downloads; neither operation moves or deletes existing snapshots.

Each download creates a unique directory with `rows.jsonl` and `manifest.json`. The manifest records the Hub dataset ID, full immutable revision, configuration, split, license, source link, timestamp, requested/actual/total rows, and SHA-256 of the JSONL bytes. Every Dataset Viewer page must report the selected Hub revision in `X-Revision`; a changed, absent or mismatched revision stops the download. Search again to select the current revision. This avoids mixed-revision exports; historical revisions are not fetched through the Viewer.

Downloads take the first requested rows, not a random or representative sample. Limits are 10,000 rows, 50 MiB per saved snapshot and 5 MiB per HTTP response. A page that contains truncated cells is rejected. Cancellation or a failed request leaves no completed snapshot. Existing files are never overwritten. Private/gated datasets and datasets without Dataset Viewer support are unavailable in this version. The app does not execute remote dataset scripts or download media URLs embedded in rows.

Use the saved folder as the source for a dataset benchmark/test-collection workflow. Corpus text, queries and relevance judgments often live in separate configurations or repositories; downloading a corpus does not manufacture relevance labels or produce retrieval-quality results. The dataset library itself never changes embedding settings or Qdrant collections.

## Validation

Unit fixtures cover paging, immutable revision checks, incomplete/truncated responses, bounds, cancellation, snapshot integrity and saved folder selection. macOS UI captures use fixture metadata rather than claims of measured benchmark performance. A live read-only API probe verified public search, dataset metadata and the `X-Revision` header on `BeIR/scifact`; no model inference or retrieval-quality benchmark is implied.
