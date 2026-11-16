export type InsightStatus = 'ok' | 'error' | 'skipped' | 'green' | 'yellow' | 'red' | 'unknown';
export type StageInsight = { name: string; status: InsightStatus; runtime: string | null; durationMs: number | null; pages: number | null; chunks: number | null; tokens: number | null };
export type MetricsInsight = { host: string | null; wallMs: number | null; pagesPerSecond: number | null; chunksPerSecond: number | null; embeddingsPerSecond: number | null; stages: StageInsight[]; gpuName: string | null; vramUsedMb: number | null; vramTotalMb: number | null };
export type VerificationPage = { page: number | null; status: InsightStatus; coverage: number | null; flags: string[] };
export type VerificationCheck = { name: string; status: InsightStatus; detail: string | null };
export type VerificationFinding = { name: string; status: InsightStatus; detail: string; page: number | null };
export type VerificationInsight = { status: InsightStatus; filename: string | null; generatedAt: string | null; pages: VerificationPage[]; checks: VerificationCheck[]; findings: VerificationFinding[] };

function object(value: unknown): Record<string, unknown> { return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}; }
function rows(value: unknown): Record<string, unknown>[] { return Array.isArray(value) ? value.filter((item) => item !== null && typeof item === 'object' && !Array.isArray(item)) as Record<string, unknown>[] : []; }
function text(value: unknown): string | null { return typeof value === 'string' && value.trim() ? value : null; }
function number(value: unknown): number | null { return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null; }
function count(value: unknown): number | null { const result = number(value); return result !== null && Number.isInteger(result) ? result : null; }
function page(value: unknown): number | null { const result = count(value); return result !== null && result > 0 ? result : null; }
function status(value: unknown): InsightStatus { return typeof value === 'string' && ['ok', 'error', 'skipped', 'green', 'yellow', 'red'].includes(value) ? value as InsightStatus : 'unknown'; }
function strings(value: unknown): string[] { return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []; }

export function jobInsights(result: unknown): { metrics: MetricsInsight | null; verificationStatus: InsightStatus } {
  const source = object(result);
  const raw = object(source.metrics);
  const resources = object(raw.resources);
  return {
    verificationStatus: status(source.verification_status),
    metrics: Object.keys(raw).length ? {
      host: text(raw.host), wallMs: number(raw.wall_ms), pagesPerSecond: number(raw.pages_per_s), chunksPerSecond: number(raw.chunks_per_s), embeddingsPerSecond: number(raw.embeddings_per_s),
      stages: rows(raw.stages).flatMap((stage) => text(stage.name) ? [{ name: stage.name as string, status: status(stage.status), runtime: text(stage.runtime), durationMs: number(stage.duration_ms), pages: count(stage.pages), chunks: count(stage.chunks), tokens: count(stage.tokens) }] : []),
      gpuName: text(resources.gpu_name), vramUsedMb: number(resources.vram_used_mb), vramTotalMb: number(resources.vram_total_mb),
    } : null,
  };
}

export function verificationInsights(value: unknown): VerificationInsight {
  const raw = object(value);
  const reportStatus = status(raw.status);
  if (!Object.keys(raw).length || !['green', 'yellow', 'red', 'skipped'].includes(reportStatus)) throw new Error('The worker returned an invalid verification report.');
  const textCheck = object(raw.text);
  const store = object(raw.store);
  const vectors = object(raw.vector_spot_check);
  const retrieval = object(raw.retrieval);
  const attributions = rows(raw.attributions);
  const attributionStatus = !Array.isArray(raw.attributions) ? 'unknown' : !attributions.length ? 'skipped' : attributions.some((row) => row.matched === false) ? 'red' : attributions.every((row) => row.matched === true) ? 'green' : 'unknown';
  const checks: VerificationCheck[] = [
    { name: 'Text coverage', status: status(textCheck.status), detail: text(textCheck.note) },
    { name: 'Page attribution', status: attributionStatus, detail: attributions.length ? `${attributions.length} chunk attributions` : null },
    { name: 'Stored chunks', status: status(store.status), detail: count(store.checked) !== null ? `${store.checked} chunks checked` : null },
    { name: 'Vector spot check', status: status(vectors.status), detail: text(vectors.error) },
    { name: 'Retrieval self-test', status: status(retrieval.status), detail: text(retrieval.error) },
  ];
  const findings: VerificationFinding[] = [];
  for (const item of rows(store.issues)) findings.push({ name: `Stored chunk ${text(item.chunk_id) ?? 'unknown'}`, status: 'red', detail: text(item.detail) ?? text(item.kind) ?? 'Store mismatch', page: page(item.page) });
  for (const item of attributions) findings.push({ name: `Attribution ${text(item.chunk_id) ?? 'unknown'}`, status: item.matched === true ? 'green' : item.matched === false ? 'red' : 'unknown', detail: `Claimed page: ${page(item.page) ?? 'Not recorded'}${page(item.page_end) !== null && item.page_end !== item.page ? `–${item.page_end}` : ''} · suggested page: ${page(item.suggested_page) ?? 'Not recorded'} · similarity: ${formatNumber(item.similarity)}`, page: page(item.suggested_page) ?? page(item.page) });
  for (const item of rows(vectors.samples)) findings.push({ name: `Vector ${text(item.chunk_id) ?? 'unknown'}`, status: status(item.status), detail: `Cosine similarity: ${typeof item.cosine === 'number' && Number.isFinite(item.cosine) ? item.cosine.toFixed(4) : 'Not recorded'}`, page: null });
  for (const item of rows(retrieval.queries)) {
    const returnedChunk = text(item.top_chunk_id) ?? (item.top_chunk_id === null || item.top_chunk_id === '' ? 'No result' : 'Not recorded');
    const returnedPage = page(item.top_page) ?? (item.top_page === null ? 'No result' : 'Not recorded');
    findings.push({ name: `Retrieval ${text(item.expected_chunk_id) ?? 'unknown'}`, status: item.passed === true ? 'green' : item.passed === false ? 'red' : 'unknown', detail: `${text(item.query) ?? 'No query recorded'}\nExpected chunk: ${text(item.expected_chunk_id) ?? 'Not recorded'} · page: ${page(item.expected_page) ?? 'Not recorded'}\nReturned chunk: ${returnedChunk} · page: ${returnedPage}`, page: page(item.expected_page) });
  }
  for (const item of rows(raw.spot_checks)) findings.push({ name: `Spot check ${text(item.chunk_id) ?? 'unknown'}`, status: 'unknown', detail: text(item.preview) ?? 'No preview recorded', page: page(item.page) });
  return { status: reportStatus, filename: text(raw.filename), generatedAt: text(raw.generated_at), checks, findings,
    pages: rows(raw.pages).map((item) => ({ page: page(item.page), status: status(item.status), coverage: typeof item.coverage === 'number' && Number.isFinite(item.coverage) && item.coverage >= 0 && item.coverage <= 1 ? item.coverage : null, flags: strings(item.flags) })),
  };
}

export function formatNumber(value: unknown, unit = ''): string { const parsed = number(value); return parsed === null ? 'Not recorded' : `${parsed.toLocaleString('en-US', { maximumFractionDigits: 2 })}${unit}`; }
export function formatDuration(value: unknown): string { const parsed = number(value); return parsed === null ? 'Not recorded' : parsed >= 1000 ? `${(parsed / 1000).toLocaleString('en-US', { maximumFractionDigits: 2 })} s` : `${parsed.toLocaleString('en-US', { maximumFractionDigits: 2 })} ms`; }
