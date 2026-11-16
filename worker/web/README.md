# Chunky worker workspace

A Svelte application served by the worker at `/`. All API requests use the same origin. The access token and processing preferences stay in memory until sign out or reload. A configured worker bearer token is required.

Use Node 24.22.1 and npm 11.9.0:

```sh
npm ci
npm run check
npm run test:unit
npm run build
npx playwright install chromium
npm run test:browser
```

The production build writes to `../chunky_worker/web_dist/`. Run the worker to serve that build with its authenticated API. `npm run preview` serves the built application on `127.0.0.1:4173` for browser tests; it does not provide a worker API.

Browser tests route every `/v1/` request to deterministic fixtures. Their documents, processing events, chunks and model names are test data, not results of actual document conversion or embedding. They exercise the production application and produce `/tmp/chunky-web-queue.png`, `/tmp/chunky-web-chunks.png`, `/tmp/chunky-web-settings.png`, `/tmp/chunky-web-mobile.png`, `/tmp/chunky-web-collections.png`, `/tmp/chunky-web-search.png`, and `/tmp/chunky-web-collections-mobile.png`. Each screenshot checks visible application content and rejects blank images by pixel contrast and opacity. Repository CI captures the required macOS screenshots.

Qdrant ingest uses only the worker target. The browser never requests Qdrant credentials. The worker validates collection identity and rejects incompatible existing collections; select a new collection when changing embedding models. Chunk previews request results without vectors. JSON with vectors is fetched only when the user explicitly downloads a finished result.

Collections use authenticated worker routes for cursor-paginated browsing (up to 50 points per page) and semantic search (10 results per page). The browser never connects to Qdrant directly. A configured keyless target can be browsed even when ingestion is unavailable. Unknown collection identities remain browsable but disable semantic search. Query model/provider/endpoint choices are separate from upload settings and must match the collection's verified embedding identity; changing a query setting clears stale results. Collection changes, navigation, and sign out abort pending requests and discard late responses.
