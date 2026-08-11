import { afterEach, describe, expect, it, vi } from 'vitest';
import type { LinuxShellBridge, SessionEntry, SessionListResult } from '../tauriBridge.js';
import type { ActivityRouteSelection } from '../routes.js';
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
    visibleCount: ACTIVITY_PAGE_SIZE,
    target: null,
    targetSession: null,
    targetLoading: false,
    targetError: null
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

  it('opens only an exact verified conversation returned by daemon search', async () => {
    const target: ActivityRouteSelection = {
      kind: 'conversation',
      conversationID: 'Codex:canonical-target'
    };
    const exact = {
      ...session('search-row'),
      sourceID: target.conversationID,
      sourceIDVerified: true
    };
    const sessionSearch = vi.fn(async () => ({ sessions: [exact], nextCursor: null }));
    useShellStore.setState({
      bridge: { sessionSearch } as unknown as LinuxShellBridge,
      fixtureMode: false
    });

    await useActivityStore.getState().openTarget(target);

    expect(sessionSearch).toHaveBeenCalledWith(target.conversationID);
    expect(useActivityStore.getState()).toMatchObject({
      target,
      targetSession: exact,
      targetLoading: false,
      targetError: null
    });
  });

  it('rejects fuzzy search rows and falls back to exact complete-history identity', async () => {
    const target: ActivityRouteSelection = {
      kind: 'conversation',
      conversationID: 'Claude Code:canonical-target'
    };
    const fuzzy = {
      ...session('fuzzy-title-match'),
      sourceID: target.conversationID,
      sourceIDVerified: false
    };
    const exact = {
      ...session('history-row'),
      sourceID: target.conversationID,
      sourceIDVerified: true,
      bodyMD: '# Complete history'
    };
    const sessionSearch = vi.fn(async () => ({ sessions: [fuzzy], nextCursor: null }));
    const sessionHistory = vi.fn(async () => ({
      sessions: [exact],
      nextCursor: null,
      complete: true,
      historyComplete: true,
      historyLimit: 500,
      totalCount: 1
    }));
    useShellStore.setState({
      bridge: { sessionSearch, sessionHistory } as unknown as LinuxShellBridge,
      fixtureMode: false
    });

    await useActivityStore.getState().openTarget(target);

    expect(sessionHistory).toHaveBeenCalledOnce();
    expect(useActivityStore.getState().targetSession).toEqual(exact);
    expect(useActivityStore.getState().targetError).toBeNull();
  });

  it('fails closed when absence cannot be proven from complete history', async () => {
    const target: ActivityRouteSelection = {
      kind: 'conversation',
      conversationID: 'Codex:missing'
    };
    useShellStore.setState({
      bridge: {
        sessionSearch: async () => ({ sessions: [], nextCursor: null }),
        sessionHistory: async () => ({
          sessions: [],
          nextCursor: 'older',
          complete: false,
          historyComplete: false,
          historyLimit: 500,
          totalCount: 600
        })
      } as unknown as LinuxShellBridge,
      fixtureMode: false
    });

    await useActivityStore.getState().openTarget(target);

    expect(useActivityStore.getState().targetSession).toBeNull();
    expect(useActivityStore.getState().targetError).toMatch(/could not prove complete history/i);
  });
});
