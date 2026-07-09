import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath, URL } from 'node:url';

export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    // Aliased workspace sources (@openburnbar/entitlements, @openburnbar/gl-engine)
    // live outside the app root; allow only the packages tree, not the whole repo.
    fs: { allow: ['.', '../../packages'] }
  },
  envPrefix: ['VITE_', 'TAURI_'],
  resolve: {
    alias: {
      '@openburnbar/design-tokens/css/pensieve.css': fileURLToPath(
        new URL('../../packages/design-tokens/dist/css/pensieve.css', import.meta.url)
      ),
      '@openburnbar/design-tokens': fileURLToPath(new URL('../../packages/design-tokens', import.meta.url)),
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
