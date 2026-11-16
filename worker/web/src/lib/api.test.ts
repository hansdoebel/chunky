import { describe, expect, it, vi } from 'vitest';
import { APIError, WorkerAPI, buildJobSettings, decodeEvents, type JobOptions, type WorkerConfig } from './api';
const config: WorkerConfig = { embedding_backend: 'ollama', embedding_model: 'embed', qdrant_available: true, qdrant_label: 'Worker Qdrant', vlm_models: ['standard'] };
const options: JobOptions = { mode: 'chunks', backend: 'ollama', model: 'embed', endpoint: '', vlm: 'standard', accelerator: 'cpu', collection: 'docs', hybrid: false, chunkTokens: 512 };
function stream(parts: Uint8Array[]) { return new ReadableStream<Uint8Array>({ start(controller) { parts.forEach((part) => controller.enqueue(part)); controller.close(); } }); }
async function collect<T>(source: AsyncIterable<T>) { const result: T[] = []; for await (const value of source) result.push(value); return result; }
async function events(text: string) { return collect(decodeEvents(stream([new TextEncoder().encode(text)]))); }
describe('worker settings', () => {
  it('keeps chunk only uploads independent of embedding and collection credentials', () => {
    expect(buildJobSettings(options, config)).toMatchObject({ mode: 'chunk_only', ingest_target: 'none' });
    expect(buildJobSettings(options, config)).not.toHaveProperty('embedding_model');
  });
  it('uses only the server configured Qdrant target with explicit identity', () => {
    const settings = buildJobSettings({ ...options, mode: 'ingest', hybrid: true }, config);
    expect(settings).toMatchObject({ use_worker_qdrant: true, qdrant_collection: 'docs', embedding_model: 'embed', qdrant_hybrid: true });
    expect(settings).not.toHaveProperty('qdrant_url');
    expect(settings).not.toHaveProperty('qdrant_api_key');
    expect(() => buildJobSettings({ ...options, mode: 'ingest' }, { ...config, qdrant_available: false })).toThrow('configured worker');
  });
  it('requires an explicit safe endpoint when changing embedding provider', () => {
    expect(() => buildJobSettings({ ...options, mode: 'vectors', backend: 'openai' }, config)).toThrow('endpoint');
    expect(() => buildJobSettings({ ...options, mode: 'vectors', endpoint: 'https://secret:password@example.com' }, config)).toThrow('credentials');
    expect(() => buildJobSettings({ ...options, chunkTokens: NaN }, config)).toThrow('Chunk size');
  });
});
describe('SSE parser', () => {
  it('handles split UTF8, CRLF, multiline JSON, comments and final EOF', async () => {
    const bytes = new TextEncoder().encode(': keepalive\r\ndata: {"message":"文書",\r\ndata: "percent":42}\r\n\r\ndata: {"status":"succeeded"}');
    const result = await collect(decodeEvents(stream(Array.from(bytes, (byte) => new Uint8Array([byte])))));
    expect(result).toEqual([{ message: '文書', percent: 42 }, { status: 'succeeded' }]);
  });
  it('rejects malformed JSON, unsafe types and accumulated oversized data', async () => {
    await expect(events('data: bad\n\n')).rejects.toThrow('invalid progress');
    await expect(events('data: {"message":{}}\n\n')).rejects.toThrow('invalid progress');
    await expect(events('data: {"status":"toString"}\n\n')).rejects.toThrow('invalid progress');
    const part = new TextEncoder().encode(`data: ${'a'.repeat(600000)}\n`);
    await expect(collect(decodeEvents(stream([part, part])))).rejects.toThrow('too large');
  });
  it('cancels its reader when consumption stops', async () => {
    const cancel = vi.fn();
    const source = new ReadableStream<Uint8Array>({ start(c) { c.enqueue(new TextEncoder().encode('data: {}\n\n')); }, cancel });
    for await (const _event of decodeEvents(source)) break;
    expect(cancel).toHaveBeenCalledOnce();
  });
});
describe('authenticated API', () => {
  it('uses headers, never URLs, uploads multipart and excludes vectors from previews', async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(new Response('{}'));
    const api = new WorkerAPI('private-token', fetcher);
    await api.upload(new File(['test'], 'fixture.pdf'), { mode: 'chunk_only' });
    const [url, init] = fetcher.mock.calls[0];
    expect(url).toBe('/v1/jobs');
    expect(new Headers(init?.headers).get('Authorization')).toBe('Bearer private-token');
    expect((init?.body as FormData).get('settings')).toBe('{"mode":"chunk_only"}');
    fetcher.mockResolvedValueOnce(new Response('{}'));
    await api.job('a/b');
    expect(fetcher.mock.lastCall?.[0]).toBe('/v1/jobs/a%2Fb?include_embeddings=false');
  });
  it('reports auth rejection and aborts every request on logout', async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(new Response('{}', { status: 401 }));
    const api = new WorkerAPI('token', fetcher);
    await expect(api.config()).rejects.toBeInstanceOf(APIError);
    const signal = fetcher.mock.calls[0][1]?.signal;
    api.dispose();
    expect(signal?.aborted).toBe(true);
  });
});
