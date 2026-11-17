import { expect, test, type Page } from '@playwright/test';
import { captureWorkspace } from './support';
const fixture = { embeddings: [{ name: 'custom', available: true }], vlm: [{ name: 'granite-fixture', engine: 'transformers', repo_id: 'fixture/granite', available: true, revision: 'fixture-revision', size: 1048576 }, { name: 'missing-fixture', available: false }, { name: 'apple-mlx', available: true }], recommended: { devbox: ['fixture/granite'] } };
async function setup(page: Page) {
  let catalog: unknown = fixture;
  let status = 200;
  let delay = 0;
  let delivered = 0;
  const methods: string[] = [];
  await page.route('**/v1/**', async (route) => {
    const request = route.request();
    methods.push(request.method());
    const path = new URL(request.url()).pathname;
    const json = (body: unknown, code = 200) => route.fulfill({ status: code, contentType: 'application/json', body: JSON.stringify(body) });
    if (path === '/v1/ui/config') return json({ embedding_backend: 'ollama', embedding_model: 'custom', qdrant_available: false, qdrant_label: 'Worker Qdrant', vlm_models: ['standard'] });
    if (path === '/v1/models') { const body = catalog; const code = status; await new Promise((r) => setTimeout(r, delay)); await json(body, code); delivered++; return; }
    return json({ jobs: [], total: 0, limit: 50, offset: 0 });
  });
  await page.goto('/');
  await page.getByLabel('Worker access token').fill('fixture-token');
  await page.getByRole('button', { name: 'Connect to worker' }).click();
  await page.getByRole('button', { name: 'Edit job settings' }).click();
  await expect(page.getByRole('heading', { name: 'granite-fixture', exact: true })).toBeVisible();
  return { change: (body: unknown, code = 200, ms = 0) => { catalog = body; status = code; delay = ms; }, methods, delivered: () => delivered };
}
for (const appearance of ['light', 'dark'] as const) test(`model catalog displays worker discovery in ${appearance}`, async ({ page }) => {
  await page.emulateMedia({ colorScheme: appearance });
  const mocked = await setup(page);
  await expect(page.getByText('apple-mlx')).toHaveCount(0);
  await expect(page.getByText('Recommended by the worker devbox catalog')).toBeVisible();
  await expect(page.getByText('Not detected', { exact: true })).toBeVisible();
  await expect(page.getByLabel('Embedding model', { exact: true })).toHaveValue('custom');
  await captureWorkspace(page, `models-${appearance}`, 'Job settings');
  await page.setViewportSize({ width: 390, height: 844 });
  await captureWorkspace(page, `models-${appearance}-mobile`, 'Job settings');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  expect(mocked.methods.every((m) => m === 'GET')).toBe(true);
});
test('refresh clears stale availability and handles partial discovery and failures', async ({ page }) => {
  const mocked = await setup(page);
  mocked.change({ cache_error: 'private fixture failure', vlm: [{ name: 'uncertain', available: false }] });
  await page.getByRole('button', { name: 'Refresh model catalog' }).click();
  await expect(page.getByText('Unknown', { exact: true })).toBeVisible();
  await expect(page.getByText('granite-fixture', { exact: true })).toHaveCount(0);
  await expect(page.getByText('private fixture failure')).toHaveCount(0);
  mocked.change({ detail: 'offline' }, 503);
  await page.getByRole('button', { name: 'Refresh model catalog' }).click();
  await expect(page.getByText('Model readiness is unknown because')).toBeVisible();
  mocked.change({ embeddings: [] });
  await page.getByRole('button', { name: 'Refresh model catalog' }).click();
  await expect(page.getByText('No compatible models were reported.')).toBeVisible();
});
test('catalog authorization failure clears the session', async ({ page }) => {
  const mocked = await setup(page);
  mocked.change({ detail: 'Unauthorized' }, 401);
  await page.getByRole('button', { name: 'Refresh model catalog' }).click();
  await expect(page.getByLabel('Worker access token')).toHaveValue('');
  await expect(page.getByTestId('model-readiness')).toHaveCount(0);
});
test('a delivered late catalog cannot return after logout even if abort is ignored', async ({ page }) => {
  await page.addInitScript(() => { const original = window.fetch; window.fetch = (input, init) => original(input, String(input).includes('/models') ? { ...init, signal: undefined } : init); });
  const mocked = await setup(page);
  const before = mocked.delivered();
  mocked.change({ embeddings: [{ name: 'late-secret-model', available: true }] }, 200, 350);
  await page.getByRole('button', { name: 'Refresh model catalog' }).click();
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect.poll(mocked.delivered).toBeGreaterThan(before);
  await expect(page.getByText('late-secret-model')).toHaveCount(0);
  await expect(page.getByLabel('Worker access token')).toHaveValue('');
  expect(await page.evaluate(() => [localStorage.length, sessionStorage.length])).toEqual([0, 0]);
});
test('catalog pages are bounded and refresh resets pagination', async ({ page }) => {
  const mocked = await setup(page);
  mocked.change({ embeddings: Array.from({ length: 23 }, (_, i) => ({ name: `fixture-model-${i}`, available: true })) });
  await page.getByRole('button', { name: 'Refresh model catalog' }).click();
  await expect(page.getByTestId('model-readiness').locator('article')).toHaveCount(20);
  await page.getByRole('button', { name: 'Next models' }).click();
  await expect(page.getByTestId('model-readiness').locator('article')).toHaveCount(3);
  await expect(page.getByRole('heading', { name: 'fixture-model-22', exact: true })).toBeVisible();
  mocked.change({ embeddings: [{ name: 'replacement', available: false }] });
  await page.getByRole('button', { name: 'Refresh model catalog' }).click();
  await expect(page.getByRole('heading', { name: 'replacement', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Next models' })).toHaveCount(0);
});
