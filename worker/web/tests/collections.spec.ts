import { expect, test, type Page } from '@playwright/test';
import { captureWorkspace } from './support';

const embedding = { backend: 'ollama', model: 'fixture-embedding', dimensions: 3, distance: 'cosine', hybrid: true };
const first = { id: 'fixture-point-1', payload: { text: 'Fixture collection passage. These are mocked chunks, not live conversion results. <img src=x onerror="window.collectionXSS=true">', source: 'fixture-science.pdf', page: 2, headings: ['Fixture findings'] } };
const second = { id: 'fixture-point-51', payload: { text: 'Fixture next-page passage beyond the first 50 points.', source: 'fixture-next.pdf', page: 5, headings: ['Next page'] } };
const pointPage = (collection: string, next = false) => ({ collection, points: [next ? second : first], limit: 50, next_offset: next ? null : 'cursor-next', points_count: 73, semantic_search_available: collection !== 'legacy', semantic_search_reason: collection === 'legacy' ? 'Collection embedding identity is unknown. Browsing is available; choose a verified collection for semantic search.' : null, embedding: collection === 'legacy' ? null : embedding });
async function mockCollections(page: Page) {
  const searches: Record<string, unknown>[] = [];
  const cursors: (string | null)[] = [];
  const urls: string[] = [];
  await page.route('**/v1/**', async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    urls.push(url.href);
    expect(request.headers().authorization).toBe('Bearer fixture-token');
    const json = (body: unknown, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
    if (url.pathname === '/v1/ui/config') return json({ embedding_backend: 'ollama', embedding_model: 'worker-default', qdrant_available: false, qdrant_read_available: true, qdrant_label: 'Worker Qdrant', vlm_models: ['standard'] });
    if (url.pathname === '/v1/jobs') return json({ jobs: [], total: 0, limit: 50, offset: 0 });
    if (url.pathname === '/v1/models') return json({ embeddings: [] });
    if (url.pathname === '/v1/collections') return json({ collections: [{ name: 'fixture-papers' }, { name: 'legacy' }], target_label: 'Worker Qdrant' });
    if (url.pathname.endsWith('/points')) {
      expect(url.searchParams.get('limit')).toBe('50');
      cursors.push(url.searchParams.get('offset'));
      return json(pointPage(url.pathname.split('/')[3], url.searchParams.has('offset')));
    }
    if (url.pathname === '/v1/search') {
      const body = request.postDataJSON() as Record<string, unknown>;
      searches.push(body);
      return json({ results: [{ ...(body.offset ? second : first), score: body.offset ? .8712 : .9823 }], limit: 10, offset: body.offset, next_offset: body.offset ? null : 10, embedding_backend: body.embedding_backend, embedding_model: body.embedding_model, embedding_dim: 3 });
    }
    return json({ detail: 'Unexpected fixture route' }, 404);
  });
  return { searches, cursors, urls };
}
async function connect(page: Page) {
  await page.goto('/');
  await page.getByLabel('Worker access token').fill('fixture-token');
  await page.getByRole('button', { name: 'Connect to worker' }).click();
  await page.getByRole('button', { name: 'Collections', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Collections', exact: true })).toBeVisible();
}
async function choose(page: Page, name = 'fixture-papers') {
  await page.getByRole('navigation', { name: 'Collections', exact: true }).getByRole('button', { name, exact: false }).click();
  await expect(page.getByText('Fixture findings', { exact: true })).toBeVisible();
}

test('keyless read target lists collections and cursor pages with real responsive captures', async ({ page }) => {
  const mocked = await mockCollections(page);
  await connect(page);
  await choose(page);
  await expect(page.getByText('73 points · 3 dimensions · fixture-embedding')).toBeVisible();
  await expect(page.getByText('Page 1 · up to 50 points per page')).toBeVisible();
  expect(await page.evaluate(() => (window as Window & { collectionXSS?: boolean }).collectionXSS)).toBeUndefined();
  await captureWorkspace(page, 'collections', 'Collections');
  await page.getByRole('button', { name: 'Next points' }).click();
  await expect(page.getByText('Fixture next-page passage beyond the first 50 points.')).toBeVisible();
  await expect(page.getByText('Page 2 · up to 50 points per page')).toBeVisible();
  await page.getByRole('button', { name: 'Previous points' }).click();
  await expect(page.getByText('Fixture findings', { exact: true })).toBeVisible();
  expect(mocked.cursors).toEqual([null, 'cursor-next', null]);
  await page.setViewportSize({ width: 390, height: 844 });
  await captureWorkspace(page, 'collections-mobile', 'Collections');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  expect(mocked.urls.every((url) => url.startsWith('http://127.0.0.1:4173/v1/') && !url.includes('fixture-token'))).toBe(true);
});

test('semantic search uses collection identity, displays scores and pages explicitly', async ({ page }) => {
  const mocked = await mockCollections(page);
  await connect(page);
  await choose(page);
  await page.getByRole('button', { name: 'Semantic search', exact: true }).click();
  await page.getByText('Query model and search options', { exact: true }).click();
  await expect(page.getByLabel('Query embedding model', { exact: true })).toHaveValue('fixture-embedding');
  await page.getByLabel('Find a passage').fill('What did the fixture find?');
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect(page.getByText('Score 0.9823', { exact: true })).toBeVisible();
  await expect(page.getByText('Showing 1–1 · 10 results per page')).toBeVisible();
  expect(mocked.searches[0]).toEqual({ query: 'What did the fixture find?', collection: 'fixture-papers', use_worker_qdrant: true, mode: 'dense', embedding_backend: 'ollama', embedding_model: 'fixture-embedding', limit: 10, offset: 0 });
  await captureWorkspace(page, 'search', 'Collections');
  await page.getByRole('button', { name: 'Next search results' }).click();
  await expect(page.getByText('Score 0.8712', { exact: true })).toBeVisible();
  expect(mocked.searches[1].offset).toBe(10);
  await page.getByRole('button', { name: 'Previous search results' }).click();
  await expect(page.getByText('Score 0.9823', { exact: true })).toBeVisible();
  await page.getByLabel('Query embedding model', { exact: true }).fill('different-model');
  await expect(page.getByText('Score 0.9823', { exact: true })).toHaveCount(0);
  expect(JSON.stringify(mocked.searches)).not.toContain('qdrant_api_key');
  expect(JSON.stringify(mocked.searches)).not.toContain('qdrant_url');
});

test('unknown identity remains browsable and clearly refuses semantic search', async ({ page }) => {
  const mocked = await mockCollections(page);
  await connect(page);
  await choose(page, 'legacy');
  await page.getByRole('button', { name: 'Semantic search', exact: true }).click();
  await expect(page.getByText('Collection embedding identity is unknown.', { exact: false })).toBeVisible();
  await expect(page.getByLabel('Find a passage')).toBeDisabled();
  await expect(page.getByRole('button', { name: 'Search', exact: true })).toBeDisabled();
  expect(mocked.searches).toHaveLength(0);
});

test('late collection and search responses cannot replace a newer selection', async ({ page }) => {
  await mockCollections(page);
  let release: (() => void) | undefined;
  const hold = new Promise<void>((resolve) => release = resolve);
  let began = false;
  await page.route('**/v1/collections/fixture-papers/points?*', async (route) => { began = true; await hold; await route.fulfill({ contentType: 'application/json', body: JSON.stringify(pointPage('fixture-papers')) }).catch(() => {}); });
  await connect(page);
  await page.getByRole('navigation', { name: 'Collections', exact: true }).getByRole('button', { name: 'fixture-papers' }).click();
  await expect.poll(() => began).toBe(true);
  await choose(page, 'legacy');
  release?.();
  await expect(page.getByRole('heading', { name: 'legacy', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Semantic search', exact: true }).click();
  await expect(page.getByLabel('Find a passage')).toBeDisabled();
});

test('search changes and logout discard delayed results and auth rejection clears the session', async ({ page }) => {
  await mockCollections(page);
  let release: (() => void) | undefined;
  const hold = new Promise<void>((resolve) => release = resolve);
  let began = false;
  await page.route('**/v1/search', async (route) => { began = true; await hold; await route.fulfill({ contentType: 'application/json', body: JSON.stringify({ results: [{ ...first, score: .99 }], offset: 0, next_offset: null, limit: 10, embedding_model: 'fixture-embedding', embedding_backend: 'ollama', embedding_dim: 3 }) }).catch(() => {}); });
  await connect(page);
  await choose(page);
  await page.getByRole('button', { name: 'Semantic search', exact: true }).click();
  await page.getByLabel('Find a passage').fill('Old question');
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect.poll(() => began).toBe(true);
  await page.getByLabel('Find a passage').fill('New question');
  release?.();
  await expect(page.getByText('Score 0.9900')).toHaveCount(0);
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page.getByLabel('Worker access token')).toHaveValue('');
  await expect(page.getByText('Fixture findings')).toHaveCount(0);
  await page.unroute('**/v1/search');
  await page.route('**/v1/collections', (route) => route.fulfill({ status: 401, contentType: 'application/json', body: '{"detail":"Expired token"}' }));
  await connect(page);
  await expect(page.getByLabel('Worker access token')).toHaveValue('');
  await expect(page.getByRole('alert')).toContainText('rejected this token');
});

test('collection changes and logout invalidate in-flight semantic searches', async ({ page }) => {
  await mockCollections(page);
  const releases: (() => void)[] = [];
  let searches = 0;
  await page.route('**/v1/search', async (route) => {
    searches++;
    await new Promise<void>((resolve) => releases.push(resolve));
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify({ results: [{ ...first, score: .7654 }], offset: 0, next_offset: null, limit: 10, embedding_model: 'fixture-embedding', embedding_backend: 'ollama', embedding_dim: 3 }) }).catch(() => {});
  });
  await connect(page);
  await choose(page);
  await page.getByRole('button', { name: 'Semantic search', exact: true }).click();
  await page.getByLabel('Find a passage').fill('Fixture question');
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect.poll(() => searches).toBe(1);
  await choose(page, 'legacy');
  releases[0]();
  await page.getByRole('button', { name: 'Semantic search', exact: true }).click();
  await expect(page.getByLabel('Find a passage')).toBeDisabled();
  await expect(page.getByText('Score 0.7654')).toHaveCount(0);
  await choose(page);
  await page.getByRole('button', { name: 'Semantic search', exact: true }).click();
  await page.getByLabel('Find a passage').fill('Second fixture question');
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect.poll(() => searches).toBe(2);
  await page.getByRole('button', { name: 'Sign out' }).click();
  releases[1]();
  await expect(page.getByLabel('Worker access token')).toHaveValue('');
  await expect(page.getByText('Score 0.7654')).toHaveCount(0);
  await expect(page.getByText('Fixture findings')).toHaveCount(0);
});
