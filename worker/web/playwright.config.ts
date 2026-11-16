import { defineConfig } from '@playwright/test';

const port = Number(process.env.CHUNKY_WEB_TEST_PORT ?? '4173');
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('CHUNKY_WEB_TEST_PORT must be an integer from 1024 to 65535');
const baseURL = `http://127.0.0.1:${port}`;

export default defineConfig({
  testDir: './tests', workers: 1, fullyParallel: false,
  use: { baseURL, browserName: 'chromium', colorScheme: 'light', viewport: { width: 1440, height: 1100 } },
  webServer: { command: `bun run preview --port ${port} --strictPort`, url: baseURL, reuseExistingServer: false },
});
