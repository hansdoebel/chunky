import { defineConfig } from 'vitest/config';
import { svelte } from '@sveltejs/vite-plugin-svelte';

export default defineConfig({
  plugins: [svelte()],
  build: { outDir: '../chunky_worker/web_dist', emptyOutDir: true },
  test: { include: ['src/**/*.test.ts'], environment: 'node' },
});
