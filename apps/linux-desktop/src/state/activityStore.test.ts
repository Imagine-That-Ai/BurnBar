import { afterEach, describe, expect, it, vi } from 'vitest';
import type { LinuxShellBridge, SessionEntry, SessionListResult } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';
import { ACTIVITY_PAGE_SIZE, useActivityStore } from './activityStore.js';

const session = (id: string): SessionEntry => ({
  id,
  provider: 'hermes',
  model: 'hermes',
  startedAt: '2026-07-21T12:00:00Z',
  tokens: 10,
  costUsd: 0.01,
  title: id
});

function resetStores(): void {
  useActivityStore.setState({
    sessions: [],
    loading: false,
    error: null,
    query: '',
    visibleCount: ACTIVITY_PAGE_SIZE
  });
  useShellStore.setState({ bridge: null, fixtureMode: false, bridgeReady: true, health: null });
}

describe('activity store request ordering', () => {
  afterEach(() => {
    vi.restoreAllMocks();
    resetStores();
  });

  it('keeps the newest response when an older daemon request resolves later', async () => {
    let resolveFirst!: (result: SessionListResult) => void;
    const firstResponse = new Promise<SessionListResult>((resolve) => {
      resolveFirst = resolve;
    });
    const newest = session('newest');
    const stale = session('stale');
    const sessionList = vi.fn()
      .mockImplementationOnce(() => firstResponse)
      .mockResolvedValueOnce({ sessions: [newest], nextCursor: null });
    const bridge = { sessionList } as unknown as LinuxShellBridge;
    useShellStore.setState({ bridge, fixtureMode: false });

    const firstLoad = useActivityStore.getState().load();
    const secondLoad = useActivityStore.getState().load();
    await secondLoad;

    expect(useActivityStore.getState().sessions).toEqual([newest]);
    expect(useActivityStore.getState().loading).toBe(false);

    resolveFirst({ sessions: [stale], nextCursor: null });
    await firstLoad;

    expect(useActivityStore.getState().sessions).toEqual([newest]);
    expect(useActivityStore.getState().error).toBeNull();
  });
});
