import { useEffect, useState } from 'react';
import type { KernelId } from '@openburnbar/gl-engine/engine/types';
import { decodeNativeNotificationActionEvent } from '../tauriBridge.js';
import { CommandPalette } from '../components/CommandPalette.js';
import { KernelBackdrop } from '../components/KernelBackdrop.js';
import { TopChrome } from '../components/TopChrome.js';
import { SurfaceRouter } from '../surfaces/SurfaceRouter.js';
import { PetSurface } from '../surfaces/PetSurface.js';
import { ROUTES, type ShellRoute } from '../routes.js';
import { readPersistedKernelId, writePersistedKernelId } from '../state/kernelPrefs.js';
import { useShellStore } from '../state/shellStore.js';
import { isChatPopoutWindow } from '../surfaces/chat/chatWindow.js';
import {
  isNativePetSummonPayload,
  isPetCompanionWindow,
  openPetCompanionWindow,
  PET_SUMMON_EVENT
} from '../petCompanionWindow.js';

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
  const setRoute = useShellStore((s) => s.setRoute);
  const skin = useShellStore((s) => s.skin);
  const syncRouteFromHash = useShellStore((s) => s.syncRouteFromHash);
  const bridge = useShellStore((s) => s.bridge);
  const chatPopout = isChatPopoutWindow();
  const petCompanion = isPetCompanionWindow();

  useEffect(() => {
    window.addEventListener('hashchange', syncRouteFromHash);
    return () => window.removeEventListener('hashchange', syncRouteFromHash);
  }, [syncRouteFromHash]);

  // Native tray actions stay typed at the shell boundary: the Rust tray only
  // emits routes present in the installed route registry, and the renderer
  // still validates before changing the URL hash.
  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void) | undefined;
    void import('@tauri-apps/api/event')
      .then(async ({ listen }) => {
        const stop = await listen<string>('tray-route', (event) => {
          if (cancelled || !ROUTES.some((candidate) => candidate.id === event.payload)) return;
          setRoute(event.payload as ShellRoute);
        });
        if (cancelled) {
          stop();
          return;
        }
        unlisten = stop;

        // A secondary launch can forward a route before the renderer has
        // installed the native event listener. Drain every queued route after
        // registration; main.tsx already consumed the original launch route.
        while (!cancelled && bridge?.initialDeepLinkRoute) {
          const pendingRoute = await bridge.initialDeepLinkRoute();
          if (pendingRoute === null) break;
          if (ROUTES.some((candidate) => candidate.id === pendingRoute)) {
            setRoute(pendingRoute as ShellRoute);
          }
        }
      })
      .catch(() => {
        // Browser preview has no Tauri event bus; the normal URL/hash shell
        // remains the fallback there.
      });
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [bridge, setRoute]);

  // The Linux native shell registers this event only for a successful X11
  // global binding. Validate its fixed payload before routing or opening the
  // companion; Wayland and unknown sessions never emit it.
  useEffect(() => {
    if (petCompanion) return;
    let cancelled = false;
    let unlisten: (() => void) | undefined;
    void import('@tauri-apps/api/event')
      .then(async ({ listen }) => {
        const stop = await listen<unknown>(PET_SUMMON_EVENT, (event) => {
          if (cancelled || !isNativePetSummonPayload(event.payload)) return;
          setRoute('pet');
          void openPetCompanionWindow().catch(() => {
            // The route remains available as the contained fallback if the
            // native child cannot be created after registration.
          });
        });
        if (cancelled) stop();
        else unlisten = stop;
      })
      .catch(() => {
        // Browser preview has no Tauri event bus.
      });
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [petCompanion, setRoute]);

  // Native freedesktop actions carry a closed route/action pair. Decode again
  // at the renderer boundary so a malformed or stale host event cannot steer
  // navigation to an unregistered route.
  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void) | undefined;
    void import('@tauri-apps/api/event')
      .then(async ({ listen }) => {
        const stop = await listen<unknown>('notification-action', (event) => {
          if (cancelled) return;
          try {
            const action = decodeNativeNotificationActionEvent(event.payload);
            setRoute(action.route);
          } catch (error) {
            console.warn('linux_notification_action_rejected', error);
          }
        });
        if (cancelled) stop();
        else unlisten = stop;
      })
      .catch(() => {
        // Browser preview has no Tauri event bus.
      });
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [setRoute]);

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

  if (chatPopout) {
    return (
      <main className="chat-popout-shell" id="main" tabIndex={-1}>
        <SurfaceRouter route="chat" />
      </main>
    );
  }

  if (petCompanion) {
    return (
      <main className="pet-companion-shell" id="main" tabIndex={-1}>
        <PetSurface companionMode />
      </main>
    );
  }

  return (
    <>
      {/* Keep the fixed backdrop outside the shell stacking context. */}
      <KernelBackdrop skin={skin} kernelId={kernelId} />
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
    </>
  );
}
