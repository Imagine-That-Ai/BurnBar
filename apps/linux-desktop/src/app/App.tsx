import { useEffect, useState } from 'react';
import type { KernelId } from '@openburnbar/gl-engine/engine/types';
import { decodeNativeNotificationActionEvent } from '../tauriBridge.js';
import { CommandPalette } from '../components/CommandPalette.js';
import { KernelBackdrop } from '../components/KernelBackdrop.js';
import { TopChrome } from '../components/TopChrome.js';
import { SurfaceRouter } from '../surfaces/SurfaceRouter.js';
import { PetSurface } from '../surfaces/PetSurface.js';
import { ROUTES, shellDestinationFromNative, type ShellRoute } from '../routes.js';
import { readPersistedKernelId, writePersistedKernelId } from '../state/kernelPrefs.js';
import { useShellStore } from '../state/shellStore.js';
import type { NativeShortcutStatus } from '../tauriBridge.js';
import { isChatPopoutWindow } from '../surfaces/chat/chatWindow.js';
import {
  isNativePetSummonPayload,
  isPetCompanionWindow,
  openPetCompanionWindow,
  PET_SUMMON_EVENT
} from '../petCompanionWindow.js';
import { CHAT_COMPOSER_FOCUS_EVENT } from '../surfaces/chat/chatComposerEvents.js';

function isComputerUsePanicHotkey(event: KeyboardEvent): boolean {
  const isPeriod = event.key === '.' || event.code === 'Period';
  return isPeriod && event.ctrlKey && event.altKey && (event.metaKey || event.shiftKey);
}

function nativeShortcutBindingNeedsFallback(
  status: NativeShortcutStatus | null | undefined,
  bindingID: string
): boolean {
  // Wait for the packaged shell's status query before adding a renderer
  // fallback. This prevents a healthy X11 grab from opening the pet twice.
  if (status === undefined) return false;
  if (status === null) return true;
  if (!status.bindings) return !status.registered;
  const binding = status.bindings.find((candidate) => candidate.id === bindingID);
  // A healthy aggregate result is not enough when one required binding is
  // absent from the native report. Treat that binding as degraded so the
  // focused-window fallback remains available for the missing command.
  return binding ? binding.state !== 'registered' : true;
}

function isLinuxNativeRouteShortcut(event: KeyboardEvent, key: string): boolean {
  const physicalKey = `Key${key.toUpperCase()}`;
  return (
    (event.key.toLowerCase() === key || event.code === physicalKey) &&
    event.ctrlKey &&
    event.altKey &&
    event.metaKey &&
    !event.shiftKey &&
    !event.repeat
  );
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
  const [nativeShortcutStatus, setNativeShortcutStatus] = useState<NativeShortcutStatus | null | undefined>(undefined);

  useEffect(() => {
    let cancelled = false;
    setNativeShortcutStatus(undefined);
    if (!bridge?.nativeShortcutStatus) {
      setNativeShortcutStatus(null);
      return () => {
        cancelled = true;
      };
    }
    void bridge.nativeShortcutStatus()
      .then((status) => {
        if (!cancelled) setNativeShortcutStatus(status);
      })
      .catch(() => {
        if (!cancelled) setNativeShortcutStatus(null);
      });
    return () => {
      cancelled = true;
    };
  }, [bridge]);

  useEffect(() => {
    const onHashChange = () => syncRouteFromHash();
    window.addEventListener('hashchange', onHashChange);
    return () => window.removeEventListener('hashchange', onHashChange);
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
          if (cancelled) return;
          const destination = shellDestinationFromNative(event.payload);
          if (!destination) return;
          location.hash = destination.hash;
          syncRouteFromHash();
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
          const destination = shellDestinationFromNative(pendingRoute);
          if (!destination) continue;
          location.hash = destination.hash;
          syncRouteFromHash();
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
  }, [bridge, syncRouteFromHash]);

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
    const handleNotificationAction = (payload: unknown) => {
      if (cancelled) return;
      try {
        const action = decodeNativeNotificationActionEvent(payload);
        setRoute(action.route);
        if (action.action === 'reply' && action.route === 'chat') {
          // Let React mount the Chat route before asking its composer to
          // focus. The event contains only the validated notification ID;
          // no notification body or untrusted text crosses this boundary.
          window.setTimeout(() => {
            if (cancelled) return;
            window.dispatchEvent(new CustomEvent(CHAT_COMPOSER_FOCUS_EVENT, {
              detail: { notificationId: action.notificationId }
            }));
          }, 0);
        }
      } catch (error) {
        console.warn('linux_notification_action_rejected', error);
      }
    };
    void import('@tauri-apps/api/event')
      .then(async ({ listen }) => {
        const stop = await listen<unknown>('notification-action', (event) => {
          handleNotificationAction(event.payload);
        });
        if (cancelled) stop();
        else {
          unlisten = stop;
          // Native actions received during cold start are held until this
          // listener is installed, preserving Reply intent instead of only
          // forwarding the route.
          if (bridge?.initialNotificationActions) {
            try {
              const pending = await bridge.initialNotificationActions();
              pending.forEach(handleNotificationAction);
            } catch (error) {
              console.warn('linux_notification_action_queue_unavailable', error);
            }
          }
        }
      })
      .catch(() => {
        // Browser preview has no Tauri event bus.
      });
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [bridge, setRoute]);

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

  // X11 grabs run outside the renderer. Wayland and hosts with a conflicting
  // native binding cannot provide that global grab, so preserve the same
  // commands while the OpenBurnBar window is focused. The status-aware gate
  // avoids duplicate route/window actions when the native binding is healthy.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (isLinuxNativeRouteShortcut(event, 'o')) {
        if (!nativeShortcutBindingNeedsFallback(nativeShortcutStatus, 'open-dashboard')) return;
        event.preventDefault();
        setRoute('overview');
        return;
      }
      if (!isLinuxNativeRouteShortcut(event, 'p')) return;
      if (!nativeShortcutBindingNeedsFallback(nativeShortcutStatus, 'summon-pet')) return;
      event.preventDefault();
      setRoute('pet');
      void openPetCompanionWindow().catch(() => {
        // The contained route remains available when the native child is not.
      });
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [nativeShortcutStatus, setRoute]);

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
