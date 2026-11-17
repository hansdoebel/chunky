# Chunky worker workspace

A Svelte application served by the worker at `/`. All API requests use the same origin. The access token and processing preferences stay in memory until sign out or reload. A configured worker bearer token is required.

Use Bun 1.4.4 and Node 26.13.1 (for tool compatibility):

```sh
bun install --frozen-lockfile
bun run check
bun run test:unit
bun run build
bun x playwright install chromium
bun run test:browser
```

The production build writes to `../chunky_worker/web_dist/`. Run the worker to serve that build with its authenticated API. `bun run preview` serves the built application on `127.0.0.1:4173` for browser tests; it does not provide a worker API.

Browser tests route every `/v1/` request to deterministic fixtures. Their documents, processing events, chunks and model names are test data, not results of actual document conversion or embedding. They exercise the production application and produce `/tmp/chunky-web-queue.png`, `/tmp/chunky-web-chunks.png`, `/tmp/chunky-web-settings.png`, `/tmp/chunky-web-mobile.png`, `/tmp/chunky-web-collections.png`, `/tmp/chunky-web-search.png`, and `/tmp/chunky-web-collections-mobile.png`. Each screenshot checks visible application content and rejects blank images by pixel contrast and opacity. Repository CI captures the required macOS screenshots.

Qdrant ingest uses only the worker target. The browser never requests Qdrant credentials. The worker validates collection identity and rejects incompatible existing collections; select a new collection when changing embedding models. Chunk previews request results without vectors. JSON with vectors is fetched only when the user explicitly downloads a finished result.

Collections use authenticated worker routes for cursor-paginated browsing (up to 50 points per page) and semantic search (10 results per page). The browser never connects to Qdrant directly. A configured keyless target can be browsed even when ingestion is unavailable. Unknown collection identities remain browsable but disable semantic search. Query model/provider/endpoint choices are separate from upload settings and must match the collection's verified embedding identity; changing a query setting clears stale results. Collection changes, navigation, and sign out abort pending requests and discard late responses.

Appearance defaults to the operating system and follows changes immediately. The Appearance control is available before sign-in and throughout the workspace. Explicit System, Light, or Dark choices persist only the nonsecret `chunky.appearance` enum; sign-out retains that preference and clears authenticated session data. Blocked browser storage does not prevent theme changes. Semantic color tokens cover controls, status messages, previews, and collections in both themes.

The UI uses official shadcn-svelte 1.8.1 registry components (Vega preset) with Tailwind CSS 4.3.5, native accessible selects, and system fonts. Component aliases and registry configuration live in `components.json`; generated components live under `src/lib/components/ui`. Vendored component licensing is served at `/assets/THIRD_PARTY_NOTICES.txt`. Theme initialization and generated styles respect the worker's existing content security policy without inline bootstrap scripts.

Theme browser tests additionally capture `/tmp/chunky-web-light-login.png` and `/tmp/chunky-web-dark-{login,queue,settings,collections,search,mobile}.png`. These use the same synthetic fixtures and blank-image checks as the light screenshots. Linux local captures supplement the required macOS CI validation.

Parallel worktrees must set distinct `CHUNKY_WEB_TEST_PORT` and `CHUNKY_WEB_SCREENSHOT_DIR` values. Browser tests always launch their own preview server and fail if that port is already occupied. CI uses the default isolated runner port and `/tmp` screenshot directory.
