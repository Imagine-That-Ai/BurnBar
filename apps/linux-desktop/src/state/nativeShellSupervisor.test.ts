import { describe, expect, it, vi } from 'vitest';
import type { LinuxShellBridge, NativeDeepLink, ProviderCatalog, UsageSummary } from '../tauriBridge.js';
import { buildNativeTraySnapshot, NativeShellSupervisor } from './nativeShellSupervisor.js';

const summary: UsageSummary = {
  todayTokens: 12_345,
  todayCostUsd: 4.25,
  sevenDay: [],
  recentEvents: []
};
const catalog: ProviderCatalog = [
  {
    id: 'claude',
    label: 'Claude',
    accountLabel: 'Work',
    quotaBuckets: [{ id: 'primary', label: 'Primary', usedPct: 72, state: 'ok' }]
  },
  {
    id: 'codex',
    label: 'Codex',
    accountLabel: 'Personal',
    quotaBuckets: [{ id: 'primary', label: 'Primary', usedPct: 10, state: 'missing_credential' }]
  }
];

describe('buildNativeTraySnapshot', () => {
  it('derives bounded live cost, provider, and quota facts', () => {
    expect(buildNativeTraySnapshot(
      summary,
      catalog,
      { daemonOk: true, online: true, lastDaemonEventAt: '2026-07-10T12:00:00.000Z' },
      Date.parse('2026-07-10T12:00:30.000Z'),
      120_000
    )).toEqual({
      todayCostUsd: 4.25,
      todayTokens: 12_345,
      connectedProviders: 1,
      quotaFloorRemainingPercent: 28,
      freshness: 'live'
    });
  });

  it('reports stale, offline, and unavailable states without inventing freshness', () => {
    const base = { daemonOk: true, online: true, lastDaemonEventAt: '2026-07-10T12:00:00.000Z' };
    expect(buildNativeTraySnapshot(summary, catalog, base, Date.parse('2026-07-10T12:03:00.000Z'), 120_000).freshness).toBe('stale');
    expect(buildNativeTraySnapshot(summary, catalog, { ...base, online: false }, 0, 120_000).freshness).toBe('offline');
    expect(buildNativeTraySnapshot(summary, catalog, { ...base, daemonOk: false }, 0, 120_000).freshness).toBe('unavailable');
  });

  it('counts configured providers that do not expose quota buckets', () => {
    const withoutBuckets: ProviderCatalog = [{
      id: 'openai',
      label: 'OpenAI',
      accountLabel: 'Work',
      quotaBuckets: []
    }];
    expect(buildNativeTraySnapshot(
      summary,
      withoutBuckets,
      { daemonOk: true, online: true, lastDaemonEventAt: null },
      0,
      120_000
    ).connectedProviders).toBe(1);
  });
});

describe('NativeShellSupervisor', () => {
  it('installs the listener before draining pending links and refreshes the tray', async () => {
    const order: string[] = [];
    const handled: NativeDeepLink[] = [];
    const update = vi.fn(async () => {});
    const bridge = {
      onNativeDeepLink: vi.fn(async () => {
        order.push('listen');
        return () => order.push('unlisten');
      }),
      nativeShellReady: vi.fn(async () => {
        order.push('ready');
        return [{ route: 'account', action: 'membership-success' }] as NativeDeepLink[];
      }),
      nativeTrayUpdate: update,
      usageSummary: vi.fn(async () => summary),
      providerCatalog: vi.fn(async () => catalog)
    } as unknown as LinuxShellBridge;
    const supervisor = new NativeShellSupervisor(bridge, async (link) => {
      handled.push(link);
    }, {
      status: () => ({ daemonOk: true, online: true, lastDaemonEventAt: null })
    });
    await supervisor.start();
    expect(order.slice(0, 2)).toEqual(['listen', 'ready']);
    expect(handled).toEqual([{ route: 'account', action: 'membership-success' }]);
    expect(update).toHaveBeenCalledOnce();
    supervisor.stop();
    expect(order.at(-1)).toBe('unlisten');
  });

  it('coalesces overlapping refreshes and performs the pending refresh once', async () => {
    let release!: () => void;
    let calls = 0;
    const usageSummary = vi.fn(() => {
      calls += 1;
      if (calls > 1) return Promise.resolve(summary);
      return new Promise<UsageSummary>((resolve) => {
        release = () => resolve(summary);
      });
    });
    const update = vi.fn(async () => {});
    const bridge = {
      onNativeDeepLink: async () => () => {},
      nativeShellReady: async () => [],
      nativeTrayUpdate: update,
      usageSummary,
      providerCatalog: async () => catalog
    } as unknown as LinuxShellBridge;
    const supervisor = new NativeShellSupervisor(bridge, () => {});
    const start = supervisor.start();
    await Promise.resolve();
    const pending = supervisor.refresh();
    release();
    await start;
    await pending;
    expect(usageSummary).toHaveBeenCalledTimes(2);
    supervisor.stop();
  });

  it('replaces stale tray data with unavailable state when daemon refresh fails', async () => {
    const update = vi.fn(async () => {});
    const bridge = {
      onNativeDeepLink: async () => () => {},
      nativeShellReady: async () => [],
      nativeTrayUpdate: update,
      usageSummary: vi.fn(async () => { throw new Error('daemon down'); }),
      providerCatalog: vi.fn(async () => catalog)
    } as unknown as LinuxShellBridge;
    const onError = vi.fn();
    const supervisor = new NativeShellSupervisor(bridge, () => {}, {
      status: () => ({ daemonOk: false, online: true, lastDaemonEventAt: null }),
      onError
    });
    await supervisor.start();
    expect(onError).toHaveBeenCalled();
    expect(update).toHaveBeenCalledWith({
      todayCostUsd: 0,
      todayTokens: 0,
      connectedProviders: 0,
      freshness: 'unavailable'
    });
    supervisor.stop();
  });
});
