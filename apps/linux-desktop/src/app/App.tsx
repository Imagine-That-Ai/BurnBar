import { useEffect } from 'react';
import { MeshBackdrop } from '../components/MeshBackdrop.js';
import { NavRail } from '../components/NavRail.js';
import { SurfaceRouter } from '../surfaces/SurfaceRouter.js';
import { useShellStore } from '../state/shellStore.js';

/**
 * Shell layout. A11y landmark contract (pinned by evidence harness):
 * `a.skip-link[href="#main"]` → `nav[aria-label="Primary"]` → `main#main`.
 */
export function App() {
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
    <div className="shell">
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
      <NavRail />
      <main className="shell-main" id="main" tabIndex={-1}>
        <MeshBackdrop />
        <SurfaceRouter route={route} />
      </main>
    </div>
  );
}
