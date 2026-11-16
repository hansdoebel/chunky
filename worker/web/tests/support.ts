import { expect, type Page } from '@playwright/test';
import { PNG } from 'pngjs';
import { mkdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';

export async function captureWorkspace(page: Page, name: string, heading: string | RegExp) {
  await expect(page.getByRole('heading', { name: heading, exact: true })).toBeVisible();
  await page.evaluate(() => document.fonts.ready);
  const directory = process.env.CHUNKY_WEB_SCREENSHOT_DIR ?? '/tmp';
  await mkdir(directory, { recursive: true });
  const path = join(directory, `chunky-web-${name}.png`);
  await page.screenshot({ path, fullPage: true, animations: 'disabled' });
  const png = PNG.sync.read(await readFile(path));
  let dark = 0; let light = 0; let opaque = 0;
  for (let i = 0; i < png.data.length; i += 4) { if (png.data[i + 3] > 200) opaque++; const luma = (png.data[i] + png.data[i + 1] + png.data[i + 2]) / 3; if (luma < 150) dark++; if (luma > 220) light++; }
  expect(opaque).toBeGreaterThan(png.width * png.height * .9);
  expect(dark).toBeGreaterThan(1000);
  expect(light).toBeGreaterThan(1000);
}
