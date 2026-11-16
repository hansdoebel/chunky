<script lang="ts">
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Label } from '$lib/components/ui/label';
  import * as Card from '$lib/components/ui/card';
  import * as NativeSelect from '$lib/components/ui/native-select';
  import { Badge } from '$lib/components/ui/badge';
  import AppearancePicker from './AppearancePicker.svelte';

  import { onDestroy } from 'svelte';
  import Collections from './Collections.svelte';
  import JobInsights from './JobInsights.svelte';
  import { APIError, WorkerAPI, buildJobSettings, type Job, type JobOptions, type WorkerConfig, type JobEvent } from './lib/api';

  let token = $state('');
  let api = $state.raw<WorkerAPI | null>(null);
  let config = $state<WorkerConfig | null>(null);
  let connected = $state(false);
  let connecting = $state(false);
  let tab = $state<'queue' | 'settings' | 'collections'>('queue');
  let jobs = $state<Job[]>([]);
  let total = $state(0);
  let offset = $state(0);
  let selected = $state<Job | null>(null);
  let previewPage = $state(0);
  let detailState = $state<'idle' | 'loading' | 'loaded' | 'error'>('idle');
  let files = $state<File[]>([]);
  let uploading = $state(false);
  let refreshing = $state(false);
  let dragging = $state(false);
  let error = $state('');
  let connectionError = $state('');
  let models = $state<string[]>([]);
  let modelNotice = $state('');
  let options = $state<JobOptions>({ mode: 'chunks', backend: 'ollama', model: '', endpoint: '', vlm: 'standard', accelerator: 'cuda', collection: 'documents', hybrid: false, chunkTokens: 512 });
  let generation = 0;
  let selectionGeneration = 0;
  let poll: ReturnType<typeof setInterval> | undefined;
  const streams = new Map<string, AbortController>();
  const active = (job: Job) => job.status === 'queued' || job.status === 'running';
  const labels = { queued: 'Queued', running: 'Processing', succeeded: 'Completed', failed: 'Failed', canceled: 'Canceled' };
  const chunkLimit = 50;
  const chunks = $derived(selected?.result?.chunks ?? []);
  const visibleChunks = $derived(chunks.slice(previewPage * chunkLimit, (previewPage + 1) * chunkLimit));
  const pageEnd = $derived(Math.min(offset + jobs.length, total));

  function clearSession(message = '') {
    generation += 1;
    selectionGeneration += 1;
    api?.dispose();
    api = null;
    for (const controller of streams.values()) controller.abort();
    streams.clear();
    clearInterval(poll);
    connected = false;
    connecting = false;
    config = null;
    token = '';
    jobs = [];
    total = 0;
    offset = 0;
    selected = null;
    detailState = 'idle';
    files = [];
    models = [];
    options = { mode: 'chunks', backend: 'ollama', model: '', endpoint: '', vlm: 'standard', accelerator: 'cuda', collection: 'documents', hybrid: false, chunkTokens: 512 };
    modelNotice = '';
    uploading = false;
    refreshing = false;
    connectionError = '';
    error = message;
    tab = 'queue';
  }

  function failure(problem: unknown, session: number, connection = false) {
    if (session !== generation) return;
    if (problem instanceof APIError && (problem.status === 401 || problem.status === 403)) {
      clearSession(problem.message);
    } else if (!(problem instanceof DOMException && problem.name === 'AbortError')) {
      const message = problem instanceof Error ? problem.message : 'The worker could not complete this request.';
      if (connection) connectionError = message;
      else error = message;
    }
  }

  async function connect(event: SubmitEvent) {
    event.preventDefault();
    if (connecting) return;
    if (!token.trim()) { error = 'Configure a worker access token and enter it to connect.'; return; }
    connecting = true;
    error = '';
    const session = ++generation;
    const candidate = new WorkerAPI(token.trim());
    api?.dispose();
    api = candidate;
    try {
      const settings = await candidate.config();
      if (session !== generation) return;
      config = settings;
      options = { mode: 'chunks', backend: settings.embedding_backend, model: settings.embedding_model, endpoint: '', vlm: 'standard', accelerator: 'cuda', collection: 'documents', hybrid: false, chunkTokens: 512 };
      connected = true;
      token = '';
      await refresh();
      if (session !== generation) return;
      poll = setInterval(() => { void refresh(); }, 3000);
      void candidate.models().then((reply) => {
        if (session === generation) models = reply.embeddings?.map((model) => model.name) ?? [];
      }).catch((problem) => {
        if (session !== generation) return;
        if (problem instanceof APIError && (problem.status === 401 || problem.status === 403)) failure(problem, session);
        else modelNotice = 'Installed models could not be listed. You can still enter a model name.';
      });
    } catch (problem) {
      if (session === generation) { candidate.dispose(); api = null; connected = false; failure(problem, session); }
    } finally { if (session === generation) connecting = false; }
  }

  async function refresh() {
    if (!api || !connected || refreshing) return;
    const session = generation;
    const client = api;
    refreshing = true;
    try {
      let page = await client.jobs(offset);
      if (session !== generation) return;
      if (page.total <= offset && offset > 0) { clearSelection(); offset = 0; page = await client.jobs(0); }
      if (session !== generation) return;
      jobs = page.jobs.map((job) => {
        const previous = jobs.find((item) => item.id === job.id);
        return previous && !active(previous) && active(job) ? previous : job;
      });
      total = page.total;
      if (selected && detailState !== 'loading') {
        const summary = jobs.find((job) => job.id === selected?.id);
        if (summary && ((!active(summary) && active(selected)) || detailState === 'error')) void loadDetail(summary.id);
      }
      connectionError = '';
      reconcileStreams(session, client);
    } catch (problem) { failure(problem, session, true); }
    finally { if (session === generation) refreshing = false; }
  }

  function reconcileStreams(session: number, client: WorkerAPI) {
    const running = new Set(selected && active(selected) ? [selected.id] : []);
    for (const [id, controller] of streams) {
      if (!running.has(id)) { controller.abort(); streams.delete(id); }
    }
    for (const id of running) {
      if (streams.has(id)) continue;
      const controller = new AbortController();
      streams.set(id, controller);
      void client.events(id, (event) => applyEvent(id, event, session), controller.signal)
        .catch((problem) => { if (!controller.signal.aborted) failure(problem, session, true); })
        .finally(() => {
          if (streams.get(id) === controller) streams.delete(id);

        });
    }
  }

  function applyEvent(id: string, event: JobEvent, session: number) {
    if (session !== generation) return;
    const status = event.status && Object.hasOwn(labels, event.status) ? event.status : undefined;
    jobs = jobs.map((job) => job.id === id ? { ...job, status: status ?? job.status, progress: { ...job.progress, ...event } } : job);
    if (selected?.id === id) selected = { ...selected, status: status ?? selected.status, progress: { ...selected.progress, ...event } };
    if (status && !['queued', 'running'].includes(status)) {
      if (selected?.id === id) void loadDetail(id);
      void refresh();
    }
  }

  function clearSelection() {
    selectionGeneration += 1;
    selected = null;
    detailState = 'idle';
    previewPage = 0;
    for (const controller of streams.values()) controller.abort();
    streams.clear();
  }

  function changePage(next: number) {
    clearSelection();
    offset = next;
    void refresh();
  }

  async function selectJob(id: string, acceptedJob?: Job) {
    if (!api) return;
    clearSelection();
    selected = jobs.find((job) => job.id === id) ?? acceptedJob ?? null;
    reconcileStreams(generation, api);
    await loadDetail(id);
  }

  async function loadDetail(id: string) {
    if (!api || selected?.id !== id) return;
    const session = generation;
    const selection = ++selectionGeneration;
    const client = api;
    detailState = 'loading';
    try {
      const job = await client.job(id);
      if (session === generation && selection === selectionGeneration) {
        selected = job;
        detailState = 'loaded';
        reconcileStreams(session, client);
      }
    } catch (problem) {
      if (session === generation && selection === selectionGeneration) {
        detailState = 'error';
        failure(problem, session);
      }
    }
  }

  function chooseFiles(chosen: FileList | File[] | null) {
    if (!chosen || uploading) return;
    files = Array.from(chosen);
    error = '';
  }

  async function upload() {
    if (!api || !config || !files.length || uploading) return;
    const session = generation;
    const client = api;
    let settings: Record<string, unknown>;
    try { settings = buildJobSettings(options, config); }
    catch (problem) { failure(problem, session); return; }
    uploading = true;
    error = '';
    const pending = [...files];
    try {
      for (const file of pending) {
        if (session !== generation) return;
        const accepted = await client.upload(file, settings);
        if (session !== generation) return;
        files = files.filter((item) => item !== file);
        offset = 0;
        await refresh();
        if (session !== generation) return;
        await selectJob(accepted.id, { id: accepted.id, filename: file.name, status: 'queued' });
      }
    } catch (problem) {
      failure(problem, session);
      if (session === generation && !(problem instanceof APIError)) error = 'Upload status may be unknown. Refresh the queue before trying again.';
    } finally { if (session === generation) uploading = false; }
  }

  async function cancelJob(id: string) {
    if (!api) return;
    const session = generation;
    try {
      await api.cancel(id);
      if (session !== generation) return;
      await refresh();
      if (session === generation && selected?.id === id) await selectJob(id);
    } catch (problem) { failure(problem, session); }
  }

  async function download() {
    if (!api || !selected) return;
    const session = generation;
    try {
      const job = await api.job(selected.id, true);
      if (session !== generation) return;
      const url = URL.createObjectURL(new Blob([JSON.stringify(job.result, null, 2)], { type: 'application/json' }));
      const link = document.createElement('a');
      link.href = url;
      link.download = `${job.filename.replace(/[\\/\u0000-\u001f]/g, '_')}.chunks.json`;
      link.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (problem) { failure(problem, session); }
  }

  function collectionFailure(problem: unknown, client: WorkerAPI) {
    if (api === client) failure(problem, generation);
  }

  function percent(job: Job) { return Math.max(0, Math.min(100, job.progress?.percent ?? 0)); }
  function fileSize(size: number) { return size < 1_048_576 ? `${Math.max(1, Math.round(size / 1024))} KB` : `${(size / 1_048_576).toFixed(1)} MB`; }
  function vlmName(id: string) { return id === 'standard' ? 'Standard · no VLM' : id === 'granite-docling-transformers' ? 'Granite-Docling' : id === 'smoldocling-transformers' ? 'SmolDocling' : id; }
  onDestroy(() => { api?.dispose(); clearInterval(poll); for (const controller of streams.values()) controller.abort(); });
</script>

<svelte:head><title>Chunky · Worker workspace</title></svelte:head>

{#if !connected}
  <main class="login-shell">
    <div class="login-appearance"><AppearancePicker id="login" /></div>
    <div class="login-brand"><span class="brand-mark">C</span><span>Chunky</span></div>
    <Card.Root class="login-card">
      <div class="eyebrow">WORKER WORKSPACE</div>
      <h1>Your documents.<br />Ready for discovery.</h1>
      <p>Connect to your worker to turn documents into useful, searchable chunks.</p>
      <form onsubmit={connect}>
        <Label for="access-token">Worker access token</Label>
        <Input id="access-token" type="password" bind:value={token} autocomplete="off" placeholder="Enter your worker token" disabled={connecting} />
        <p class="field-note">Your token stays in memory for this session.</p>
        {#if error}<div class="notice danger" role="alert">{error}</div>{/if}
        <Button variant="ghost" class="primary full" disabled={connecting} type="submit">{connecting ? 'Connecting…' : 'Connect to worker'}<span aria-hidden="true">→</span></Button>
      </form>
      <div class="private-note"><span aria-hidden="true">◈</span> Processing stays on your configured worker.</div>
    </Card.Root>
    <p class="login-footer">One workspace for your documents, chunks, and collections.</p>
  </main>
{:else}
  <div class="workspace">
    <aside class="sidebar">
      <a href="#queue" class="brand" onclick={() => tab = 'queue'}><span class="brand-mark">C</span><span>Chunky<small>Worker workspace</small></span></a>
      <div class="nav-label">WORKSPACE</div>
      <nav aria-label="Workspace">
        <Button variant="ghost" class={tab === 'queue' ? 'active' : ''} onclick={() => tab = 'queue'}><span class="nav-icon" aria-hidden="true">▤</span>Processing queue<span class="count">{total}</span></Button>
        <Button variant="ghost" class={tab === 'collections' ? 'active' : ''} onclick={() => tab = 'collections'}><span class="nav-icon" aria-hidden="true">▦</span>Collections</Button>
        <Button variant="ghost" class={tab === 'settings' ? 'active' : ''} onclick={() => tab = 'settings'}><span class="nav-icon" aria-hidden="true">⚙</span>Job settings</Button>
      </nav>
      <div class="sidebar-bottom"><AppearancePicker id="workspace" /><div class="worker-state"><span class:unavailable={!!connectionError} class="status-dot"></span>{connectionError ? 'Connection interrupted' : 'Worker connected'}</div><Button variant="ghost" class="quiet signout" onclick={() => clearSession()}>Sign out <span aria-hidden="true">→</span></Button></div>
    </aside>

    <main class="main-content">
      <header class="page-header"><div><div class="eyebrow">YOUR WORKSPACE</div><h1>{tab === 'queue' ? 'Processing queue' : tab === 'collections' ? 'Collections' : 'Job settings'}</h1><p>{tab === 'queue' ? 'From documents to knowledge, one chunk at a time.' : tab === 'collections' ? 'Explore your documents and find the passages that matter.' : 'Choose how the worker processes your next documents.'}</p></div><span class="host-badge"><span class="status-dot"></span>Processing on worker</span></header>
      {#if error}<div class="notice danger" role="alert">{error}<Button variant="ghost" class="dismiss" aria-label="Dismiss error" onclick={() => error = ''}>×</Button></div>{/if}
      {#if connectionError}<div class="notice warning" role="alert">{connectionError} Your queue will refresh when the worker responds.</div>{/if}

      {#if tab === 'collections' && api && config}
        <Collections {api} {config} onAuthFailure={collectionFailure} />
      {:else if tab === 'settings'}
        <Card.Root class="card settings-card">
          <div class="section-heading"><div><h2>Processing preferences</h2><p>Applied to new uploads. Existing jobs keep their settings.</p></div><Badge variant="secondary" class="pill neutral">Session only</Badge></div>
          <div class="settings-grid">
            <div class="field wide"><Label for="output-mode">Output</Label><NativeSelect.Root id="output-mode" bind:value={options.mode}><option value="chunks">Chunks only</option><option value="vectors">Chunks and vectors</option><option value="ingest" disabled={!config?.qdrant_available}>{config?.qdrant_label ?? 'Worker Qdrant'}</option></NativeSelect.Root><p class="field-note">{options.mode === 'chunks' ? 'Convert and preview chunks without embedding.' : options.mode === 'vectors' ? 'Generate embeddings and download the results.' : 'The worker writes to its configured Qdrant target. Credentials stay server-side.'}</p>{#if !config?.qdrant_available}<p class="field-note">Qdrant ingest is unavailable until the worker target is configured.</p>{/if}</div>
            <div class="field"><Label for="conversion-model">Document model</Label><NativeSelect.Root id="conversion-model" bind:value={options.vlm}>{#each config?.vlm_models ?? ['standard'] as model}<option value={model}>{vlmName(model)}</option>{/each}</NativeSelect.Root></div>
            <div class="field"><Label for="accelerator">Processing device</Label><NativeSelect.Root id="accelerator" bind:value={options.accelerator}><option value="cuda">GPU · worker</option><option value="cpu">CPU · worker</option></NativeSelect.Root></div>
            <div class="field"><Label for="embedding-provider">Embedding provider</Label><NativeSelect.Root id="embedding-provider" bind:value={options.backend} disabled={options.mode === 'chunks'}><option value="ollama">Ollama</option><option value="openai">OpenAI-compatible</option></NativeSelect.Root></div>
            <div class="field"><Label for="embedding-model">Embedding model</Label><Input id="embedding-model" bind:value={options.model} list="embedding-models" disabled={options.mode === 'chunks'} /><datalist id="embedding-models">{#each models as model}<option value={model}></option>{/each}</datalist></div>
            {#if modelNotice}<p class="field-note wide">{modelNotice}</p>{/if}
            {#if options.mode === 'ingest'}<div class="field wide"><Label for="collection">Collection</Label><Input id="collection" bind:value={options.collection} placeholder="documents" /><Label class="checkbox"><input type="checkbox" bind:checked={options.hybrid} />Enable BM25 hybrid search</Label><p class="field-note">Use a new collection for a different model. Existing collections must have matching verified model settings.</p></div>{/if}
            <div class="field"><Label for="chunk-tokens">Maximum chunk tokens</Label><Input id="chunk-tokens" type="number" min="64" max="4096" step="1" bind:value={options.chunkTokens} /></div>
            <div class="field"><Label for="embedding-endpoint">Embedding endpoint <span class="optional">optional</span></Label><Input id="embedding-endpoint" bind:value={options.endpoint} placeholder="Use worker default" disabled={options.mode === 'chunks'} /><p class="field-note">A worker-side HTTP(S) endpoint. Required when changing providers.</p></div>
          </div>
          <div class="settings-footer"><p>Model choices do not alter existing collections.</p><Button variant="ghost" class="primary" onclick={() => tab = 'queue'}>Back to queue <span aria-hidden="true">→</span></Button></div>
        </Card.Root>
      {:else}
        <div class="queue-layout">
          <div class="queue-main">
            <section class="upload-card" class:dragging aria-label="Upload documents" ondragover={(event) => { event.preventDefault(); dragging = true; }} ondragleave={() => dragging = false} ondrop={(event) => { event.preventDefault(); dragging = false; chooseFiles(event.dataTransfer?.files ?? null); }}>
              <div class="upload-symbol" aria-hidden="true"><svg viewBox="0 0 32 32"><path d="M9 3h10l6 6v20H7V3h2m10 0v7h6M16 24V14m-4 4 4-4 4 4" /></svg></div>
              <h2>Bring your documents</h2><p>Drop PDF, Office, or text files here to get started.</p>
              <Label class="button secondary file-button">Choose files<input type="file" multiple aria-label="Choose documents" onchange={(event) => { chooseFiles(event.currentTarget.files); event.currentTarget.value = ''; }} disabled={uploading} /></Label>
              {#if files.length}<div class="selected-files">{#each files as file}<span>{file.name}<small>{fileSize(file.size)}</small></span>{/each}</div><Button variant="ghost" class="primary" onclick={upload} disabled={uploading}>{uploading ? 'Uploading…' : `Add ${files.length === 1 ? 'document' : `${files.length} documents`} to queue`}<span aria-hidden="true">→</span></Button>{/if}
            </section>

            <Card.Root class="card queue-card">
              <div class="section-heading"><div><h2>Documents <span class="heading-count">{total}</span></h2><p>Follow progress and inspect the finished chunks.</p></div><Button variant="ghost" class="quiet" onclick={() => void refresh()} disabled={refreshing} aria-label="Refresh queue">↻ <span>{refreshing ? 'Refreshing' : 'Refresh'}</span></Button></div>
              {#if !jobs.length}<div class="empty-state"><div class="empty-icon" aria-hidden="true">▤</div><h3>A little space for your next idea</h3><p>Add a document above. Its progress and results will appear here.</p></div>{:else}<div class="job-list">{#each jobs as job (job.id)}<div class={selected?.id === job.id ? 'job-row selected' : 'job-row'}><Button variant="ghost" class="job-select" onclick={() => void selectJob(job.id)}><span class="document-icon" aria-hidden="true">{job.status === 'succeeded' ? '✓' : '▤'}</span><span class="job-copy"><strong>{job.filename}</strong><span>{job.progress?.message ?? (job.status === 'queued' ? 'Waiting for the worker' : labels[job.status])}</span>{#if active(job)}<progress class="progress-track" aria-label={`${job.filename} progress`} value={percent(job)} max="100"></progress>{/if}</span><Badge variant="secondary" class="pill {job.status}">{labels[job.status]}</Badge></Button>{#if active(job)}<Button variant="ghost" class="cancel-job" aria-label={`Cancel ${job.filename}`} onclick={() => void cancelJob(job.id)}>×</Button>{/if}</div>{/each}</div>{/if}
              <div class="queue-footer"><span>{total ? `Showing ${offset + 1}–${pageEnd} of ${total} jobs` : 'Your queue is ready.'}</span><div><Button variant="ghost" class="quiet" aria-label="Previous jobs" disabled={!offset || refreshing} onclick={() => changePage(Math.max(0, offset - 50))}>←</Button><Button variant="ghost" class="quiet" aria-label="Next jobs" disabled={offset + 50 >= total || refreshing} onclick={() => changePage(offset + 50)}>→</Button></div></div>
            </Card.Root>

            {#if selected}<Card.Root class="card preview-card"><div class="section-heading"><div><div class="eyebrow">DOCUMENT PREVIEW</div><h2>{selected.filename}</h2><p>{selected.result ? `${chunks.length} chunks${selected.result.page_count ? ` · ${selected.result.page_count} pages` : ''}` : labels[selected.status]}</p></div>{#if selected.status === 'succeeded'}<Button variant="ghost" class="secondary" onclick={download}>Download JSON <span aria-hidden="true">↓</span></Button>{/if}</div>{#if selected.error}<div class="notice danger" role="alert">{selected.error}</div>{/if}{#if detailState === 'loading'}<p class="preview-empty" role="status">Loading document preview…</p>{:else if detailState === 'error'}<p class="preview-empty" role="status">Document preview could not be loaded. Refresh the queue to retry.</p>{:else if !chunks.length}<p class="preview-empty">{active(selected) ? 'Chunks will appear here when processing finishes.' : 'This job has no chunks to preview.'}</p>{:else}<div class="chunks">{#each visibleChunks as chunk, index}<article class="chunk"><div class="chunk-meta"><span>CHUNK {previewPage * chunkLimit + index + 1}</span>{#if chunk.page}<span>Page {chunk.page}{chunk.page_end && chunk.page_end !== chunk.page ? `–${chunk.page_end}` : ''}</span>{/if}{#if chunk.token_count}<span>{chunk.token_count} tokens</span>{/if}</div>{#if chunk.headings?.length}<h3>{chunk.headings.join(' › ')}</h3>{/if}<p>{chunk.text ?? chunk.embedding_text ?? ''}</p></article>{/each}</div><div class="queue-footer"><span>Showing {previewPage * chunkLimit + 1}–{Math.min((previewPage + 1) * chunkLimit, chunks.length)} of {chunks.length} chunks</span><div><Button variant="ghost" class="quiet" disabled={previewPage === 0} aria-label="Previous chunks" onclick={() => previewPage -= 1}>←</Button><Button variant="ghost" class="quiet" disabled={(previewPage + 1) * chunkLimit >= chunks.length} aria-label="Next chunks" onclick={() => previewPage += 1}>→</Button></div></div>{/if}</Card.Root>{/if}
            {#if selected && api && detailState === 'loaded'}
              {@const insightsClient = api}
              <JobInsights job={selected} loadVerification={(id, signal) => insightsClient.verification(id, signal)} onAuthFailure={(problem) => collectionFailure(problem, insightsClient)} />
            {/if}
          </div>
          <aside class="setup-column"><Card.Root class="card setup-card"><div class="eyebrow">NEXT UPLOAD</div><h2>Job setup</h2><dl><dt>Output</dt><dd>{options.mode === 'chunks' ? 'Chunks only' : options.mode === 'vectors' ? 'Chunks and vectors' : config?.qdrant_label}</dd><dt>Document model</dt><dd>{vlmName(options.vlm)}</dd><dt>Processing</dt><dd>{options.accelerator === 'cuda' ? 'GPU on worker' : 'CPU on worker'}</dd>{#if options.mode !== 'chunks'}<dt>Embedding model</dt><dd>{options.model || 'Choose a model'}</dd>{/if}{#if options.mode === 'ingest'}<dt>Collection</dt><dd>{options.collection}</dd>{/if}</dl><Button variant="ghost" class="secondary full" onclick={() => tab = 'settings'}>Edit job settings <span aria-hidden="true">→</span></Button></Card.Root><div class="workspace-note"><span aria-hidden="true">◈</span><p>Your browser talks only to this worker. Qdrant credentials stay on the server.</p></div></aside>
        </div>
      {/if}
    </main>
  </div>
{/if}
