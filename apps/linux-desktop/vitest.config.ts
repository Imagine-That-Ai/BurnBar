import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@openburnbar/entitlements': new URL('../../packages/entitlements/src/index.ts', import.meta.url).pathname,
      '@openburnbar/gl-engine': new URL('../../packages/gl-engine/src', import.meta.url).pathname
    }
  },
  test: {
    environment: 'jsdom',
    include: ['src/**/*.test.ts', 'src/**/*.test.tsx']
  }
});
