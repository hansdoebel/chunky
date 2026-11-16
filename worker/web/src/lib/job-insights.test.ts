import { describe, expect, it } from 'vitest';
import { formatDuration, formatNumber, jobInsights, verificationInsights } from './job-insights';

describe('job insight measurements', () => {
  it('keeps measured zero separate from missing, invalid and negative values', () => {
    const parsed = jobInsights({ metrics: { host: 'fixture worker', wall_ms: 0, pages_per_s: 0, chunks_per_s: null, embeddings_per_s: Infinity, stages: [{ name: 'ocr', status: 'skipped', duration_ms: 0, pages: 0 }, { name: 'embedding', status: 'error', duration_ms: -2, chunks: 1.5 }], resources: { gpu_name: 'Fixture GPU', vram_used_mb: 0 } } });
    expect(parsed.metrics).toMatchObject({ wallMs: 0, pagesPerSecond: 0, chunksPerSecond: null, embeddingsPerSecond: null, vramUsedMb: 0, vramTotalMb: null });
    expect(parsed.metrics?.stages).toEqual([{ name: 'ocr', status: 'skipped', runtime: null, durationMs: 0, pages: 0, chunks: null, tokens: null }, { name: 'embedding', status: 'error', runtime: null, durationMs: null, pages: null, chunks: null, tokens: null }]);
    expect(formatDuration(0)).toBe('0 ms'); expect(formatDuration(1250)).toBe('1.25 s'); expect(formatDuration(null)).toBe('Not recorded');
    expect(formatNumber(0, ' /s')).toBe('0 /s'); expect(formatNumber(NaN)).toBe('Not recorded');
  });
  it('handles partial, canceled and malformed job results safely', () => {
    for (const value of [null, undefined, [], { metrics: [] }, { metrics: null }]) expect(jobInsights(value).metrics).toBeNull();
    expect(jobInsights({ metrics: { stages: [null, false, { name: {} }, { name: 'convert_layout', status: 'unexpected' }] }, verification_status: 'red' })).toMatchObject({ verificationStatus: 'red', metrics: { stages: [{ name: 'convert_layout', status: 'unknown' }] } });
  });
});

describe('verification insight reports', () => {
  it('preserves page coverage zero and skipped checks without implying success', () => {
    const parsed = verificationInsights({ status: 'yellow', text: { status: 'yellow', note: 'Fixture only' }, pages: [{ page: 1, status: 'red', coverage: 0, flags: ['Missing text'] }, { page: 2, coverage: NaN, flags: [false, 'No measurement'] }], store: { status: 'skipped', checked: 0 }, vector_spot_check: { status: 'skipped' }, retrieval: { status: 'skipped' } });
    expect(parsed.pages).toEqual([{ page: 1, status: 'red', coverage: 0, flags: ['Missing text'] }, { page: 2, status: 'unknown', coverage: null, flags: ['No measurement'] }]);
    expect(parsed.checks.find((item) => item.name === 'Stored chunks')).toMatchObject({ status: 'skipped', detail: '0 chunks checked' });
    expect(parsed.checks.find((item) => item.name === 'Vector spot check')?.status).toBe('skipped');
  });
  it('retains the check details needed for explicit paginated rendering', () => {
    const parsed = verificationInsights({ status: 'red', store: { status: 'red', issues: [{ chunk_id: 'c1', detail: '<script>fixture</script>' }] }, attributions: [{ chunk_id: 'c1', matched: false, page: 1, page_end: 2, suggested_page: 3, similarity: .4 }], vector_spot_check: { status: 'green', samples: [{ chunk_id: 'c1', status: 'green', cosine: 0 }] }, retrieval: { status: 'red', queries: [{ expected_chunk_id: 'c1', expected_page: 1, passed: false, query: 'Fixture question' }] }, spot_checks: [{ chunk_id: 'c1', page: 1, preview: 'Fixture preview' }] });
    expect(parsed.findings).toHaveLength(5);
    expect(parsed.findings[0].detail).toBe('<script>fixture</script>');
    expect(parsed.findings[1]).toMatchObject({ detail: 'Claimed page: 1–2 · suggested page: 3 · similarity: 0.4', page: 3 });
    expect(parsed.findings[2].detail).toBe('Cosine similarity: 0.0000');
    expect(parsed.checks.find((item) => item.name === 'Page attribution')?.status).toBe('red');
  });
  it('rejects malformed reports instead of showing a false green status', () => {
    for (const value of [null, [], {}, { status: [] }, { status: 'ok' }, { status: 'error' }]) expect(() => verificationInsights(value)).toThrow('invalid verification report');
  });
});
