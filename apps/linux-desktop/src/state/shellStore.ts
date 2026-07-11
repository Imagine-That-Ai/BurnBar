import { useMemo } from 'react';
import { create } from 'zustand';
import {
  DAEMON_FIXTURE_AVAILABLE,
  fixtureDaemonHealth,
  isDaemonFixtureMode,
  setDaemonFixtureMode
} from '../daemonFixture.js';
import { buildDaemonStatusCopy, type DaemonStatusCopy } from '../daemonStatusCopy.js';
import { markAfterPaint, markStart } from '../perfMarks.js';
import { routeFromHash, type ShellRoute } from '../routes.js';
import { displayLinuxSocketPath } from '../shellPaths.js';
import {
  loadShellBridge,
  type DaemonSubscriptionResponse,
  type LinuxShellBridge
} from '../tauriBridge.js';
import type { DaemonHealth } from '../daemonClient.js';
import type { RuntimeCapabilityManifest } from '../runtimeCapabilities.js';
import type { DaemonSubscriptionStatus } from './daemonSubscriptionSupervisor.js';

export type ShellSkin = 'editorial' | 'aurora';

const SKIN_KEY = 'openburnbar.linux.skin.v1';

function readPersistedSkin(): ShellSkin {
  try {
    return localStorage.getItem(SKIN_KEY) === 'aurora' ? 'aurora' : 'editorial';
  } catch {
    return 'editorial';
  }
}

export type ShellState = {
  route: ShellRoute;
  health: DaemonHealth | null;
  healthError: string | null;
  healthBusy: boolean;
  trayDegraded: boolean;
  skin: ShellSkin;
  bridge: LinuxShellBridge | null;
  bridgeReady: boolean;
  dataRevision: number;
  lastDaemonEventAt: string | null;
  subscriptionRecoveredAfterRestart: boolean;
  subscriptionState: DaemonSubscriptionStatus['state'];
  subscriptionError: string | null;
  runtimeCapabilities: RuntimeCapabilityManifest | null;
  capabilityError: string | null;
  fixtureMode: boolean;
  setRoute(route: ShellRoute): void;
  syncRouteFromHash(): void;
  refreshHealth(): Promise<void>;
  toggleSkin(): void;
  setFixtureMode(enabled: boolean): void;
  recordDaemonSubscription(response: DaemonSubscriptionResponse): void;
  recordDaemonSubscriptionStatus(status: DaemonSubscriptionStatus): void;
  boot(): Promise<void>;
};

export const useShellStore = create<ShellState>()((set, get) => ({
  route: routeFromHash(typeof location === 'undefined' ? '' : location.hash),
  health: null,
  healthError: null,
  healthBusy: false,
  trayDegraded: false,
  skin: readPersistedSkin(),
  bridge: null,
  bridgeReady: false,
  dataRevision: 0,
  lastDaemonEventAt: null,
  subscriptionRecoveredAfterRestart: false,
  subscriptionState: 'stopped',
  subscriptionError: null,
  runtimeCapabilities: null,
  capabilityError: null,
  fixtureMode: false,

  setRoute(route) {
    markAfterPaint('route.navigation', `packaged-ui-route-after-paint:${route}`);
    location.hash = `#/${route}`;
    set({ route });
  },

  syncRouteFromHash() {
    const route = routeFromHash(location.hash);
    markAfterPaint('route.navigation', `packaged-ui-hash-route-after-paint:${route}`);
    set({ route });
  },

  async refreshHealth() {
    const end = markStart('ipc.health.roundtrip');
    const { fixtureMode, bridge } = get();
    if (fixtureMode) {
      set({ health: fixtureDaemonHealth(displayLinuxSocketPath()), healthError: null, healthBusy: false });
      end();
      return;
    }
    if (!bridge) {
      set({
        health: null,
        healthError: 'Packaged shell required for live daemon health (browser preview mode).',
        healthBusy: false
      });
      end();
      return;
    }
    set({ healthBusy: true });
    try {
      const health = await bridge.daemonHealth();
      set({
        health,
        healthError: health.ok ? null : health.error ?? 'Daemon reported not ready',
        healthBusy: false
      });
    } catch (e) {
      set({
        health: { ok: false },
        healthError: e instanceof Error ? e.message : 'Health probe failed',
        healthBusy: false
      });
    }
    end();
  },

  toggleSkin() {
    const skin: ShellSkin = get().skin === 'editorial' ? 'aurora' : 'editorial';
    try {
      localStorage.setItem(SKIN_KEY, skin);
    } catch {
      // Skin persistence is a convenience; the toggle still applies in-memory.
    }
    set({ skin });
  },

  setFixtureMode(enabled) {
    const next = enabled && DAEMON_FIXTURE_AVAILABLE;
    setDaemonFixtureMode(next);
    set({ fixtureMode: next });
    void get().refreshHealth();
  },

  recordDaemonSubscription(response) {
    set((state) => ({
      dataRevision: state.dataRevision + 1,
      lastDaemonEventAt: new Date().toISOString(),
      subscriptionRecoveredAfterRestart: response.recoveredAfterRestart
    }));
  },

  recordDaemonSubscriptionStatus(status) {
    set({
      subscriptionState: status.state,
      subscriptionError: status.error ?? null
    });
  },

  async boot() {
    set({ fixtureMode: isDaemonFixtureMode() });
    const bridge = await loadShellBridge();
    if (!bridge) {
      set({
        bridge: null,
        bridgeReady: true,
        runtimeCapabilities: null,
        capabilityError: null
      });
    } else {
      const [manifestResult, trayResult] = await Promise.allSettled([
        bridge.runtimeCapabilities(),
        bridge.trayDegraded()
      ]);
      set({
        bridge,
        bridgeReady: true,
        runtimeCapabilities:
          manifestResult.status === 'fulfilled' ? manifestResult.value : null,
        capabilityError:
          manifestResult.status === 'rejected'
            ? manifestResult.reason instanceof Error
              ? manifestResult.reason.message
              : 'Runtime capability probe failed.'
            : null,
        trayDegraded: trayResult.status === 'fulfilled' ? trayResult.value : true
      });
    }
    await get().refreshHealth();
  }
}));

export function selectDaemonStatusCopy(state: ShellState): DaemonStatusCopy {
  return buildDaemonStatusCopy({
    ok: state.health?.ok ?? false,
    daemonVersion: state.health?.daemonVersion,
    socketPath: state.health?.socketPath,
    fixtureMode: state.fixtureMode,
    bridgeAvailable: Boolean(state.bridge),
    healthError: state.healthError,
    daemonError: state.health?.error,
    displaySocketPath: displayLinuxSocketPath()
  });
}

/**
 * Memoized daemon status copy for components. Never pass
 * `selectDaemonStatusCopy` directly to `useShellStore` — it returns a fresh
 * object per snapshot and would loop the store subscription.
 */
export function useDaemonStatusCopy(): DaemonStatusCopy {
  const health = useShellStore((s) => s.health);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const healthError = useShellStore((s) => s.healthError);
  return useMemo(
    () =>
      buildDaemonStatusCopy({
        ok: health?.ok ?? false,
        daemonVersion: health?.daemonVersion,
        socketPath: health?.socketPath,
        fixtureMode,
        bridgeAvailable: Boolean(bridge),
        healthError,
        daemonError: health?.error,
        displaySocketPath: displayLinuxSocketPath()
      }),
    [health, fixtureMode, bridge, healthError]
  );
}
