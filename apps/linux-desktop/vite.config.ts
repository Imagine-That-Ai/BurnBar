import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath, URL } from 'node:url';

export default defineConfig(({ mode }) => {
  const productionWithoutFixtures = mode === 'production' && process.env.VITE_ENABLE_DAEMON_FIXTURE !== '1';
  // --mode windows: build the same UI for the WinUI WebView2 host (SharedUiHost).
  // @tauri-apps/api/* is aliased to the chrome.webview.postMessage shim; the C#
  // dispatcher in windows/app/OpenBurnBar.App/SharedUi serves the command surface.
  const windowsWebview = mode === 'windows';
  return {
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
      alias: [
        ...(windowsWebview
          ? [
              {
                find: '@tauri-apps/api/core',
                replacement: fileURLToPath(new URL('./src/shim/tauriWebviewShim.ts', import.meta.url))
              },
              {
                find: '@tauri-apps/api/event',
                replacement: fileURLToPath(new URL('./src/shim/tauriWebviewShim.ts', import.meta.url))
              }
            ]
          : []),
        ...(productionWithoutFixtures
          ? [
              {
                find: /(?:^|.*\/)daemonFixture\.js$/,
                replacement: fileURLToPath(new URL('./src/daemonFixture.production.ts', import.meta.url))
              }
            ]
          : []),
        {
          find: '@openburnbar/design-tokens/css/pensieve.css',
          replacement: fileURLToPath(new URL('../../packages/design-tokens/dist/css/pensieve.css', import.meta.url))
        },
        {
          find: '@openburnbar/design-tokens',
          replacement: fileURLToPath(new URL('../../packages/design-tokens', import.meta.url))
        },
        {
          find: '@openburnbar/entitlements',
          replacement: fileURLToPath(new URL('../../packages/entitlements/src/index.ts', import.meta.url))
        },
        {
          find: '@openburnbar/gl-engine',
          replacement: fileURLToPath(new URL('../../packages/gl-engine/src', import.meta.url))
        }
      ]
    },
    build: {
      target: 'es2021',
      minify: !process.env.TAURI_DEBUG ? 'esbuild' : false,
      sourcemap: !!process.env.TAURI_DEBUG,
      outDir: windowsWebview ? 'dist-windows' : 'dist'
    }
  };
});
