import { useMemo } from 'react';
import { create } from 'zustand';
import {
  DAEMON_FIXTURE_AVAILABLE,
  fixtureDaemonHealth,
  isDaemonFixtureMode,
  setDaemonFixtureMode
} from '../daemonFixture.js';
import { buildDaemonStatusCopy, type DaemonStatusCopy } from '../daemonStatusCopy.js';
import { markStart, recordPerfSample } from '../perfMarks.js';
import { routeFromHash, type ShellRoute } from '../routes.js';
import { displayLinuxSocketPath } from '../shellPaths.js';
import { loadShellBridge, type LinuxShellBridge } from '../tauriBridge.js';
import type { DaemonHealth } from '../daemonClient.js';

export type ShellSkin = 'editorial' | 'aurora';

const SKIN_KEY = 'openburnbar.linux.skin.v1';

function readPersistedSkin(): ShellSkin {
  try {
    return localStorage.getItem(SKIN_KEY) === 'aurora' ? 'aurora' : 'editorial';
  } catch {
    return 'editorial';
  }
}

/**
 * Required perf operations measured once through the packaged Tauri bridge.
 * Names are pinned by budgets/linux-desktop.perf.json and
 * scripts/linux-port/run-perf-budget.mjs — never rename without updating both.
 */
export const REQUIRED_PERF_OPERATIONS: { name: string; source: string }[] = [
  { name: 'chat.firstToken.progress', source: 'packaged-startup-chat-hermes-daemon-measurement' },
  { name: 'db.migration.open.query', source: 'packaged-startup-db-daemon-measurement' },
  { name: 'parser.incremental.run', source: 'packaged-startup-parser-daemon-measurement' },
  { name: 'memory.search', source: 'packaged-startup-memory-daemon-measurement' },
  { name: 'media.control.stage', source: 'packaged-startup-media-control-daemon-measurement' }
];

export function routeSurfaceMetric(route: ShellRoute): { name: string; source: string } | null {
  switch (route) {
    case 'chat':
      return { name: 'chat.firstToken.progress', source: 'packaged-chat-route-daemon-measurement' };
    case 'database':
      return { name: 'db.migration.open.query', source: 'packaged-database-route-daemon-measurement' };
    case 'activity':
      return { name: 'parser.incremental.run', source: 'packaged-parser-route-daemon-measurement' };
    case 'memory':
      return { name: 'memory.search', source: 'packaged-memory-route-daemon-measurement' };
    case 'support':
      return { name: 'media.control.stage', source: 'packaged-support-route-daemon-measurement' };
    default:
      return null;
  }
}

const measuredRouteOperations = new Set<string>();

export type ShellState = {
  route: ShellRoute;
  health: DaemonHealth | null;
  healthError: string | null;
  healthBusy: boolean;
  trayDegraded: boolean;
  skin: ShellSkin;
  bridge: LinuxShellBridge | null;
  bridgeReady: boolean;
  fixtureMode: boolean;
  setRoute(route: ShellRoute): void;
  syncRouteFromHash(): void;
  refreshHealth(): Promise<void>;
  toggleSkin(): void;
  setFixtureMode(enabled: boolean): void;
  boot(): Promise<void>;
};

async function measurePerfOperation(
  bridge: LinuxShellBridge | null,
  name: string,
  source: string
): Promise<void> {
  if (!bridge || measuredRouteOperations.has(name)) return;
  measuredRouteOperations.add(name);
  const result = await bridge.measurePerfOperation(name);
  if (!result.ok) {
    recordPerfSample(name, result.ms, `${source};${result.source};blocked=${result.detail ?? 'unknown'}`);
    return;
  }
  recordPerfSample(name, result.ms, `${source};${result.source}`);
}

export const useShellStore = create<ShellState>()((set, get) => ({
  route: routeFromHash(typeof location === 'undefined' ? '' : location.hash),
  health: null,
  healthError: null,
  healthBusy: false,
  trayDegraded: false,
  skin: readPersistedSkin(),
  bridge: null,
  bridgeReady: false,
  fixtureMode: false,

  setRoute(route) {
    const end = markStart('route.navigation', `packaged-ui-route:${route}`);
    location.hash = `#/${route}`;
    set({ route });
    end();
    const metric = routeSurfaceMetric(route);
    if (metric) void measurePerfOperation(get().bridge, metric.name, metric.source);
  },

  syncRouteFromHash() {
    const route = routeFromHash(location.hash);
    set({ route });
    const metric = routeSurfaceMetric(route);
    if (metric) void measurePerfOperation(get().bridge, metric.name, metric.source);
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

  async boot() {
    set({ fixtureMode: isDaemonFixtureMode() });
    const bridge = await loadShellBridge();
    set({ bridge, bridgeReady: true });
    if (bridge) {
      const trayDegraded = await bridge.trayDegraded();
      set({ trayDegraded });
    }
    await get().refreshHealth();
    for (const operation of REQUIRED_PERF_OPERATIONS) {
      await measurePerfOperation(get().bridge, operation.name, operation.source);
    }
    const metric = routeSurfaceMetric(get().route);
    if (metric) void measurePerfOperation(get().bridge, metric.name, metric.source);
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
