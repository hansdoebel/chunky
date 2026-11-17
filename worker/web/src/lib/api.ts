import { buildSearchFilters, type SearchFilterDraft } from './search-filters';

export type JobStatus = 'queued' | 'running' | 'succeeded' | 'failed' | 'canceled';
export type JobEvent = { type?: string; status?: JobStatus; stage_status?: 'ok' | 'error' | 'skipped'; message?: string; percent?: number };
export type Chunk = { text?: string; embedding_text?: string; page?: number; page_end?: number; headings?: string[]; token_count?: number; content_type?: string };
export type Job = {
  id: string;
  filename: string;
  status: JobStatus;
  progress?: JobEvent | null;
  error?: string | null;
  error_type?: string | null;
  result?: { chunks?: Chunk[]; page_count?: number; embedding_dim?: number; embeddings?: number[][] | null; metrics?: unknown; verification_status?: string | null } | null;
};
export type WorkerConfig = {
  embedding_backend: 'ollama' | 'openai';
  embedding_model: string;
  qdrant_available: boolean;
  qdrant_read_available?: boolean;
  qdrant_label: string;
  vlm_models: string[];
};
export type JobPage = { jobs: Job[]; total: number; limit: number; offset: number };
export type JobOptions = {
  mode: 'chunks' | 'vectors' | 'ingest';
  backend: 'ollama' | 'openai';
  model: string;
  endpoint: string;
  vlm: string;
  accelerator: 'cuda' | 'cpu';
  collection: string;
  hybrid: boolean;
  chunkTokens: number;
};

export type CollectionEmbedding = { backend: 'ollama' | 'openai'; model: string; dimensions: number; distance: string; hybrid: boolean };
export type CollectionPoint = { id: string | number; payload: Record<string, unknown> };
export type CollectionPage = {
  collection: string;
  points: CollectionPoint[];
  limit: number;
  next_offset: string | null;
  points_count: number | null;
  semantic_search_available: boolean;
  semantic_search_reason: string | null;
  embedding: CollectionEmbedding | null;
};
export type SearchOptions = { query: string; backend: 'ollama' | 'openai'; model: string; endpoint: string; mode: 'dense' | 'hybrid'; filters?: SearchFilterDraft };
export type SearchPage = {
  results: (CollectionPoint & { score: number })[];
  limit: number;
  offset: number;
  next_offset: number | null;
  embedding_model: string;
  embedding_backend: string;
  embedding_dim: number;
};

function validateEmbeddingEndpoint(endpoint: string) {
  let url: URL;
  try { url = new URL(endpoint.trim()); } catch { throw new Error('Enter a valid HTTP(S) embedding endpoint.'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
    throw new Error('Use an HTTP(S) embedding endpoint without credentials or query parameters.');
  }
}

export function buildSearchRequest(collection: string, options: SearchOptions, config: WorkerConfig, offset = 0): Record<string, unknown> {
  if (!collection.trim() || !options.query.trim()) throw new Error('Choose a collection and enter a search query.');
  if (!options.model.trim()) throw new Error('Choose the collection’s embedding model.');
  if (options.backend !== config.embedding_backend && !options.endpoint.trim()) throw new Error('Enter the worker-side endpoint for this embedding provider.');
  if (options.endpoint.trim()) validateEmbeddingEndpoint(options.endpoint);
  if (!Number.isInteger(offset) || offset < 0) throw new Error('Invalid search page.');
  const filters = options.filters ? buildSearchFilters(options.filters) : [];
  return {
    query: options.query.trim(), collection, use_worker_qdrant: true,
    mode: options.mode, embedding_backend: options.backend, embedding_model: options.model.trim(),
    ...(options.endpoint.trim() ? { embedding_url: options.endpoint.trim() } : {}),
    ...(filters.length ? { filters } : {}),
    limit: 10, offset,
  };
}

export class APIError extends Error {
  constructor(message: string, public status: number) { super(message); }
}

export function buildJobSettings(options: JobOptions, config: WorkerConfig): Record<string, unknown> {
  const full = options.mode !== 'chunks';
  if (full && !options.model.trim()) throw new Error('Choose an embedding model.');
  if (full && options.backend !== config.embedding_backend && !options.endpoint.trim()) {
    throw new Error('Enter the worker-side endpoint for this embedding provider.');
  }
  if (full && options.endpoint.trim()) validateEmbeddingEndpoint(options.endpoint);
  if (!Number.isInteger(options.chunkTokens) || options.chunkTokens < 64 || options.chunkTokens > 4096) {
    throw new Error('Chunk size must be between 64 and 4096 tokens.');
  }
  if (options.mode === 'ingest' && (!config.qdrant_available || !options.collection.trim())) {
    throw new Error('Choose a collection on the configured worker Qdrant target.');
  }
  const body: Record<string, unknown> = {
    mode: full ? 'chunk_and_embed' : 'chunk_only',
    ingest_target: options.mode === 'ingest' ? 'qdrant_cloud' : options.mode === 'vectors' ? 'return_vectors' : 'none',
    chunk: true,
    chunk_max_tokens: options.chunkTokens,
    accelerator: options.accelerator,
    format: 'json',
  };
  if (full) {
    body.embedding_backend = options.backend;
    body.embedding_model = options.model.trim();
    if (options.endpoint.trim()) body.embedding_url = options.endpoint.trim();
  }
  if (options.vlm !== 'standard') body.vlm_model = options.vlm;
  if (options.mode === 'ingest') {
    body.use_worker_qdrant = true;
    body.qdrant_collection = options.collection.trim();
    body.qdrant_hybrid = options.hybrid;
  }
  return body;
}

export async function* decodeEvents(body: ReadableStream<Uint8Array>): AsyncGenerator<JobEvent> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  let data: string[] = [];
  let dataSize = 0;
  function append(line: string) {
    dataSize += line.length;
    if (dataSize > 1_048_576) throw new Error('The worker progress event is too large. Refresh the queue.');
    data.push(line);
  }
  function event(): JobEvent | null {
    if (!data.length) return null;
    let value: unknown;
    try { value = JSON.parse(data.join('\n')); } catch { throw new Error('The worker sent an invalid progress event. Refresh the queue.'); }
    data = [];
    dataSize = 0;
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('The worker sent an invalid progress event.');
    const event = value as Record<string, unknown>;
    if (event.type === 'stage' && event.status !== undefined) {
      if (!['ok', 'error', 'skipped'].includes(event.status as string)) throw new Error('The worker sent an invalid stage event.');
      event.stage_status = event.status;
      delete event.status;
    }
    if ((event.status !== undefined && !['queued', 'running', 'succeeded', 'failed', 'canceled'].includes(event.status as string)) || (event.message !== undefined && typeof event.message !== 'string') || (event.percent !== undefined && (typeof event.percent !== 'number' || !Number.isFinite(event.percent)))) throw new Error('The worker sent an invalid progress event.');
    return event as JobEvent;
  }
  try {
    while (true) {
      const { value, done } = await reader.read();
      buffer += done ? decoder.decode() : decoder.decode(value, { stream: true });
      if (buffer.length > 1_048_576) throw new Error('The worker progress event is too large. Refresh the queue.');
      let end: number;
      while ((end = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, end).replace(/\r$/, '');
        buffer = buffer.slice(end + 1);
        if (!line) {
          const parsed = event();
          if (parsed) yield parsed;
        } else if (line.startsWith('data:')) append(line.slice(5).replace(/^ /, ''));
      }
      if (done) {
        if (buffer.startsWith('data:')) append(buffer.slice(5).trim());
        const parsed = event();
        if (parsed) yield parsed;
        break;
      }
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

export class WorkerAPI {
  private controller = new AbortController();
  constructor(private token: string, private fetcher: typeof fetch = globalThis.fetch.bind(globalThis)) {}
  dispose() { this.controller.abort(); this.token = ''; }
  private async request(path: string, init: RequestInit = {}): Promise<Response> {
    const headers = new Headers(init.headers);
    if (this.token) headers.set('Authorization', `Bearer ${this.token}`);
    const signal = init.signal ? AbortSignal.any([this.controller.signal, init.signal]) : this.controller.signal;
    const response = await this.fetcher(`/v1/${path}`, { ...init, headers, signal, cache: 'no-store', credentials: 'omit' });
    if (!response.ok) {
      let message = `Worker request failed (${response.status}).`;
      try {
        const error = await response.json();
        if (typeof error.detail === 'string') message = error.detail;
      } catch {}
      if (response.status === 401 || response.status === 403) message = 'The worker rejected this token. Connect again with the worker access token.';
      throw new APIError(message, response.status);
    }
    return response;
  }
  async collections(signal?: AbortSignal): Promise<{ collections: { name: string }[]; target_label: string }> {
    return (await this.request('collections', { signal })).json();
  }
  async points(collection: string, offset?: string, signal?: AbortSignal): Promise<CollectionPage> {
    const query = new URLSearchParams({ limit: '50' });
    if (offset !== undefined) query.set('offset', offset);
    return (await this.request(`collections/${encodeURIComponent(collection)}/points?${query}`, { signal })).json();
  }
  async search(body: Record<string, unknown>, signal?: AbortSignal): Promise<SearchPage> {
    return (await this.request('search', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal })).json();
  }
  async config(): Promise<WorkerConfig> { return (await this.request('ui/config')).json(); }
  async modelCatalog(signal?: AbortSignal): Promise<unknown> { return (await this.request('models', { signal })).json(); }
  async models(): Promise<{ embeddings?: { name: string }[] }> { return (await this.request('models')).json(); }
  async jobs(offset = 0): Promise<JobPage> { return (await this.request(`jobs?limit=50&offset=${offset}`)).json(); }
  async job(id: string, vectors = false): Promise<Job> {
    return (await this.request(`jobs/${encodeURIComponent(id)}?include_embeddings=${vectors}`)).json();
  }
  async upload(file: File, settings: Record<string, unknown>): Promise<{ id: string }> {
    const body = new FormData();
    body.append('file', file);
    body.append('settings', JSON.stringify(settings));
    return (await this.request('jobs', { method: 'POST', body })).json();
  }
  async verification(id: string, signal?: AbortSignal): Promise<unknown> {
    return (await this.request(`jobs/${encodeURIComponent(id)}/verification`, { signal })).json();
  }
  async cancel(id: string): Promise<void> { await this.request(`jobs/${encodeURIComponent(id)}/cancel`, { method: 'POST' }); }
  async events(id: string, onEvent: (event: JobEvent) => void, signal: AbortSignal): Promise<void> {
    const response = await this.request(`jobs/${encodeURIComponent(id)}/events`, { signal });
    if (!response.body) throw new Error('The worker progress stream is unavailable.');
    for await (const event of decodeEvents(response.body)) onEvent(event);
  }
}
