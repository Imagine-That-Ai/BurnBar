import { useEffect, useState } from 'react';
import type { KernelId } from '@openburnbar/gl-engine/engine/types';
import { CommandPalette } from '../components/CommandPalette.js';
import { KernelBackdrop } from '../components/KernelBackdrop.js';
import { TopChrome } from '../components/TopChrome.js';
import { SurfaceRouter } from '../surfaces/SurfaceRouter.js';
import { readPersistedKernelId, writePersistedKernelId } from '../state/kernelPrefs.js';
import { useShellStore } from '../state/shellStore.js';

/**
 * Shell layout. A11y landmark contract (pinned by evidence harness):
 * `a.skip-link[href="#main"]` → `nav[aria-label="Primary"]` (tab strip) → `main#main`.
 */
export function App() {
  const [commandPaletteOpen, setCommandPaletteOpen] = useState(false);
  const [kernelId, setKernelId] = useState<KernelId>(() => readPersistedKernelId());
  const route = useShellStore((s) => s.route);
  const skin = useShellStore((s) => s.skin);
  const syncRouteFromHash = useShellStore((s) => s.syncRouteFromHash);

  useEffect(() => {
    window.addEventListener('hashchange', syncRouteFromHash);
    return () => window.removeEventListener('hashchange', syncRouteFromHash);
  }, [syncRouteFromHash]);

  useEffect(() => {
    document.documentElement.dataset.skin = skin;
    document.documentElement.style.setProperty('--ds-skin', skin);
  }, [skin]);

  return (
    <div
      className="shell"
      onKeyDown={(event) => {
        const isModK =
          (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k';
        if (!isModK) return;
        event.preventDefault();
        setCommandPaletteOpen(true);
      }}
    >
      <div className="shell-key-capture" tabIndex={0} aria-hidden="true" />
      <a
        className="skip-link"
        href="#main"
        onClick={(event) => {
          event.preventDefault();
          window.requestAnimationFrame(() => document.getElementById('main')?.focus());
        }}
      >
        Skip to content
      </a>
      <KernelBackdrop skin={skin} kernelId={kernelId} />
      <TopChrome
        onOpenCommandPalette={() => setCommandPaletteOpen(true)}
        kernelId={kernelId}
        onKernelChange={(id) => {
          writePersistedKernelId(id);
          setKernelId(id);
        }}
      />
      <CommandPalette open={commandPaletteOpen} onClose={() => setCommandPaletteOpen(false)} />
      <main className="shell-main shell-main--bleed" id="main" tabIndex={-1}>
        <SurfaceRouter route={route} />
      </main>
    </div>
  );
}