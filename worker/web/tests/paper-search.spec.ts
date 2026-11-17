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
      return json({ results: body.papers_first ? [{ id: 'paper', score: .8, payload: { record_type: 'document', source: 'fixture.pdf', text: 'Mocked paper summary' } }, ...(body.expand_documents ? [{ ...passage, score: .7 }] : [])] : [{ ...passage, score: .9421 }], limit: 10, offset: body.offset, next_offset: body.offset ? null : 10, embedding_backend: body.embedding_backend, embedding_model: body.embedding_model, embedding_dim: 3 });
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

test('paper modes retain metadata filters and paginate papers separately from supporting passages', async ({ page }) => {
  const searches = await mockWorker(page); await connectSearch(page);
  await page.getByLabel('Heading contains').fill('Results');
  await page.getByLabel('Search for', { exact: true }).selectOption('papers-with-passages');
  await expect(page.getByLabel('Heading contains')).toBeDisabled();
  await expect(page.getByLabel('Find a paper')).toBeVisible();
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  expect(searches).toHaveLength(0);
  await page.getByRole('button', { name: 'Clear passage filters' }).click();
  await page.getByLabel('Author contains').fill('Ada');
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect(page.getByText('Paper summary', { exact: true })).toBeVisible();
  await expect(page.getByText('Supporting passage', { exact: true })).toBeVisible();
  await expect(page.getByText('Papers 1–1 · 1 supporting passages · up to 10 papers per page')).toBeVisible();
  expect(searches[0]).toMatchObject({ papers_first: true, expand_documents: true, filters: [{ key: 'authors', text: 'Ada' }], offset: 0 });
  await page.getByRole('button', { name: 'Next search results' }).click();
  await expect.poll(() => searches.length).toBe(2);
  expect(searches[1]).toMatchObject({ offset: 10, papers_first: true });
  await page.getByLabel('Search for', { exact: true }).selectOption('papers');
  await expect(page.getByText('Paper summary', { exact: true })).toHaveCount(0);
  await expect(page.getByText('Up to 10 paper summaries per page. Papers need stored document summaries.')).toBeVisible();
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect.poll(() => searches.length).toBe(3);
  expect(searches[2]).toMatchObject({ offset: 0, expand_documents: false });
  await expect(page.getByText('Supporting passage', { exact: true })).toHaveCount(0);
  await page.getByLabel('Search for', { exact: true }).selectOption('passages');
  await expect(page.getByLabel('Heading contains')).toBeEnabled();
});
for (const theme of ['light', 'dark'] as const) test(`paper search ${theme} capture`, async ({ page }) => {
  await page.emulateMedia({ colorScheme: theme });
  await mockWorker(page); await connectSearch(page);
  await page.getByLabel('Search for', { exact: true }).selectOption('papers-with-passages');
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect(page.getByText('Paper summary', { exact: true })).toBeVisible();
  await captureWorkspace(page, `papers-${theme}`, "Collections");
});

test('paper mode changes and collection changes discard responses even when cancellation is ignored', async ({ page }) => {
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
  await page.getByLabel('Search for', { exact: true }).selectOption('papers');
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

