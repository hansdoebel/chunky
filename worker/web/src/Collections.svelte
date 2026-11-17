<script lang="ts">
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Label } from '$lib/components/ui/label';
  import * as Card from '$lib/components/ui/card';
  import * as NativeSelect from '$lib/components/ui/native-select';

  import { onDestroy, onMount } from 'svelte';
  import SearchFilters from './SearchFilters.svelte';
  import { emptySearchFilters, type SearchFilterDraft } from './lib/search-filters';
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
  const papers = $derived(search.resultKind === 'papers' || search.resultKind === 'papers-with-passages');
  let filterDraft = $state<SearchFilterDraft>(emptySearchFilters());
  let results = $state<SearchPage | null>(null);
  const paperCount = $derived(results?.results.filter((point) => point.payload.record_type === 'document').length ?? 0);
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
    filterDraft = emptySearchFilters();
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
    try { request = buildSearchRequest(selected, { ...search, filters: filterDraft }, config, offset); }
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
  <Card.Root class="card collection-unavailable"><h2>Connect a Qdrant target</h2><p>Collection browsing is unavailable until a safe Qdrant URL is configured on the worker. Its credentials stay on the server.</p></Card.Root>
{:else}
  <div class="collection-layout">
    <aside class="card collection-picker">
      <div class="section-heading"><div><div class="eyebrow">{targetLabel}</div><h2>Your collections</h2></div><Button variant="ghost" class="quiet" aria-label="Refresh collections" onclick={() => void loadCollections()} disabled={listing}>↻</Button></div>
      {#if listError}<div class="collection-notice notice danger" role="alert">{listError}</div>{/if}
      {#if listing && !collections.length}<p class="collection-empty" role="status">Loading collections…</p>{:else if !collections.length}<p class="collection-empty">No collections found. Ingest documents into a new collection from Job settings.</p>{:else}
        <nav class="collection-list" aria-label="Collections">{#each collections as name}<Button variant="ghost" class={selected === name ? 'selected' : ''} onclick={() => chooseCollection(name)}><span aria-hidden="true">▦</span><span>{name}</span><span aria-hidden="true">›</span></Button>{/each}</nav>
      {/if}
      <p class="collection-private">Read-only browsing · credentials stay on the worker.</p>
    </aside>
    <div class="collection-content">
      {#if !selected}<Card.Root class="card collection-welcome"><div class="empty-icon" aria-hidden="true">▦</div><h2>A place for every passage</h2><p>Choose a collection to browse its chunks or find a passage with semantic search.</p></Card.Root>{:else}
        <Card.Root class="card collection-detail">
          <div class="section-heading"><div><div class="eyebrow">COLLECTION</div><h2>{selected}</h2><p>{points?.points_count !== null && points?.points_count !== undefined ? `${points.points_count.toLocaleString()} points` : 'Browse stored document passages'}{points?.embedding ? ` · ${points.embedding.dimensions} dimensions · ${points.embedding.model}` : ''}</p></div><Button variant="ghost" class="quiet" aria-label="Refresh collection points" disabled={browsing} onclick={() => chooseCollection(selected)}>↻ Refresh</Button></div>
          <div class="collection-tabs"><Button variant="ghost" class={view === 'browse' ? 'current' : ''} onclick={() => view = 'browse'}>Browse chunks</Button><Button variant="ghost" class={view === 'search' ? 'current' : ''} onclick={() => view = 'search'}>Semantic search</Button></div>
          {#if browseError}<div class="collection-notice notice danger" role="alert">{browseError}</div>{/if}
          {#if view === 'browse'}
            {#if browsing}<p class="collection-empty" role="status">Loading collection points…</p>{:else if points}
              {#if !points.points.length}<p class="collection-empty">This collection has no points on this page.</p>{/if}
              {#each points.points as point (point.id)}<article class="chunk collection-chunk"><div class="chunk-meta"><span>POINT {point.id}</span>{#if source(point)}<span>{source(point)}</span>{/if}{#if page(point)}<span>Page {page(point)}</span>{/if}</div>{#if headings(point)}<h3>{headings(point)}</h3>{/if}<p>{pointText(point)}</p></article>{/each}
              <div class="queue-footer"><span>Page {pageIndex + 1} · up to 50 points per page</span><div><Button variant="ghost" class="quiet" aria-label="Previous points" disabled={pageIndex === 0 || browsing} onclick={() => void loadPoints(selected, cursors[pageIndex - 1], pageIndex - 1)}>← Previous</Button><Button variant="ghost" class="quiet" aria-label="Next points" disabled={points.next_offset === null || browsing} onclick={nextPoints}>Next →</Button></div></div>
            {/if}
          {:else}
            <form class="semantic-form" onsubmit={(event) => { event.preventDefault(); void runSearch(); }}>
              <div><Label for="semantic-query">{papers ? 'Find a paper' : 'Find a passage'}</Label><div class="semantic-query"><Input id="semantic-query" bind:value={search.query} oninput={invalidateSearch} placeholder="Ask about something in your documents…" disabled={!points?.semantic_search_available} /><Button variant="ghost" class="primary" type="submit" disabled={searching || !points?.semantic_search_available || !search.query.trim()}>{searching ? 'Searching…' : 'Search'}</Button></div></div>
              {#if !points?.semantic_search_available}<p class="notice warning" role="status">{points?.semantic_search_reason ?? 'Semantic search needs a verified collection embedding identity. Browsing is still available.'}</p>{:else}
                <div class="field"><Label for="search-result-kind">Search for</Label><NativeSelect.Root id="search-result-kind" value={search.resultKind ?? 'passages'} onchange={(event) => { search.resultKind = event.currentTarget.value as SearchOptions['resultKind']; invalidateSearch(); }}><NativeSelect.Option value="passages">Passages</NativeSelect.Option><NativeSelect.Option value="papers">Papers</NativeSelect.Option><NativeSelect.Option value="papers-with-passages">Papers with supporting passages</NativeSelect.Option></NativeSelect.Root></div>
                <SearchFilters {papers} value={filterDraft} onChange={(next) => { filterDraft = next; invalidateSearch(); }} />
                <details class="query-options"><summary>Query model and search options</summary><div class="query-grid"><div class="field"><Label for="query-backend">Query embedding provider</Label><NativeSelect.Root id="query-backend" bind:value={search.backend} onchange={invalidateSearch}><option value="ollama">Ollama</option><option value="openai">OpenAI-compatible</option></NativeSelect.Root></div><div class="field"><Label for="query-model">Query embedding model</Label><Input id="query-model" bind:value={search.model} oninput={invalidateSearch} /></div><div class="field"><Label for="query-endpoint">Query embedding endpoint <span class="optional">optional</span></Label><Input id="query-endpoint" bind:value={search.endpoint} oninput={invalidateSearch} placeholder="Use worker default" /></div><div class="field"><Label for="query-mode">Search mode</Label><NativeSelect.Root id="query-mode" bind:value={search.mode} onchange={invalidateSearch}><option value="dense">Dense vector</option><option value="hybrid" disabled={!points.embedding?.hybrid}>Hybrid · dense + BM25</option></NativeSelect.Root></div><p class="field-note wide">Use the exact model and worker-side endpoint used to ingest this collection. The worker verifies their identity and dimensions before querying. Search settings do not change upload settings or the collection.</p></div></details>
              {/if}
              <p class="field-note">{papers ? (search.resultKind === 'papers-with-passages' ? 'Up to 10 papers per page. Supporting passages are the top 10 matches across those papers, not all their chunks. Papers need stored document summaries.' : 'Up to 10 paper summaries per page. Papers need stored document summaries.') : '10 results per page · semantic search runs through the worker.'}</p>
            </form>
            {#if searchError}<div class="collection-notice notice danger" role="alert">{searchError}</div>{/if}
            {#if results}
              <div class="search-result-heading"><h3>Search results</h3><span>{results.embedding_model} · {results.embedding_dim} dimensions</span></div>
              {#if !results.results.length}<p class="collection-empty">No matching {papers ? 'papers' : 'passages'} found on this page.</p>{/if}
              {#each results.results as point (point.id)}<article class="chunk collection-chunk"><div class="chunk-meta"><span>{point.payload.record_type === 'document' ? 'Paper summary' : papers ? 'Supporting passage' : 'Passage'}</span><span class="search-score">Score {score(point.score)}</span><span>POINT {point.id}</span>{#if source(point)}<span>{source(point)}</span>{/if}{#if page(point)}<span>Page {page(point)}</span>{/if}</div>{#if headings(point)}<h3>{headings(point)}</h3>{/if}<p>{pointText(point)}</p></article>{/each}
              <div class="queue-footer"><span>{papers ? `${paperCount ? `Papers ${results.offset + 1}–${results.offset + paperCount}` : 'No papers'} · ${results.results.length - paperCount} supporting passages · up to 10 papers per page` : `${results.results.length ? `Showing ${results.offset + 1}–${results.offset + results.results.length}` : 'No results'} · 10 results per page`}</span><div><Button variant="ghost" class="quiet" aria-label="Previous search results" disabled={results.offset === 0 || searching} onclick={() => void runSearch(Math.max(0, (results?.offset ?? 0) - 10))}>← Previous</Button><Button variant="ghost" class="quiet" aria-label="Next search results" disabled={results.next_offset === null || searching} onclick={() => void runSearch(results?.next_offset ?? 0)}>Next →</Button></div></div>
            {:else if searching}<p class="collection-empty" role="status">Finding matching {papers ? 'papers' : 'passages'}…</p>{:else if points?.semantic_search_available && !searchError}<p class="collection-empty">Enter a query to discover relevant {papers ? 'papers' : 'chunks'} in this collection.</p>{/if}
          {/if}
        </Card.Root>
      {/if}
    </div>
  </div>
{/if}
