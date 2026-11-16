import { expect, test, type Page } from '@playwright/test';
import { PNG } from 'pngjs';
import { readFile } from 'node:fs/promises';
const config = { embedding_backend: 'ollama', embedding_model: 'nomic-embed-text', qdrant_available: true, qdrant_label: 'Worker Qdrant', vlm_models: ['standard', 'granite-docling-transformers', 'smoldocling-transformers'] };
const fixture = { id: 'fixture-complete', filename: 'fixture-research.pdf', status: 'succeeded', progress: { message: 'Fixture processing complete', percent: 100 }, result: { page_count: 3, chunks: [{ page: 1, headings: ['Fixture overview'], text: 'Fixture text for browser validation. <script>window.chunkXSS=true</script>', token_count: 28 }, { page: 2, headings: ['Findings'], text: 'These are mocked test chunks, not actual PDF conversion results.', token_count: 15 }] } };
async function mockWorker(page: Page, options: { qdrant?: boolean; reject?: boolean; late?: boolean } = {}) {
  let jobs: Record<string, unknown>[] = [fixture];
  const uploads: string[] = [];
  const requests: string[] = [];
  await page.route('**/v1/**', async (route) => {
    const request = route.request();
    requests.push(request.url());
    expect(request.headers().authorization).toBe('Bearer fixture-token');
    const url = new URL(request.url());
    const json = (body: unknown, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
    if (options.reject) return json({ detail: 'Invalid token' }, 401);
    if (url.pathname === '/v1/ui/config') return json({ ...config, qdrant_available: options.qdrant ?? true });
    if (url.pathname === '/v1/models') return json({ embeddings: [{ name: 'nomic-embed-text' }, { name: 'custom-model' }] });
    if (url.pathname === '/v1/jobs' && request.method() === 'POST') {
      uploads.push(request.postDataBuffer()?.toString() ?? '');
      jobs = [{ id: 'fixture-active', filename: 'fixture-upload.txt', status: 'running', progress: { message: 'Preparing fixture document', percent: 10 } }, ...jobs];
      return json({ id: 'fixture-active', status: 'queued' }, 202);
    }
    if (url.pathname === '/v1/jobs') {
      expect(url.searchParams.get('limit')).toBe('50');
      expect(url.searchParams.get('offset')).toBe('0');
      if (options.late) await new Promise((resolve) => setTimeout(resolve, 600));
      return json({ jobs: jobs.map(({ result: _result, ...job }) => job), total: jobs.length, limit: 50, offset: 0 });
    }
    if (url.pathname.endsWith('/cancel')) { jobs = jobs.map((job) => job.id === 'fixture-active' ? { ...job, status: 'canceled', progress: { message: 'Canceled fixture', percent: 42 } } : job); return json({ status: 'canceled' }); }
    if (url.pathname.endsWith('/events')) return route.fulfill({ contentType: 'text/event-stream', body: 'data: {"type":"progress","status":"running","message":"Reading fixture pages","percent":42}\n\n' });
    if (url.pathname === '/v1/jobs/fixture-complete') {
      expect(url.searchParams.get('include_embeddings')).toBe('false');
      return json(fixture);
    }
    return json(jobs.find((job) => job.id === 'fixture-active'));
  });
  return { uploads, requests };
}
async function login(page: Page) { await page.goto('/'); await page.getByLabel('Worker access token').fill('fixture-token'); await page.getByRole('button', { name: 'Connect to worker' }).click(); await expect(page.getByRole('heading', { name: 'Processing queue' })).toBeVisible(); }
async function screenshot(page: Page, name: string) {
  await expect(page.getByRole('heading', { name: name === 'settings' ? 'Job settings' : 'Processing queue', exact: true })).toBeVisible();
  const path = `/tmp/chunky-web-${name}.png`;
  await page.screenshot({ path, fullPage: true, animations: 'disabled' });
  const png = PNG.sync.read(await readFile(path));
  let dark = 0; let light = 0; let opaque = 0;
  for (let i = 0; i < png.data.length; i += 4) { if (png.data[i + 3] > 200) opaque++; const luma = (png.data[i] + png.data[i + 1] + png.data[i + 2]) / 3; if (luma < 150) dark++; if (luma > 220) light++; }
  expect(opaque).toBeGreaterThan(png.width * png.height * .9);
  expect(dark).toBeGreaterThan(1000);
  expect(light).toBeGreaterThan(1000);
}
test('authenticated production workspace, escaped chunk preview and responsive screenshots', async ({ page }) => {
  const mocked = await mockWorker(page);
  await login(page);
  await expect(page.getByText('fixture-research.pdf', { exact: true })).toBeVisible();
  await screenshot(page, 'queue');
  await page.getByRole('button', { name: /^fixture-research.pdf/ }).click();
  await expect(page.getByText('Fixture overview', { exact: true })).toBeVisible();
  await expect(page.getByText('Fixture text for browser validation.', { exact: false })).toBeVisible();
  expect(await page.evaluate(() => (window as Window & { chunkXSS?: boolean }).chunkXSS)).toBeUndefined();
  await screenshot(page, 'chunks');
  await page.getByRole('button', { name: 'Job settings', exact: false }).first().click();
  await page.getByLabel('Output', { exact: true }).selectOption('ingest');
  await expect(page.getByLabel('Collection', { exact: true })).toBeVisible();
  await page.getByLabel('Collection', { exact: true }).fill('fixture-documents');
  await screenshot(page, 'settings');
  await page.getByRole('button', { name: 'Back to queue' }).click();
  await page.setViewportSize({ width: 390, height: 844 });
  await screenshot(page, 'mobile');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  expect(mocked.requests.every((url) => !url.includes('fixture-token'))).toBe(true);
});
test('multipart upload uses chosen model and server Qdrant target, streams progress and cancels', async ({ page }) => {
  const mocked = await mockWorker(page);
  await login(page);
  await page.getByRole('button', { name: 'Edit job settings' }).click();
  await page.getByLabel('Output', { exact: true }).selectOption('ingest');
  await page.getByLabel('Embedding model', { exact: true }).fill('custom-model');
  await page.getByLabel('Collection', { exact: true }).fill('fixture-documents');
  await page.getByLabel('Enable BM25 hybrid search').check();
  await page.getByLabel('Processing device').selectOption('cpu');
  await page.getByLabel('Document model', { exact: true }).selectOption('granite-docling-transformers');
  await page.getByRole('button', { name: 'Back to queue' }).click();
  await page.getByLabel('Choose documents').setInputFiles({ name: 'fixture-upload.txt', mimeType: 'text/plain', buffer: Buffer.from('Fixture content') });
  await page.getByRole('button', { name: 'Add document to queue' }).click();
  await expect(page.getByText('Reading fixture pages').first()).toBeVisible();
  await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
  expect(mocked.uploads).toHaveLength(1);
  const payload = mocked.uploads[0];
  expect(payload).toContain('"use_worker_qdrant":true'); expect(payload).toContain('"embedding_model":"custom-model"'); expect(payload).toContain('"qdrant_collection":"fixture-documents"'); expect(payload).toContain('"vlm_model":"granite-docling-transformers"');
  expect(payload).not.toContain('qdrant_api_key'); expect(payload).not.toContain('qdrant_url');
  await page.getByRole('button', { name: 'Cancel fixture-upload.txt' }).click();
  await expect(page.getByText('Canceled', { exact: true }).first()).toBeVisible();
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page.getByLabel('Worker access token')).toHaveValue('');
  expect(await page.evaluate(() => [localStorage.length, sessionStorage.length])).toEqual([0, 0]);
  await expect(page.getByText('fixture-upload.txt', { exact: true })).toHaveCount(0);
});
test('blank and rejected tokens do not expose job data', async ({ page }) => {
  await mockWorker(page, { reject: true });
  await page.goto('/');
  await page.getByRole('button', { name: 'Connect to worker' }).click();
  await expect(page.getByRole('alert')).toContainText('Configure a worker access token');
  await page.getByLabel('Worker access token').fill('fixture-token');
  await page.getByRole('button', { name: 'Connect to worker' }).click();
  await expect(page.getByRole('alert')).toContainText('rejected this token');
  await expect(page.getByLabel('Worker access token')).toHaveValue('');
  await expect(page.getByText('fixture-research.pdf')).toHaveCount(0);
});
test('logout prevents delayed responses from repopulating the workspace', async ({ page }) => {
  await mockWorker(page, { late: true, qdrant: false });
  await login(page);
  await page.getByRole('button', { name: 'Sign out' }).click();
  await page.waitForTimeout(750);
  await expect(page.getByText('fixture-research.pdf')).toHaveCount(0);
  await expect(page.getByLabel('Worker access token')).toHaveValue('');
});

test('queue polling loads completed detail when progress stream misses completion', async ({ page }) => {
  let complete = false;
  await mockWorker(page);
  await page.route('**/v1/jobs?*', (route) => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ jobs: [{ ...fixture, result: undefined, status: complete ? 'succeeded' : 'running' }], total: 1, limit: 50, offset: 0 }) }));
  await page.route('**/v1/jobs/fixture-complete?*', (route) => route.fulfill({ contentType: 'application/json', body: JSON.stringify(complete ? fixture : { ...fixture, status: 'running', result: null }) }));
  await login(page);
  await page.getByRole('button', { name: /^fixture-research.pdf/ }).click();
  await expect(page.getByText('Chunks will appear here when processing finishes.')).toBeVisible();
  complete = true;
  await page.getByRole('button', { name: 'Refresh queue' }).click();
  await expect(page.getByText('Fixture overview', { exact: true })).toBeVisible();
});
test('same file can be selected again after upload', async ({ page }) => {
  const mocked = await mockWorker(page);
  await login(page);
  const file = { name: 'fixture-upload.txt', mimeType: 'text/plain', buffer: Buffer.from('Fixture content') };
  await page.getByLabel('Choose documents').setInputFiles(file);
  await page.getByRole('button', { name: 'Add document to queue' }).click();
  await expect.poll(() => mocked.uploads.length).toBe(1);
  await expect(page.getByLabel('Choose documents')).toBeEnabled();
  await expect(page.getByLabel('Choose documents')).toHaveValue('');
  await page.getByLabel('Choose documents').setInputFiles(file);
  await expect(page.getByRole('button', { name: 'Add document to queue' })).toBeVisible();
});
