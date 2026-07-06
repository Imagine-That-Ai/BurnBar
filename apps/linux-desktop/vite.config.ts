import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath, URL } from 'node:url';

export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  envPrefix: ['VITE_', 'TAURI_'],
  resolve: {
    alias: {
      '@openburnbar/entitlements': fileURLToPath(new URL('../../packages/entitlements/src/index.ts', import.meta.url)),
      '@openburnbar/gl-engine': fileURLToPath(new URL('../../packages/gl-engine/src', import.meta.url))
    }
  },
  build: {
    target: 'es2021',
    minify: !process.env.TAURI_DEBUG ? 'esbuild' : false,
    sourcemap: !!process.env.TAURI_DEBUG,
    outDir: 'dist'
  }
});
