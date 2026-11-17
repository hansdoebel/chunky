import { expect, test, type Page } from '@playwright/test';
import { captureWorkspace } from './support';

async function setup(page: Page) {
  const uploads: Record<string, unknown>[] = [];
  await page.route('**/v1/**', async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    const json = (body: unknown) => route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
    expect(request.headers().authorization).toBe('Bearer fixture-token');
    if (path === '/v1/ui/config') return json({ embedding_backend: 'ollama', embedding_model: 'fixture', qdrant_available: false, qdrant_label: 'Worker', vlm_models: ['standard', 'granite-docling-transformers'] });
    if (path === '/v1/models') return json({ embeddings: [] });
    if (path === '/v1/jobs' && request.method() === 'POST') {
      const body = request.postDataBuffer()!.toString();
      uploads.push(JSON.parse(body.split('name="settings"\r\n\r\n')[1].split('\r\n')[0]));
      return json({ id: 'fixture', status: 'queued' });
    }
    if (path === '/v1/jobs') return json({ jobs: [], total: 0, limit: 50, offset: 0 });
    return json({ id: 'fixture', filename: 'fixture.txt', status: 'succeeded', result: { chunks: [] } });
  });
  await page.goto('/');
  await page.getByLabel('Worker access token').fill('fixture-token');
  await page.getByRole('button', { name: 'Connect to worker' }).click();
  await page.getByRole('button', { name: 'Edit job settings' }).click();
  return uploads;
}
async function upload(page: Page) {
  await page.getByRole('button', { name: 'Back to queue' }).click();
  await page.getByLabel('Choose documents').setInputFiles({ name: 'fixture.txt', mimeType: 'text/plain', buffer: Buffer.from('Synthetic upload fixture') });
  await page.getByRole('button', { name: 'Add document to queue' }).click();
}

test('processing settings reach multipart uploads, VLM omits Standard overrides and logout resets drafts', async ({ page }) => {
  const uploads = await setup(page);
  await page.getByLabel('OCR for scanned PDFs').selectOption('on');
  await page.getByLabel('OCR language', { exact: true }).selectOption('de');
  await page.getByLabel('Table recognition', { exact: true }).selectOption('accurate');
  await page.getByLabel('Maximum pages').fill('3');
  await upload(page);
  await expect.poll(() => uploads.length).toBe(1);
  expect(uploads[0]).toMatchObject({ enable_ocr: true, ocr_language: 'de', table_mode: 'accurate', max_pages: 3 });
  await page.getByRole('button', { name: 'Edit job settings' }).click();
  await page.getByLabel('Document model', { exact: true }).selectOption('granite-docling-transformers');
  await expect(page.getByLabel('OCR for scanned PDFs')).toHaveCount(0);
  await upload(page);
  await expect.poll(() => uploads.length).toBe(2);
  expect(uploads[1]).toMatchObject({ vlm_model: 'granite-docling-transformers', max_pages: 3 });
  for (const field of ['enable_ocr', 'ocr_language', 'table_mode']) expect(uploads[1]).not.toHaveProperty(field);
  expect(await page.evaluate(() => [localStorage.length, sessionStorage.length])).toEqual([0, 0]);
  await page.getByRole('button', { name: 'Sign out' }).click();
  await page.getByLabel('Worker access token').fill('fixture-token');
  await page.getByRole('button', { name: 'Connect to worker' }).click();
  await page.getByRole('button', { name: 'Edit job settings' }).click();
  await expect(page.getByLabel('Maximum pages')).toHaveValue('');
  await expect(page.getByLabel('OCR for scanned PDFs')).toHaveValue('off');
  await expect(page.getByLabel('OCR language', { exact: true })).toBeDisabled();
});

test('invalid page limits show an error without uploading any document', async ({ page }) => {
  const uploads = await setup(page);
  await page.getByLabel('Maximum pages').fill('1.5');
  await upload(page);
  await expect(page.getByRole('alert')).toContainText('Maximum pages must be a positive whole number');
  expect(uploads).toHaveLength(0);
});

for (const colorScheme of ['light', 'dark'] as const) test(`processing controls are readable in ${colorScheme}`, async ({ page }) => {
  await page.emulateMedia({ colorScheme });
  await setup(page);
  await page.getByLabel('OCR for scanned PDFs').selectOption('on');
  await page.getByLabel('OCR language', { exact: true }).selectOption('fr');
  await page.getByLabel('Maximum pages').fill('10');
  await captureWorkspace(page, `processing-${colorScheme}`, 'Job settings');
  await page.setViewportSize({ width: 390, height: 844 });
  await captureWorkspace(page, `processing-${colorScheme}-mobile`, 'Job settings');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});
