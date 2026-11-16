import { expect, test, type Page } from '@playwright/test';
import { captureWorkspace } from './support';

const fixtureJob = { id: 'insight-fixture', filename: 'fixture-insights.pdf', status: 'succeeded', result: { chunks: [{ text: 'Mocked insight fixture, not a real conversion result.', page: 1 }], metrics: { host: 'Fixture measurements only, not hardware benchmark results', wall_ms: 1250, pages_per_s: 0, chunks_per_s: null, embeddings_per_s: 4, stages: [{ name: 'convert_layout', status: 'ok', runtime: 'fixture-docling', duration_ms: 1250, pages: 2 }, { name: 'ocr', status: 'skipped', runtime: null, duration_ms: 0, pages: 0 }, { name: 'embedding', status: 'error', runtime: 'fixture-embedding', duration_ms: null, chunks: 0 }], resources: { gpu_name: 'Fixture GPU', vram_used_mb: 0, vram_total_mb: null } }, verification_status: 'yellow' } };
const missingJob = { id: 'missing-fixture', filename: 'fixture-without-report.pdf', status: 'canceled', result: null };
const fixtureReport = { status: 'yellow', filename: 'fixture-insights.pdf', generated_at: '2026-11-16T00:00:00Z', text: { status: 'yellow', note: 'Mocked verification fixture; not a real PDF check.' }, pages: [{ page: 1, status: 'red', coverage: 0, flags: ['Fixture missing text <script>window.insightXSS=true</script>'] }, { page: 2, status: 'green', coverage: 1, flags: [] }], store: { status: 'skipped', checked: 0, issues: [] }, vector_spot_check: { status: 'skipped', samples: [] }, retrieval: { status: 'skipped', queries: [] }, attributions: [{ chunk_id: 'fixture-chunk', page: 1, page_end: 1, suggested_page: 2, similarity: .4, matched: false }] };

async function mockInsights(page: Page) {
  const requests: { path: string; method: string }[] = [];
  await page.route('**/v1/**', async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    requests.push({ path: url.pathname, method: request.method() });
    expect(request.headers().authorization).toBe('Bearer fixture-token');
    const json = (value: unknown, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(value) });
    if (url.pathname === '/v1/ui/config') return json({ embedding_backend: 'ollama', embedding_model: 'fixture-model', qdrant_available: false, qdrant_read_available: false, qdrant_label: 'Worker Qdrant', vlm_models: ['standard'] });
    if (url.pathname === '/v1/models') return json({ embeddings: [] });
    if (url.pathname === '/v1/jobs') return json({ jobs: [fixtureJob, missingJob].map(({ result: _result, ...job }) => job), total: 2, limit: 50, offset: 0 });
    if (url.pathname.endsWith('/verification')) return url.pathname.includes(missingJob.id) ? json({ detail: 'Verification report not found' }, 404) : json(fixtureReport);
    if (url.pathname.startsWith('/v1/jobs/')) {
      expect(url.searchParams.get('include_embeddings')).toBe('false');
      return json(url.pathname.endsWith(fixtureJob.id) ? fixtureJob : missingJob);
    }
    return json({ detail: 'Unexpected fixture request' }, 404);
  });
  return requests;
}
async function connect(page: Page) {
  await page.goto('/');
  await page.getByLabel('Worker access token').fill('fixture-token');
  await page.getByRole('button', { name: 'Connect to worker' }).click();
  await expect(page.getByRole('heading', { name: 'Processing queue', exact: true })).toBeVisible();
  await page.getByRole('button', { name: /^fixture-insights.pdf/ }).click();
  await expect(page.getByText('Fixture measurements only, not hardware benchmark results', { exact: false })).toBeVisible();
}

for (const theme of ['light', 'dark'] as const) {
  test(`read-only job measurements and verification render in ${theme} mode`, async ({ page }) => {
    await page.emulateMedia({ colorScheme: theme });
    const requests = await mockInsights(page);
    await connect(page);
    await expect(page.getByRole('table', { name: 'Stage measurements' })).toBeVisible();
    await expect(page.getByRole('row', { name: /ocr/ })).toContainText('0 ms');
    await expect(page.getByRole('row', { name: /ocr/ })).toContainText('Skipped');
    await expect(page.getByRole('row', { name: /embedding/ })).toContainText('Error');
    await expect(page.getByRole('row', { name: /embedding/ })).toContainText('Not recorded');
    await page.getByRole('button', { name: 'View verification report' }).click();
    await expect(page.getByText('Mocked verification fixture; not a real PDF check.', { exact: true })).toBeVisible();
    await expect(page.getByText('Coverage: 0%', { exact: true })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Vector spot check', exact: true })).toBeVisible();
    expect(await page.evaluate(() => (window as Window & { insightXSS?: boolean }).insightXSS)).toBeUndefined();
    await captureWorkspace(page, `insights-${theme}`, 'Processing queue');
    await page.setViewportSize({ width: 390, height: 844 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await captureWorkspace(page, `insights-${theme}-mobile`, 'Processing queue');
    expect(requests.every((request) => request.method === 'GET')).toBe(true);
  });
}

test('failed retrieval details distinguish wrong chunks, wrong pages and no answer', async ({ page }) => {
  await mockInsights(page);
  const queries = [
    { query: 'Wrong chunk fixture', expected_chunk_id: 'expected', expected_page: 1, top_chunk_id: 'other', top_page: 1, passed: false },
    { query: 'Wrong page fixture', expected_chunk_id: 'expected', expected_page: 1, top_chunk_id: 'expected', top_page: 2, passed: false },
    { query: 'No answer fixture', expected_chunk_id: 'expected', expected_page: 1, top_chunk_id: '', top_page: null, passed: false },
  ];
  await page.route('**/v1/jobs/insight-fixture/verification', (route) => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ...fixtureReport, status: 'red', attributions: [], retrieval: { status: 'red', queries } }) }));
  await connect(page);
  await page.getByRole('button', { name: 'View verification report' }).click();
  const findings = page.getByRole('region', { name: 'Verification details', exact: true }).locator('article');
  await expect(findings).toHaveCount(3);
  for (const finding of await findings.all()) {
    await expect(finding).toContainText('Needs attention');
    await expect(finding).toContainText('Expected chunk: expected · page: 1');
  }
  await expect(findings.nth(0)).toContainText('Wrong chunk fixture');
  await expect(findings.nth(0)).toContainText('Returned chunk: other · page: 1');
  await expect(findings.nth(1)).toContainText('Wrong page fixture');
  await expect(findings.nth(1)).toContainText('Returned chunk: expected · page: 2');
  await expect(findings.nth(2)).toContainText('No answer fixture');
  await expect(findings.nth(2)).toContainText('Returned chunk: No result · page: No result');
});

test('verification pages, findings and stages have explicit bounded pagination', async ({ page }) => {
  await mockInsights(page);
  await page.route('**/v1/jobs/insight-fixture?*', (route) => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ...fixtureJob, result: { ...fixtureJob.result, metrics: { ...fixtureJob.result.metrics, stages: Array.from({ length: 23 }, (_, index) => ({ name: `fixture_stage_${index}`, status: 'ok', duration_ms: index })) } } }) }));
  await page.route('**/v1/jobs/insight-fixture/verification', (route) => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ...fixtureReport, pages: Array.from({ length: 25 }, (_, index) => ({ page: index + 1, status: 'green', coverage: 1, flags: index === 0 ? Array.from({ length: 12 }, (_, flag) => `Fixture flag ${flag}`) : [] })), attributions: [], store: { status: 'red', checked: 25, issues: Array.from({ length: 25 }, (_, index) => ({ chunk_id: `fixture-${index}`, detail: `Fixture detail ${index}` })) } }) }));
  await connect(page);
  await expect(page.getByRole('table', { name: 'Stage measurements' }).getByRole('row')).toHaveCount(11);
  await page.getByRole('button', { name: 'Next stages', exact: true }).click();
  await expect(page.getByText('fixture stage 10', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'View verification report' }).click();
  await expect(page.getByRole('region', { name: 'Verification pages', exact: true }).locator('article')).toHaveCount(20);
  await expect(page.getByText('Fixture flag 10', { exact: true })).toHaveCount(0);
  await page.getByRole('button', { name: 'Show more flags for page 1', exact: true }).click();
  await expect(page.getByText('Fixture flag 11', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Next verification pages', exact: true }).click();
  await expect(page.getByText('Page results 21–25 of 25', { exact: true })).toBeVisible();
  await expect(page.getByRole('region', { name: 'Verification pages', exact: true }).locator('article')).toHaveCount(5);
  await expect(page.getByRole('region', { name: 'Verification details', exact: true }).locator('article')).toHaveCount(20);
  await page.getByRole('button', { name: 'Next verification details', exact: true }).click();
  await expect(page.getByText('Fixture detail 20', { exact: true })).toBeVisible();
  await expect(page.getByText('Details 21–25 of 25', { exact: true })).toBeVisible();
});

test('missing or malformed reports are clear without implying a verification pass', async ({ page }) => {
  await mockInsights(page);
  await connect(page);
  await page.getByRole('button', { name: /^fixture-without-report.pdf/ }).click();
  await expect(page.getByText('No timing measurements were returned for this job.', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'View verification report' }).click();
  await expect(page.getByText('No verification report is available for this job.', { exact: true })).toBeVisible();
  await expect(page.getByRole('region', { name: 'Verification results', exact: true })).toHaveCount(0);
  await page.route('**/v1/jobs/missing-fixture/verification', (route) => route.fulfill({ contentType: 'application/json', body: '{"status":[]}' }));
  await page.getByRole('button', { name: 'View verification report' }).click();
  await expect(page.getByRole('alert')).toContainText('invalid verification report');
});

test('late verification results cannot replace the selected job or return after logout', async ({ page }) => {
  await page.addInitScript(() => {
    const originalFetch = window.fetch.bind(window);
    const state = window as Window & { verificationResponses?: number };
    state.verificationResponses = 0;
    window.fetch = async (input, init) => {
      const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
      if (!url.includes('/verification')) return originalFetch(input, init);
      const response = await originalFetch(input, { ...init, signal: undefined });
      await response.clone().text();
      state.verificationResponses = (state.verificationResponses ?? 0) + 1;
      return response;
    };
  });
  await mockInsights(page);
  const releases: (() => void)[] = [];
  let requests = 0;
  await page.route('**/v1/jobs/insight-fixture/verification', async (route) => {
    requests++;
    await new Promise<void>((resolve) => releases.push(resolve));
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(fixtureReport) }).catch(() => {});
  });
  await connect(page);
  await page.getByRole('button', { name: 'View verification report' }).click();
  await expect.poll(() => requests).toBe(1);
  await page.getByRole('button', { name: /^fixture-without-report.pdf/ }).click();
  releases[0]();
  await expect.poll(() => page.evaluate(() => (window as Window & { verificationResponses?: number }).verificationResponses)).toBe(1);
  await expect(page.getByRole('heading', { name: 'fixture-without-report.pdf', exact: true })).toBeVisible();
  await expect(page.getByText('Mocked verification fixture; not a real PDF check.', { exact: true })).toHaveCount(0);
  await page.getByRole('button', { name: /^fixture-insights.pdf/ }).click();
  await page.getByRole('button', { name: 'View verification report' }).click();
  await expect.poll(() => requests).toBe(2);
  await page.getByRole('button', { name: 'Sign out' }).click();
  releases[1]();
  await expect.poll(() => page.evaluate(() => (window as Window & { verificationResponses?: number }).verificationResponses)).toBe(2);
  await expect(page.getByLabel('Worker access token')).toHaveValue('');
  await expect(page.getByRole('heading', { name: 'Job insights', exact: true })).toHaveCount(0);
  await expect(page.getByText('Mocked verification fixture; not a real PDF check.', { exact: true })).toHaveCount(0);
});

test('verification authorization rejection clears the active session', async ({ page }) => {
  await mockInsights(page);
  await page.route('**/v1/jobs/insight-fixture/verification', (route) => route.fulfill({ status: 401, contentType: 'application/json', body: '{"detail":"Expired token"}' }));
  await connect(page);
  await page.getByRole('button', { name: 'View verification report' }).click();
  await expect(page.getByLabel('Worker access token')).toHaveValue('');
  await expect(page.getByRole('alert')).toContainText('rejected this token');
  await expect(page.getByRole('heading', { name: 'Job insights', exact: true })).toHaveCount(0);
  expect(await page.evaluate(() => [localStorage.length, sessionStorage.length])).toEqual([0, 0]);
});
