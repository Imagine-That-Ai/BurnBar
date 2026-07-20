import { afterEach, describe, expect, it, vi } from 'vitest';
import { fixtureUsageInsights } from '../daemonFixture.js';
import type { LinuxShellBridge, UsageInsights } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';
import { useInsightsStore } from './insightsStore.js';

const realLoad = useInsightsStore.getState().load;

function reset(): void {
  useShellStore.setState({ bridge: null, fixtureMode: false, bridgeReady: true });
  useInsightsStore.setState({ data: null, loading: false, error: null, load: realLoad });
}

function bridgeFor(usageInsights: LinuxShellBridge['usageInsights']): LinuxShellBridge {
  return { usageInsights } as unknown as LinuxShellBridge;
}

afterEach(() => {
  vi.restoreAllMocks();
  reset();
});

describe('insights store refresh reliability', () => {
  it('keeps the last successful snapshot when a daemon refresh fails', async () => {
    const previous = fixtureUsageInsights();
    const usageInsights = vi.fn(async () => {
      throw new Error('daemon unavailable');
    });
    useShellStore.setState({ bridge: bridgeFor(usageInsights), fixtureMode: false });
    useInsightsStore.setState({ data: previous, loading: false, error: null });

    await useInsightsStore.getState().load();

    expect(useInsightsStore.getState().data).toBe(previous);
    expect(useInsightsStore.getState().loading).toBe(false);
    expect(useInsightsStore.getState().error).toBe('daemon unavailable');
  });

  it('ignores a late response from an older refresh request', async () => {
    let releaseFirst!: (value: UsageInsights) => void;
    let callCount = 0;
    const latest = {
      ...fixtureUsageInsights(),
      weekly: [{ label: 'latest', tokens: 99, costUsd: 1.99 }]
    };
    const usageInsights = vi.fn(() => {
      callCount += 1;
      if (callCount === 1) {
        return new Promise<UsageInsights>((resolve) => {
          releaseFirst = resolve;
        });
      }
      return Promise.resolve(latest);
    });
    useShellStore.setState({ bridge: bridgeFor(usageInsights), fixtureMode: false });

    const first = useInsightsStore.getState().load();
    const second = useInsightsStore.getState().load();
    await second;
    expect(useInsightsStore.getState().data).toBe(latest);

    releaseFirst(fixtureUsageInsights());
    await first;
    expect(useInsightsStore.getState().data).toBe(latest);
    expect(useInsightsStore.getState().error).toBeNull();
    expect(useInsightsStore.getState().loading).toBe(false);
  });
});
