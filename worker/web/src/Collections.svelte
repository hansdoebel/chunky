<script lang="ts">
  import { onDestroy, onMount } from 'svelte';
  import { APIError, buildSearchRequest, type CollectionPage, type CollectionPoint, type SearchOptions, type SearchPage, type WorkerAPI, type WorkerConfig } from './lib/api';

  let { api, config, onAuthFailure }: { api: WorkerAPI; config: WorkerConfig; onAuthFailure: (problem: unknown, client: WorkerAPI) => void } = $props();
  let collections = $state<string[]>([]);
  let targetLabel = $state('Worker Qdrant');
  let selected = $state('');
  let points = $state<CollectionPage | null>(null);
  let listing = $state(false);
  let browsing = $state(false);
  let searching = $state(false);
  let listError = $state('');
  let browseError = $state('');
  let searchError = $state('');
  let view = $state<'browse' | 'search'>('browse');
  let cursors = $state<(string | undefined)[]>([undefined]);
  let pageIndex = $state(0);
  let search = $state<SearchOptions>({ query: '', backend: 'ollama', model: '', endpoint: '', mode: 'dense' });
  let results = $state<SearchPage | null>(null);
  let alive = true;
  let listRevision = 0;
  let browseRevision = 0;
  let searchRevision = 0;
  let listController: AbortController | undefined;
  let browseController: AbortController | undefined;
  let searchController: AbortController | undefined;

  function message(problem: unknown) { return problem instanceof Error ? problem.message : 'The worker could not complete this request.'; }
  function rejected(problem: unknown) {
    if (problem instanceof APIError && (problem.status === 401 || problem.status === 403)) {
      onAuthFailure(problem, api);
      return true;
    }
    return false;
  }
  function invalidateSearch() {
    searchRevision++;
    searchController?.abort();
    results = null;
    searching = false;
    searchError = '';
  }
  function clearCollection() {
    browseRevision++;
    browseController?.abort();
    invalidateSearch();
    selected = '';
    points = null;
    browsing = false;
    browseError = '';
    pageIndex = 0;
    cursors = [undefined];
  }
  async function loadCollections() {
    const revision = ++listRevision;
    listController?.abort();
    const controller = new AbortController();
    listController = controller;
    listing = true;
    listError = '';
    try {
      const reply = await api.collections(controller.signal);
      if (!alive || revision !== listRevision) return;
      collections = reply.collections.map((collection) => collection.name);
      targetLabel = reply.target_label;
      if (selected && !collections.includes(selected)) clearCollection();
    } catch (problem) {
      if (alive && revision === listRevision && !controller.signal.aborted && !rejected(problem)) listError = message(problem);
    } finally { if (alive && revision === listRevision) listing = false; }
  }
  async function loadPoints(collection: string, cursor: string | undefined, index: number, initialize = false) {
    const revision = ++browseRevision;
    browseController?.abort();
    const controller = new AbortController();
    browseController = controller;
    browsing = true;
    browseError = '';
    try {
      const reply = await api.points(collection, cursor, controller.signal);
      if (!alive || revision !== browseRevision || selected !== collection) return;
      points = reply;
      pageIndex = index;
      if (initialize) search = { query: '', backend: reply.embedding?.backend ?? config.embedding_backend, model: reply.embedding?.model ?? config.embedding_model, endpoint: '', mode: 'dense' };
    } catch (problem) {
      if (alive && revision === browseRevision && !controller.signal.aborted && !rejected(problem)) browseError = message(problem);
    } finally { if (alive && revision === browseRevision) browsing = false; }
  }
  function chooseCollection(name: string) {
    clearCollection();
    selected = name;
    view = 'browse';
    void loadPoints(name, undefined, 0, true);
  }
  function nextPoints() {
    if (!points?.next_offset || browsing) return;
    const next = points.next_offset;
    cursors = [...cursors.slice(0, pageIndex + 1), next];
    void loadPoints(selected, next, pageIndex + 1);
  }
  async function runSearch(offset = 0) {
    if (!points?.semantic_search_available || !selected || searching) return;
    let request: Record<string, unknown>;
    try { request = buildSearchRequest(selected, search, config, offset); }
    catch (problem) { searchError = message(problem); return; }
    const revision = ++searchRevision;
    const collection = selected;
    searchController?.abort();
    const controller = new AbortController();
    searchController = controller;
    searching = true;
    searchError = '';
    results = null;
    view = 'search';
    try {
      const reply = await api.search(request, controller.signal);
      if (alive && revision === searchRevision && selected === collection) results = reply;
    } catch (problem) {
      if (alive && revision === searchRevision && !controller.signal.aborted && !rejected(problem)) searchError = message(problem);
    } finally { if (alive && revision === searchRevision) searching = false; }
  }
  function pointText(point: CollectionPoint) {
    const text = point.payload.text ?? point.payload.embedding_text;
    return typeof text === 'string' ? text : 'This point has no chunk text.';
  }
  function headings(point: CollectionPoint) {
    const value = point.payload.headings;
    return Array.isArray(value) ? value.filter((heading): heading is string => typeof heading === 'string').join(' › ') : '';
  }
  function source(point: CollectionPoint) { return typeof point.payload.source === 'string' ? point.payload.source : ''; }
  function page(point: CollectionPoint) { const value = point.payload.page; return typeof value === 'number' || typeof value === 'string' ? String(value) : ''; }
  function score(value: number) { return Number.isFinite(value) ? value.toFixed(4) : 'Unavailable'; }
  onMount(() => { if (config.qdrant_read_available) void loadCollections(); });
  onDestroy(() => {
    alive = false;
    listRevision++;
    browseRevision++;
    searchRevision++;
    listController?.abort();
    browseController?.abort();
    searchController?.abort();
  });
</script>

{#if !config.qdrant_read_available}
  <section class="card collection-unavailable"><h2>Connect a Qdrant target</h2><p>Collection browsing is unavailable until a safe Qdrant URL is configured on the worker. Its credentials stay on the server.</p></section>
{:else}
  <div class="collection-layout">
    <aside class="card collection-picker">
      <div class="section-heading"><div><div class="eyebrow">{targetLabel}</div><h2>Your collections</h2></div><button class="quiet" aria-label="Refresh collections" onclick={() => void loadCollections()} disabled={listing}>↻</button></div>
      {#if listError}<div class="collection-notice notice danger" role="alert">{listError}</div>{/if}
      {#if listing && !collections.length}<p class="collection-empty" role="status">Loading collections…</p>{:else if !collections.length}<p class="collection-empty">No collections found. Ingest documents into a new collection from Job settings.</p>{:else}
        <nav class="collection-list" aria-label="Collections">{#each collections as name}<button class:selected={selected === name} onclick={() => chooseCollection(name)}><span aria-hidden="true">▦</span><span>{name}</span><span aria-hidden="true">›</span></button>{/each}</nav>
      {/if}
      <p class="collection-private">Read-only browsing · credentials stay on the worker.</p>
    </aside>
    <div class="collection-content">
      {#if !selected}<section class="card collection-welcome"><div class="empty-icon" aria-hidden="true">▦</div><h2>A place for every passage</h2><p>Choose a collection to browse its chunks or find a passage with semantic search.</p></section>{:else}
        <section class="card collection-detail">
          <div class="section-heading"><div><div class="eyebrow">COLLECTION</div><h2>{selected}</h2><p>{points?.points_count !== null && points?.points_count !== undefined ? `${points.points_count.toLocaleString()} points` : 'Browse stored document passages'}{points?.embedding ? ` · ${points.embedding.dimensions} dimensions · ${points.embedding.model}` : ''}</p></div><button class="quiet" aria-label="Refresh collection points" disabled={browsing} onclick={() => chooseCollection(selected)}>↻ Refresh</button></div>
          <div class="collection-tabs"><button class:current={view === 'browse'} onclick={() => view = 'browse'}>Browse chunks</button><button class:current={view === 'search'} onclick={() => view = 'search'}>Semantic search</button></div>
          {#if browseError}<div class="collection-notice notice danger" role="alert">{browseError}</div>{/if}
          {#if view === 'browse'}
            {#if browsing}<p class="collection-empty" role="status">Loading collection points…</p>{:else if points}
              {#if !points.points.length}<p class="collection-empty">This collection has no points on this page.</p>{/if}
              {#each points.points as point (point.id)}<article class="chunk collection-chunk"><div class="chunk-meta"><span>POINT {point.id}</span>{#if source(point)}<span>{source(point)}</span>{/if}{#if page(point)}<span>Page {page(point)}</span>{/if}</div>{#if headings(point)}<h3>{headings(point)}</h3>{/if}<p>{pointText(point)}</p></article>{/each}
              <div class="queue-footer"><span>Page {pageIndex + 1} · up to 50 points per page</span><div><button class="quiet" aria-label="Previous points" disabled={pageIndex === 0 || browsing} onclick={() => void loadPoints(selected, cursors[pageIndex - 1], pageIndex - 1)}>← Previous</button><button class="quiet" aria-label="Next points" disabled={points.next_offset === null || browsing} onclick={nextPoints}>Next →</button></div></div>
            {/if}
          {:else}
            <form class="semantic-form" onsubmit={(event) => { event.preventDefault(); void runSearch(); }}>
              <div><label for="semantic-query">Find a passage</label><div class="semantic-query"><input id="semantic-query" bind:value={search.query} oninput={invalidateSearch} placeholder="Ask about something in your documents…" disabled={!points?.semantic_search_available} /><button class="primary" type="submit" disabled={searching || !points?.semantic_search_available || !search.query.trim()}>{searching ? 'Searching…' : 'Search'}</button></div></div>
              {#if !points?.semantic_search_available}<p class="notice warning" role="status">{points?.semantic_search_reason ?? 'Semantic search needs a verified collection embedding identity. Browsing is still available.'}</p>{:else}
                <details class="query-options"><summary>Query model and search options</summary><div class="query-grid"><div class="field"><label for="query-backend">Query embedding provider</label><select id="query-backend" bind:value={search.backend} onchange={invalidateSearch}><option value="ollama">Ollama</option><option value="openai">OpenAI-compatible</option></select></div><div class="field"><label for="query-model">Query embedding model</label><input id="query-model" bind:value={search.model} oninput={invalidateSearch} /></div><div class="field"><label for="query-endpoint">Query embedding endpoint <span class="optional">optional</span></label><input id="query-endpoint" bind:value={search.endpoint} oninput={invalidateSearch} placeholder="Use worker default" /></div><div class="field"><label for="query-mode">Search mode</label><select id="query-mode" bind:value={search.mode} onchange={invalidateSearch}><option value="dense">Dense vector</option><option value="hybrid" disabled={!points.embedding?.hybrid}>Hybrid · dense + BM25</option></select></div><p class="field-note wide">Use the exact model and worker-side endpoint used to ingest this collection. The worker verifies their identity and dimensions before querying. Search settings do not change upload settings or the collection.</p></div></details>
              {/if}
              <p class="field-note">10 results per page · semantic search runs through the worker.</p>
            </form>
            {#if searchError}<div class="collection-notice notice danger" role="alert">{searchError}</div>{/if}
            {#if results}
              <div class="search-result-heading"><h3>Search results</h3><span>{results.embedding_model} · {results.embedding_dim} dimensions</span></div>
              {#if !results.results.length}<p class="collection-empty">No matching passages found on this page.</p>{/if}
              {#each results.results as point (point.id)}<article class="chunk collection-chunk"><div class="chunk-meta"><span class="search-score">Score {score(point.score)}</span><span>POINT {point.id}</span>{#if source(point)}<span>{source(point)}</span>{/if}{#if page(point)}<span>Page {page(point)}</span>{/if}</div>{#if headings(point)}<h3>{headings(point)}</h3>{/if}<p>{pointText(point)}</p></article>{/each}
              <div class="queue-footer"><span>{results.results.length ? `Showing ${results.offset + 1}–${results.offset + results.results.length}` : 'No results'} · 10 results per page</span><div><button class="quiet" aria-label="Previous search results" disabled={results.offset === 0 || searching} onclick={() => void runSearch(Math.max(0, (results?.offset ?? 0) - 10))}>← Previous</button><button class="quiet" aria-label="Next search results" disabled={results.next_offset === null || searching} onclick={() => void runSearch(results?.next_offset ?? 0)}>Next →</button></div></div>
            {:else if searching}<p class="collection-empty" role="status">Finding matching passages…</p>{:else if points?.semantic_search_available && !searchError}<p class="collection-empty">Enter a query to discover relevant chunks in this collection.</p>{/if}
          {/if}
        </section>
      {/if}
    </div>
  </div>
{/if}

<style>
  .collection-layout{display:grid;grid-template-columns:235px minmax(0,1fr);gap:23px;align-items:start}.collection-picker{min-width:0}.collection-picker .section-heading{padding:21px 18px}.collection-picker h2{font-size:15px}.collection-list{padding:8px;display:flex;flex-direction:column;gap:4px}.collection-list button{display:flex;align-items:center;gap:10px;text-align:left;padding:12px;border-radius:7px;background:transparent;color:#657791;font-size:12px}.collection-list button>span:nth-child(2){flex:1;overflow-wrap:anywhere}.collection-list button.selected{background:#edf3ff;color:#175cd3;font-weight:600}.collection-private{border-top:1px solid #edf0f5;padding:16px 18px;font-size:10px;line-height:1.8}.collection-content{min-width:0}.collection-welcome{text-align:center;padding:65px 30px}.collection-welcome p{font-size:12px;max-width:380px;margin:12px auto 0;line-height:1.9}.collection-unavailable{padding:30px}.collection-unavailable p{margin-top:12px;line-height:1.9;max-width:600px}.collection-empty{padding:30px 23px;font-size:12px;line-height:1.9}.collection-tabs{display:flex;gap:20px;padding:0 23px;border-bottom:1px solid #edf0f5}.collection-tabs button{padding:15px 0 12px;background:transparent;color:#8795a9;font-size:12px;border-bottom:2px solid transparent}.collection-tabs button.current{color:#175cd3;border-bottom-color:#175cd3;font-weight:600}.semantic-form{padding:24px;display:flex;flex-direction:column;gap:18px;border-bottom:1px solid #edf0f5}.semantic-query{display:flex;gap:10px;margin-top:9px}.semantic-query .primary{font-size:12px;gap:10px}.query-options{font-size:11px;color:#6f829e}.query-options summary{cursor:pointer;color:#667b9b}.query-grid{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-top:18px}.semantic-form .notice{margin:0}.collection-notice{margin:18px}.collection-chunk .chunk-meta{overflow-wrap:anywhere}.search-score{font-size:10px!important;letter-spacing:0!important;color:#175cd3!important;background:#edf3ff;border-radius:4px;padding:3px 6px}.search-result-heading{display:flex;justify-content:space-between;gap:15px;padding:19px 23px;background:#fafbfd;border-bottom:1px solid #edf0f5}.search-result-heading h3{font-size:12px}.search-result-heading>span{font-size:10px;color:#8b99ac;overflow-wrap:anywhere}
  @media(max-width:1150px){.collection-layout{grid-template-columns:195px minmax(0,1fr);gap:18px}.query-grid{grid-template-columns:1fr}}
  @media(max-width:850px){.collection-layout{grid-template-columns:1fr}.collection-list{display:flex;flex-direction:row;overflow:auto}.collection-list button{min-width:140px;max-width:230px;flex-shrink:0}.collection-picker .section-heading{padding:16px 18px}.collection-private{padding:10px 18px}.collection-welcome{padding:45px 24px}}
  @media(max-width:620px){.semantic-form{padding:20px 17px}.semantic-query{flex-direction:column}.semantic-query .primary{align-self:flex-end}.collection-detail .section-heading{align-items:flex-start;flex-direction:column;gap:10px}.collection-tabs{padding:0 17px;gap:18px}.collection-tabs button{font-size:11px}.collection-detail .queue-footer{align-items:flex-start;flex-direction:column;gap:8px}.search-result-heading{flex-direction:column;gap:5px;padding:17px}.collection-empty{padding:25px 17px}}
</style>
