import { useEffect, useState } from 'react';
import type { KernelId } from '@openburnbar/gl-engine/engine/types';
import { CommandPalette } from '../components/CommandPalette.js';
import { KernelBackdrop } from '../components/KernelBackdrop.js';
import { TopChrome } from '../components/TopChrome.js';
import { SurfaceRouter } from '../surfaces/SurfaceRouter.js';
import { readPersistedKernelId, writePersistedKernelId } from '../state/kernelPrefs.js';
import { useShellStore } from '../state/shellStore.js';

function isComputerUsePanicHotkey(event: KeyboardEvent): boolean {
  const isPeriod = event.key === '.' || event.code === 'Period';
  return isPeriod && event.ctrlKey && event.altKey && (event.metaKey || event.shiftKey);
}

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
  const bridge = useShellStore((s) => s.bridge);

  useEffect(() => {
    window.addEventListener('hashchange', syncRouteFromHash);
    return () => window.removeEventListener('hashchange', syncRouteFromHash);
  }, [syncRouteFromHash]);

  // Window-level so the shortcut keeps working after the palette closes and
  // focus falls back to document.body (a React onKeyDown on .shell only sees
  // events dispatched from descendants). Same idiom as
  // usePrimarySectionShortcuts (ctrl/cmd+1..7).
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (!(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey) return;
      if (event.key.toLowerCase() !== 'k') return;
      event.preventDefault();
      setCommandPaletteOpen(true);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (!isComputerUsePanicHotkey(event)) return;
      if (!bridge?.computerUsePanicHalt) return;
      event.preventDefault();
      void bridge.computerUsePanicHalt({ sessionId: '*', source: 'hotkey' }).catch((error) => {
        console.error('computer_use_panic_hotkey_failed', error);
      });
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [bridge]);

  useEffect(() => {
    document.documentElement.dataset.skin = skin;
    document.documentElement.style.setProperty('--ds-skin', skin);
  }, [skin]);

  return (
    <div className="shell">
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
