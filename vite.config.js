import { defineConfig } from 'vite';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
const root = dirname(fileURLToPath(import.meta.url));
export default defineConfig({
  base: './',
  build: {
    outDir: 'dist', emptyOutDir: true,
    rollupOptions: { input: { index: resolve(root, 'index.html'), admin: resolve(root, 'admin.html') } }
  }
});
