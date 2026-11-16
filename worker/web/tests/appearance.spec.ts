import { expect, test, type Page } from '@playwright/test';
import { captureWorkspace } from './support';

const key = 'chunky.appearance';
const fixture = { id: 'theme-fixture', filename: 'theme-fixture.pdf', status: 'succeeded', progress: { message: 'Mocked theme fixture complete', percent: 100 }, result: { chunks: [{ text: 'Mocked theme fixture. This is not a real document conversion or quality measurement.', page: 1, headings: ['Fixture overview'] }] } };
async function mockWorker(page: Page) {
  await page.route('**/v1/**', (route) => {
    expect(route.request().headers().authorization).toBe('Bearer theme-fixture-token');
    const url = new URL(route.request().url());
    let body: unknown = {};
    if (url.pathname === '/v1/ui/config') body = { embedding_backend: 'ollama', embedding_model: 'fixture-model', qdrant_available: true, qdrant_read_available: true, qdrant_label: 'Worker Qdrant', vlm_models: ['standard', 'granite-docling-transformers'] };
    else if (url.pathname === '/v1/jobs') body = { jobs: [{ ...fixture, result: undefined }], total: 1, limit: 50, offset: 0 };
    else if (url.pathname === '/v1/models') body = { embeddings: [] };
    else if (url.pathname.startsWith('/v1/jobs/')) body = fixture;
    else if (url.pathname === '/v1/collections') body = { collections: [{ name: 'theme-fixtures' }], target_label: 'Worker Qdrant' };
    else if (url.pathname.endsWith('/points')) body = { collection: 'theme-fixtures', points: [{ id: 'fixture-point', payload: { text: 'Mocked theme fixture passage, not actual conversion results.', page: 1, source: 'theme-fixture.pdf' } }], limit: 50, next_offset: null, points_count: 1, semantic_search_available: true, semantic_search_reason: null, embedding: { backend: 'ollama', model: 'fixture-model', dimensions: 3, distance: 'cosine', hybrid: false } };
    else if (url.pathname === '/v1/search') body = { results: [{ id: 'fixture-point', score: .9, payload: { text: 'Mocked theme search fixture. Scores are synthetic test data.', page: 1, source: 'theme-fixture.pdf' } }], offset: 0, next_offset: null, limit: 10, embedding_model: 'fixture-model', embedding_backend: 'ollama', embedding_dim: 3 };
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
}
async function connect(page: Page) {
  await page.getByLabel('Worker access token').fill('theme-fixture-token');
  await page.getByRole('button', { name: 'Connect to worker' }).click();
  await expect(page.getByRole('heading', { name: 'Processing queue', exact: true })).toBeVisible();
}
async function theme(page: Page, value: string) {
  await expect(page.locator('html')).toHaveAttribute('data-theme', value);
}

test('system appearance reacts to OS changes and explicit choices survive reload', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByLabel('Appearance', { exact: true })).toHaveValue('system');
  await theme(page, 'light');
  expect(await page.evaluate(() => localStorage.length)).toBe(0);
  await captureWorkspace(page, 'light-login', /Your documents/);
  await page.emulateMedia({ colorScheme: 'dark' });
  await theme(page, 'dark');
  await page.getByLabel('Appearance', { exact: true }).selectOption('light');
  await theme(page, 'light');
  await page.reload();
  await theme(page, 'light');
  await expect(page.getByLabel('Appearance', { exact: true })).toHaveValue('light');
  await page.getByLabel('Appearance', { exact: true }).selectOption('system');
  await theme(page, 'dark');
  await page.emulateMedia({ colorScheme: 'light' });
  await theme(page, 'light');
});

test('dark preference survives sign-out while token and document data do not persist', async ({ page }) => {
  await mockWorker(page);
  await page.goto('/');
  await page.getByLabel('Appearance', { exact: true }).selectOption('dark');
  await connect(page);
  await theme(page, 'dark');
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page.getByLabel('Worker access token')).toHaveValue('');
  await expect(page.getByText('theme-fixture.pdf', { exact: true })).toHaveCount(0);
  expect(await page.evaluate(() => Object.entries(localStorage))).toEqual([[key, 'dark']]);
  expect(await page.evaluate(() => sessionStorage.length)).toBe(0);
  await page.reload();
  await theme(page, 'dark');
  await expect(page.getByLabel('Appearance', { exact: true })).toHaveValue('dark');
  await expect(page.getByLabel('Worker access token')).toHaveValue('');
});

test('dark login, queue, settings, collections, search and mobile remain readable', async ({ page }) => {
  await mockWorker(page);
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.goto('/');
  await theme(page, 'dark');
  await captureWorkspace(page, 'dark-login', /Your documents/);
  await connect(page);
  await page.getByRole('button', { name: /^theme-fixture.pdf/ }).click();
  await expect(page.getByText('Fixture overview', { exact: true })).toBeVisible();
  await captureWorkspace(page, 'dark-queue', 'Processing queue');
  await page.getByRole('button', { name: 'Job settings', exact: false }).first().click();
  await captureWorkspace(page, 'dark-settings', 'Job settings');
  await page.getByRole('button', { name: 'Collections', exact: true }).click();
  await page.getByRole('navigation', { name: 'Collections', exact: true }).getByRole('button', { name: 'theme-fixtures' }).click();
  await expect(page.getByText('Mocked theme fixture passage, not actual conversion results.', { exact: true })).toBeVisible();
  await captureWorkspace(page, 'dark-collections', 'Collections');
  await page.getByRole('button', { name: 'Semantic search', exact: true }).click();
  await page.getByLabel('Find a passage').fill('Fixture question');
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect(page.getByText('Score 0.9000', { exact: true })).toBeVisible();
  await captureWorkspace(page, 'dark-search', 'Collections');
  await page.setViewportSize({ width: 390, height: 844 });
  await captureWorkspace(page, 'dark-mobile', 'Collections');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await expect(page.getByLabel('Appearance', { exact: true })).toBeVisible();
});

test('blocked localStorage does not prevent switching appearance', async ({ page }) => {
  await page.addInitScript(() => Object.defineProperty(window, 'localStorage', { get() { throw new DOMException('Blocked', 'SecurityError'); } }));
  const errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto('/');
  await page.getByLabel('Appearance', { exact: true }).selectOption('dark');
  await theme(page, 'dark');
  expect(errors).toEqual([]);
});
