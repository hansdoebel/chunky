import { expect, test, type Page } from '@playwright/test';
import { captureWorkspace } from './support';

const embedding = { backend: 'ollama', model: 'fixture-embedding', dimensions: 3, distance: 'cosine', hybrid: true };
const passage = { id: 'filtered-fixture-1', payload: { text: 'Mocked filter fixture passage, not a live conversion or retrieval-quality result.', source: 'filter-fixture.pdf', page: 4, headings: ['Fixture results'], year: 2023, authors: 'Ada Lovelace', doi: '10.1234/fixture', content_type: 'table' } };
const combinedFilters = [
  { key: 'year', gte: 2020, lte: 2024 }, { key: 'authors', text: 'Ada' },
  { key: 'doi', match: '10.1234/fixture' }, { key: 'doc_title', text: 'Methods' },
  { key: 'headings', text: 'Results' }, { key: 'content_type', match: 'table' },
];

async function mockWorker(page: Page) {
  const searches: Record<string, unknown>[] = [];
  await page.route('**/v1/**', (route) => {
    const request = route.request();
    expect(request.headers().authorization).toBe('Bearer fixture-token');
    expect(request.url()).not.toContain('fixture-token');
    const url = new URL(request.url());
    const json = (value: unknown, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(value) });
    if (url.pathname === '/v1/ui/config') return json({ embedding_backend: 'ollama', embedding_model: 'worker-default', qdrant_available: false, qdrant_read_available: true, qdrant_label: 'Worker Qdrant', vlm_models: ['standard'] });
    if (url.pathname === '/v1/jobs') return json({ jobs: [], total: 0, limit: 50, offset: 0 });
    if (url.pathname === '/v1/models') return json({ embeddings: [] });
    if (url.pathname === '/v1/collections') return json({ collections: [{ name: 'fixture-papers' }, { name: 'fixture-other' }], target_label: 'Worker Qdrant' });
    if (url.pathname.endsWith('/points')) return json({ collection: url.pathname.split('/')[3], points: [passage], limit: 50, next_offset: null, points_count: 73, semantic_search_available: true, semantic_search_reason: null, embedding });
    if (url.pathname === '/v1/search') {
      const body = request.postDataJSON() as Record<string, unknown>;
      searches.push(body);
      return json({ results: [{ ...passage, score: .9421 }], limit: 10, offset: body.offset, next_offset: body.offset ? null : 10, embedding_backend: body.embedding_backend, embedding_model: body.embedding_model, embedding_dim: 3 });
    }
    return json({ detail: 'Unexpected fixture route' }, 404);
  });
  return searches;
}

async function connectSearch(page: Page) {
  await page.goto('/');
  await page.getByLabel('Worker access token').fill('fixture-token');
  await page.getByRole('button', { name: 'Connect to worker' }).click();
  await page.getByRole('button', { name: 'Collections', exact: true }).click();
  await page.getByRole('navigation', { name: 'Collections', exact: true }).getByRole('button', { name: 'fixture-papers' }).click();
  await page.getByRole('button', { name: 'Semantic search', exact: true }).click();
  await page.getByLabel('Find a passage').fill('What did the fixture find?');
  await page.getByText('Filter passages', { exact: true }).click();
}

async function fillCombinedFilters(page: Page) {
  await page.getByLabel('From year', { exact: true }).fill('2020');
  await page.getByLabel('To year', { exact: true }).fill('2024');
  await page.getByLabel('Author contains', { exact: true }).fill('Ada');
  await page.getByLabel('DOI', { exact: true }).fill('10.1234/fixture');
  await page.getByLabel('Document title contains', { exact: true }).fill('Methods');
  await page.getByLabel('Heading contains', { exact: true }).fill('Results');
  await page.getByLabel('Element type', { exact: true }).selectOption('table');
}

test('combined filters reach the worker on every page and clearing preserves unfiltered search', async ({ page }) => {
  const searches = await mockWorker(page);
  await connectSearch(page);
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect(page.getByText('Score 0.9421', { exact: true })).toBeVisible();
  expect(searches[0]).not.toHaveProperty('filters');
  await fillCombinedFilters(page);
  await expect(page.getByText('Score 0.9421', { exact: true })).toHaveCount(0);
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect(page.getByText('Score 0.9421', { exact: true })).toBeVisible();
  expect(searches[1]).toMatchObject({ filters: combinedFilters, offset: 0, use_worker_qdrant: true });
  await page.getByRole('button', { name: 'Next search results', exact: true }).click();
  await expect.poll(() => searches.length).toBe(3);
  expect(searches[2]).toMatchObject({ filters: combinedFilters, offset: 10 });
  await page.getByLabel('Author contains', { exact: true }).fill('Grace');
  await expect(page.getByText('Score 0.9421', { exact: true })).toHaveCount(0);
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect(page.getByText('Score 0.9421', { exact: true })).toBeVisible();
  expect(searches[3].offset).toBe(0);
  expect(searches[3].filters).toEqual(combinedFilters.map((filter) => filter.key === 'authors' ? { key: 'authors', text: 'Grace' } : filter));
  await page.getByRole('button', { name: 'Clear filters', exact: true }).click();
  await expect(page.getByLabel('From year', { exact: true })).toHaveValue('');
  await expect(page.getByText('Score 0.9421', { exact: true })).toHaveCount(0);
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect.poll(() => searches.length).toBe(5);
  expect(searches[4]).not.toHaveProperty('filters');
  expect(searches[4].offset).toBe(0);
  expect(JSON.stringify(searches)).not.toContain('qdrant_api_key');
  expect(JSON.stringify(searches)).not.toContain('qdrant_url');
});

test('invalid year filters show accessible errors and never send a query', async ({ page }) => {
  const searches = await mockWorker(page);
  await connectSearch(page);
  await page.getByLabel('From year', { exact: true }).fill('2020.5');
  await expect(page.getByLabel('From year', { exact: true })).toHaveAttribute('aria-invalid', 'true');
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect(page.getByText('From year must be a whole number from 1 to 9999.', { exact: true }).first()).toBeVisible();
  expect(searches).toHaveLength(0);
  await page.getByLabel('From year', { exact: true }).fill('2025');
  await page.getByLabel('To year', { exact: true }).fill('2020');
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect(page.getByText('From year must not be later than to year.', { exact: true }).first()).toBeVisible();
  expect(searches).toHaveLength(0);
});

test('filter changes and collection changes invalidate pending results without persisting draft data', async ({ page }) => {
  await page.addInitScript(() => {
    const original = window.fetch.bind(window);
    const state = window as Window & { filterSearchResponses?: number };
    window.fetch = async (input, init) => {
      const search = typeof input === 'string' && new URL(input, location.href).pathname === '/v1/search';
      const response = await original(input, search ? { ...init, signal: undefined } : init);
      if (search) {
        await response.clone().arrayBuffer();
        state.filterSearchResponses = (state.filterSearchResponses ?? 0) + 1;
      }
      return response;
    };
  });
  await mockWorker(page);
  const releases: (() => void)[] = [];
  let requests = 0;
  await page.route('**/v1/search', async (route) => {
    requests++;
    await new Promise<void>((resolve) => releases.push(resolve));
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify({ results: [{ ...passage, score: .7654 }], limit: 10, offset: 0, next_offset: null, embedding_backend: 'ollama', embedding_model: 'fixture-embedding', embedding_dim: 3 }) }).catch(() => {});
  });
  await connectSearch(page);
  await page.getByLabel('Author contains', { exact: true }).fill('Ada');
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect.poll(() => requests).toBe(1);
  await page.getByLabel('Author contains', { exact: true }).fill('Grace');
  releases[0]();
  await expect.poll(() => page.evaluate(() => (window as Window & { filterSearchResponses?: number }).filterSearchResponses ?? 0)).toBe(1);
  await expect(page.getByText('Score 0.7654', { exact: true })).toHaveCount(0);
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect.poll(() => requests).toBe(2);
  await page.getByRole('navigation', { name: 'Collections', exact: true }).getByRole('button', { name: 'fixture-other' }).click();
  releases[1]();
  await expect.poll(() => page.evaluate(() => (window as Window & { filterSearchResponses?: number }).filterSearchResponses ?? 0)).toBe(2);
  await page.getByRole('button', { name: 'Semantic search', exact: true }).click();
  await page.getByText('Filter passages', { exact: true }).click();
  await expect(page.getByLabel('Author contains', { exact: true })).toHaveValue('');
  await expect(page.getByText('Score 0.7654', { exact: true })).toHaveCount(0);
  await page.getByLabel('Author contains', { exact: true }).fill('Sensitive fixture author');
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page.getByLabel('Worker access token')).toHaveValue('');
  expect(await page.evaluate(() => [localStorage.length, sessionStorage.length])).toEqual([0, 0]);
  await expect(page.getByLabel('Author contains', { exact: true })).toHaveCount(0);
});

test('filter search authorization rejection clears the session', async ({ page }) => {
  await mockWorker(page);
  await page.route('**/v1/search', (route) => route.fulfill({ status: 401, contentType: 'application/json', body: '{"detail":"Expired token"}' }));
  await connectSearch(page);
  await page.getByLabel('Author contains', { exact: true }).fill('Ada');
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect(page.getByLabel('Worker access token')).toHaveValue('');
  await expect(page.getByRole('alert')).toContainText('rejected this token');
  await expect(page.getByLabel('Author contains', { exact: true })).toHaveCount(0);
});

for (const scheme of ['light', 'dark'] as const) {
  test(`filter controls remain readable in ${scheme} appearance`, async ({ page }) => {
    await page.emulateMedia({ colorScheme: scheme });
    await mockWorker(page);
    await connectSearch(page);
    if (scheme === 'dark') await expect(page.locator('html')).toHaveClass(/dark/);
    else await expect(page.locator('html')).not.toHaveClass(/dark/);
    await fillCombinedFilters(page);
    await expect(page.getByLabel('Element type', { exact: true })).toHaveValue('table');
    await captureWorkspace(page, `filters-${scheme}`, 'Collections');
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  });
}
