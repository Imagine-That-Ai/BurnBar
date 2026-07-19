// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fixtureSessionList } from '../../daemonFixture.js';
import { bridgeStubDefaults } from '../../testing/bridgeStubs.js';
import type { LinuxShellBridge, SessionListResult, SessionReplayResult } from '../../tauriBridge.js';
import { ACTIVITY_PAGE_SIZE, useActivityStore } from '../../state/activityStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { availableRuntimeCapabilities } from '../../testing/bridgeStubs.js';
import { ActivitySurface } from './ActivitySurface.js';
import { formatCostUsd, formatTokens } from './sessionFormat.js';

function resetActivity(): void {
  useActivityStore.setState({
    sessions: [],
    loading: false,
    error: null,
    query: '',
    visibleCount: ACTIVITY_PAGE_SIZE
  });
}

function resetShell(): void {
  useShellStore.setState({
    fixtureMode: false,
    bridge: null,
    bridgeReady: true,
    health: null,
    healthError: null
  });
}

function mockBridge(handlers: {
  sessionList?: () => Promise<SessionListResult>;
  sessionSearch?: (query: string) => Promise<SessionListResult>;
  sessionReplay?: (sessionID: string) => Promise<SessionReplayResult>;
  sessionResume?: (sessionID: string) => Promise<SessionReplayResult>;
}): LinuxShellBridge {
  const emptyList = async (): Promise<SessionListResult> => ({ sessions: [], nextCursor: null });
  const bridge: LinuxShellBridge = {
    ...bridgeStubDefaults,
    daemonHealth: async () => ({ ok: true }),
    runtimeCapabilities: availableRuntimeCapabilities,
    openDashboard: async () => {},
    quitApp: async () => {},
    trayDegraded: async () => false,
    measurePerfOperation: async (name) => ({ name, ok: true, ms: 1, source: 'test' }),
    usageSummary: async () => ({
      todayTokens: 0,
      todayCostUsd: 0,
      sevenDay: [0, 0, 0, 0, 0, 0, 0],
      recentEvents: []
    }),
    providerCatalog: async () => [],
    sessionList: handlers.sessionList ?? emptyList,
    sessionSearch: handlers.sessionSearch ?? emptyList,
    sessionReplay: handlers.sessionReplay,
    sessionResume: handlers.sessionResume,
    usageInsights: async () => ({ weekly: [], providerMix: [], modelMix: [], cacheHitRatePct: 0 }),
    missionList: async () => ({ missions: [], pendingApprovals: [] }),
    missionApprovalDecision: async () => {},
    missionCreate: async () => null,
    configSnapshot: async () => ({
      paths: {
        supportDir: '/tmp',
        socketPath: '/tmp/sock',
        configDir: '/tmp/cfg',
        providerLogPaths: []
      },
      secretServiceStatus: 'unavailable',
      telemetryEnabled: false,
      privacyOptIn: false
    }),
    dbStatus: async () => ({ sqlcipherOk: true, migrationVersion: 0, sizeBytes: 0, walMode: true }),
    projectList: async () => [],
    memoryBoundaries: async () => [],
    memoryReviewInbox: async () => ({ items: [], auditEvents: [] }),
    memoryReviewDecision: async () => {},
    databaseWorkspaceStatus: async () => ({
      sourceLabel: 'test',
      projectID: 'test',
      artifactCount: 0,
      chunkCount: 0,
      symbolCount: 0,
      referenceCount: 0,
      callEdgeCount: 0,
      rejectedCount: 0,
      storageByteCount: 0,
      storageBudgetBytes: 0,
      storageWithinBudget: true,
      productionReady: false,
      productionReadinessReasons: [],
      parserAvailable: false,
      databaseEncrypted: false,
      hostedCodeToolsEnabled: false,
      semanticAvailable: false,
      files: [],
      languages: [],
      diagnostics: [],
      degradedReasons: []
    }),
    databaseIndexProject: async () => ({ projectID: 'test', projectRoot: '/tmp', indexedFiles: 0 }),
    databaseWatchProject: async () => ({ projectID: 'test', projectRoot: '/tmp', indexedFiles: 0 }),
    accountStatus: async () => ({ signedIn: false, trustClass: 'linux-lower-trust', syncState: 'local-only' }),
    appVersionInfo: async () => ({
      shellVersion: '0',
      daemonVersion: '0',
      packageChannel: 'unknown',
      updateCheck: 'skipped'
    }),
    exportDiagnostics: async () => ({ path: '/tmp/diag.zip' }),
    sessionEnv: async () => ({}),
    gatewayProbe: async () => false,
    gatewayChatStream: async () => undefined,
    gatewayChatCancel: async () => undefined,
    mediaStatus: async () => ({ capabilityAvailable: false, pairedDevices: [] }),
    integrationsStatus: async () => ({ integrations: [] })
  };
  return bridge;
}

describe('ActivitySurface', () => {
  beforeEach(() => {
    resetShell();
    resetActivity();
  });
  afterEach(() => {
    cleanup();
    vi.useRealTimers();
  });

  it('shows offline notice without bridge or fixture mode', () => {
    render(<ActivitySurface />);
    expect(screen.getByRole('status')).toBeTruthy();
    expect(screen.getByText(/packaged shell/i)).toBeTruthy();
  });

  it('shows loading skeleton while first fetch is in flight', async () => {
    let resolveList: (v: SessionListResult) => void;
    const pending = new Promise<SessionListResult>((r) => {
      resolveList = r;
    });
    useShellStore.setState({ bridge: mockBridge({ sessionList: () => pending }) });
    render(<ActivitySurface />);
    const loadPromise = useActivityStore.getState().load();
    await act(async () => {
      await Promise.resolve();
    });
    expect(screen.getByLabelText(/loading sessions/i)).toBeTruthy();
    resolveList!({ sessions: [], nextCursor: null });
    await act(async () => {
      await loadPromise;
    });
  });

  it('shows populated fixture sessions with token and cost formatting', async () => {
    useShellStore.setState({ fixtureMode: true });
    render(<ActivitySurface />);
    await act(async () => {
      await useActivityStore.getState().load();
    });
    expect(screen.getByText(/fixture transcript/i)).toBeTruthy();
    const rows = screen.getAllByRole('listitem');
    expect(rows.length).toBeGreaterThan(0);
    expect(rows.length).toBeLessThanOrEqual(ACTIVITY_PAGE_SIZE);
    const first = fixtureSessionList().sessions[0];
    expect(screen.getByText(first.title)).toBeTruthy();
    expect(screen.getByText(formatCostUsd(first.costUsd))).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Tokens' }));
    expect(screen.getByText(formatTokens(first.tokens))).toBeTruthy();
  });

  it('exports every currently loaded row in the selected format', async () => {
    const loaded = fixtureSessionList().sessions.slice(0, 2);
    const sessionList = vi.fn(async () => ({ sessions: loaded, nextCursor: 'older-page' }));
    useShellStore.setState({
      bridge: mockBridge({ sessionList })
    });
    render(<ActivitySurface />);
    await act(async () => {
      await useActivityStore.getState().load();
    });
    const sessionListCallsBeforeExport = sessionList.mock.calls.length;
    expect(sessionListCallsBeforeExport).toBeGreaterThan(0);

    expect(screen.getByText(/Export includes 2 currently loaded rows/i)).toBeTruthy();
    fireEvent.change(screen.getByRole('combobox', { name: 'Activity export format' }), {
      target: { value: 'markdown' }
    });
    const exportButton = screen.getByRole('button', { name: 'Export activity as Markdown' });
    expect((exportButton as HTMLButtonElement).disabled).toBe(false);

    const url = globalThis.URL;
    const originalCreateObjectURL = url.createObjectURL;
    const originalRevokeObjectURL = url.revokeObjectURL;
    const createObjectURL = vi.fn(() => 'blob:activity-export');
    const revokeObjectURL = vi.fn();
    Object.defineProperty(url, 'createObjectURL', {
      configurable: true,
      writable: true,
      value: createObjectURL
    });
    Object.defineProperty(url, 'revokeObjectURL', {
      configurable: true,
      writable: true,
      value: revokeObjectURL
    });
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => undefined);
    try {
      fireEvent.click(exportButton);
      expect(screen.getByRole('status').textContent).toContain(
        'Exported openburnbar-activity-export.md (2 loaded rows)'
      );
      expect(createObjectURL).toHaveBeenCalledOnce();
      expect(click).toHaveBeenCalled();
      expect(sessionList).toHaveBeenCalledTimes(sessionListCallsBeforeExport);
    } finally {
      click.mockRestore();
      if (originalCreateObjectURL) {
        Object.defineProperty(url, 'createObjectURL', {
          configurable: true,
          writable: true,
          value: originalCreateObjectURL
        });
      } else {
        delete (url as { createObjectURL?: unknown }).createObjectURL;
      }
      if (originalRevokeObjectURL) {
        Object.defineProperty(url, 'revokeObjectURL', {
          configurable: true,
          writable: true,
          value: originalRevokeObjectURL
        });
      } else {
        delete (url as { revokeObjectURL?: unknown }).revokeObjectURL;
      }
    }
  });

  it('shows a typed unavailable state instead of exporting a paged activity snapshot', async () => {
    const sessionList = vi.fn(async () => ({
      sessions: fixtureSessionList().sessions.slice(0, 1),
      nextCursor: 'older-page',
      complete: false
    }));
    useShellStore.setState({
      bridge: mockBridge({
        sessionList,
        sessionReplay: async () => ({ kind: 'native', briefingTruncated: false, briefingMD: 'body' })
      })
    });
    render(<ActivitySurface />);
    await act(async () => {
      await useActivityStore.getState().load();
    });

    const exportButton = screen.getByRole('button', { name: 'Export full history' });
    expect((exportButton as HTMLButtonElement).disabled).toBe(false);
    fireEvent.click(exportButton);
    await act(async () => {
      await Promise.resolve();
    });
    expect(screen.getByText(/Full history export unavailable/i).textContent).toMatch(/paged or incomplete/i);
    expect(sessionList).toHaveBeenCalled();
  });

  it('shows empty state when daemon returns no sessions', async () => {
    useShellStore.setState({
      bridge: mockBridge({ sessionList: async () => ({ sessions: [], nextCursor: null }) })
    });
    render(<ActivitySurface />);
    await act(async () => {
      await useActivityStore.getState().load();
    });
    expect(screen.getByText(/No sessions ingested/i)).toBeTruthy();
  });

  it('shows error banner with retry', async () => {
    useShellStore.setState({
      bridge: mockBridge({
        sessionList: async () => {
          throw new Error('daemon down');
        }
      })
    });
    render(<ActivitySurface />);
    await act(async () => {
      await useActivityStore.getState().load();
    });
    expect(screen.getByRole('alert')).toBeTruthy();
    expect(screen.getByText('daemon down')).toBeTruthy();
    expect(screen.getByRole('button', { name: /retry/i })).toBeTruthy();
  });

  it('shows search-empty when query matches nothing', async () => {
    useShellStore.setState({ fixtureMode: true });
    render(<ActivitySurface />);
    await act(async () => {
      await useActivityStore.getState().search('zzznomatchqueryzzz');
    });
    expect(screen.getByText(/No sessions match/i)).toBeTruthy();
  });

  it('debounces search by 300ms', async () => {
    vi.useFakeTimers();
    const searchSpy = vi.fn(async (_q: string) => ({ sessions: [], nextCursor: null }));
    useShellStore.setState({
      bridge: mockBridge({ sessionSearch: searchSpy })
    });
    render(<ActivitySurface />);
    const input = screen.getByRole('searchbox');
    fireEvent.change(input, { target: { value: 'claude' } });
    expect(searchSpy).not.toHaveBeenCalled();
    await act(async () => {
      vi.advanceTimersByTime(299);
    });
    expect(searchSpy).not.toHaveBeenCalled();
    await act(async () => {
      vi.advanceTimersByTime(1);
    });
    expect(searchSpy).toHaveBeenCalledWith('claude');
  });

  it('clears search on Escape', async () => {
    useShellStore.setState({ fixtureMode: true });
    render(<ActivitySurface />);
    const input = screen.getByRole('searchbox');
    fireEvent.change(input, { target: { value: 'bug' } });
    await act(async () => {
      await useActivityStore.getState().search('bug');
    });
    fireEvent.keyDown(input, { key: 'Escape' });
    await act(async () => {
      await Promise.resolve();
    });
    expect((input as HTMLInputElement).value).toBe('');
    expect(useActivityStore.getState().query).toBe('');
  });

  it('paginates with load more (page size 50)', async () => {
    const many = Array.from({ length: 55 }, (_, i) => ({
      id: `s-${i}`,
      provider: 'openai',
      model: 'gpt-5',
      startedAt: new Date().toISOString(),
      tokens: 1000 + i,
      costUsd: 0.1,
      title: `Session ${i}`
    }));
    useShellStore.setState({
      bridge: mockBridge({ sessionList: async () => ({ sessions: many, nextCursor: null }) })
    });
    render(<ActivitySurface />);
    await act(async () => {
      await useActivityStore.getState().load();
    });
    let rows = screen.getAllByRole('listitem');
    expect(rows.length).toBe(ACTIVITY_PAGE_SIZE);
    fireEvent.click(screen.getByRole('button', { name: /load more/i }));
    rows = screen.getAllByRole('listitem');
    expect(rows.length).toBe(55);
  });

  it('toggles session disclosure with keyboard-operable button', async () => {
    useShellStore.setState({ fixtureMode: true });
    render(<ActivitySurface />);
    await act(async () => {
      await useActivityStore.getState().load();
    });
    const toggle = screen.getAllByRole('button', { name: /show details/i })[0];
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
    fireEvent.click(toggle);
    expect(toggle.getAttribute('aria-expanded')).toBe('true');
    expect(toggle.getAttribute('aria-controls')).toBeTruthy();
    const region = document.getElementById(toggle.getAttribute('aria-controls')!);
    expect(region?.getAttribute('role')).toBe('region');
    expect(within(region as HTMLElement).getByText(/Session id/i)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /hide details/i }));
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
  });

  it('loads persisted body and requests daemon-backed resume without synthesizing content', async () => {
    const indexedSession = { ...fixtureSessionList().sessions[0]!, sourceID: 'Codex:canonical-session' };
    const replay = vi.fn(async (_sessionID: string): Promise<SessionReplayResult> => ({
      kind: 'ported',
      briefingMD: '# Persisted session\n\nOriginal body',
      briefingTruncated: false
    }));
    const resume = vi.fn(async (_sessionID: string): Promise<SessionReplayResult> => ({
      kind: 'spawned',
      briefingTruncated: false,
      pid: 42
    }));
    useShellStore.setState({
      bridge: mockBridge({
        sessionList: async () => ({ sessions: [indexedSession], nextCursor: null }),
        sessionReplay: replay,
        sessionResume: resume
      })
    });
    render(<ActivitySurface />);
    await act(async () => {
      await useActivityStore.getState().load();
    });

    fireEvent.click(screen.getAllByRole('button', { name: /show details/i })[0]!);
    fireEvent.click(screen.getByRole('button', { name: 'Load session body' }));
    await act(async () => {
      await Promise.resolve();
    });
    expect(replay).toHaveBeenCalledWith('Codex:canonical-session');
    expect(screen.getByLabelText('Persisted session body').textContent).toContain('# Persisted session');

    fireEvent.click(screen.getByRole('button', { name: 'Resume session' }));
    await act(async () => {
      await Promise.resolve();
    });
    expect(resume).toHaveBeenCalledWith('Codex:canonical-session');
    expect(screen.getByRole('status').textContent).toContain('process 42');
  });

  it('fails closed for rows without a verified source identity', async () => {
    const indexedSession = { ...fixtureSessionList().sessions[0]!, sourceID: undefined };
    const replay = vi.fn(async (_sessionID: string): Promise<SessionReplayResult> => ({
      kind: 'ported',
      briefingMD: 'Should not be requested',
      briefingTruncated: false
    }));
    const resume = vi.fn(async (_sessionID: string): Promise<SessionReplayResult> => ({
      kind: 'spawned',
      briefingTruncated: false,
      pid: 42
    }));
    useShellStore.setState({
      bridge: mockBridge({
        sessionList: async () => ({ sessions: [indexedSession], nextCursor: null }),
        sessionReplay: replay,
        sessionResume: resume
      })
    });
    render(<ActivitySurface />);
    await act(async () => {
      await useActivityStore.getState().load();
    });

    fireEvent.click(screen.getAllByRole('button', { name: /show details/i })[0]!);
    expect(screen.getByText(/no verified daemon source identity/i)).toBeTruthy();
    const loadButton = screen.getByRole('button', { name: 'Load session body' }) as HTMLButtonElement;
    const resumeButton = screen.getByRole('button', { name: 'Resume session' }) as HTMLButtonElement;
    expect(loadButton.disabled).toBe(true);
    expect(resumeButton.disabled).toBe(true);
    fireEvent.click(loadButton);
    fireEvent.click(resumeButton);
    expect(replay).not.toHaveBeenCalled();
    expect(resume).not.toHaveBeenCalled();
  });

  it('imports a complete JSON history export and resumes the selected source identity', async () => {
    const sourceID = 'Codex:exported-session';
    const indexedSession = {
      ...fixtureSessionList().sessions[0]!,
      sourceID,
      providerSessionID: 'exported-session',
      runID: 'run-exported'
    };
    const resume = vi.fn(async (sessionID: string): Promise<SessionReplayResult> => ({
      kind: 'spawned',
      briefingTruncated: false,
      pid: 99,
      note: sessionID
    }));
    const sessionList = vi.fn(async () => ({
      sessions: [indexedSession],
      nextCursor: null,
      complete: true,
      historyComplete: true
    }));
    useShellStore.setState({ bridge: mockBridge({ sessionList, sessionResume: resume }) });
    render(<ActivitySurface />);
    await act(async () => {
      await useActivityStore.getState().load();
    });

    const exported = {
      version: 1,
      scope: 'daemon-session-history',
      source: 'live daemon session index',
      generatedAt: '2026-07-13T14:00:00Z',
      loadedCount: 1,
      historyComplete: true,
      historyLimit: 500,
      sessions: [{
        ...fixtureSessionList().sessions[0]!,
        sourceID,
        providerSessionID: 'exported-session',
        runID: 'run-exported',
        bodyMD: 'persisted body'
      }]
    };
    const input = screen.getByLabelText('Choose activity history JSON export') as HTMLInputElement;
    const file = new File([JSON.stringify(exported)], 'activity-history.json', { type: 'application/json' });
    fireEvent.change(input, { target: { files: [file] } });
    expect(await screen.findByRole('combobox', { name: 'Imported activity session' })).toBeTruthy();
    expect(screen.getByRole('status').textContent).toMatch(/Imported 1 resumable session/i);

    fireEvent.click(screen.getByRole('button', { name: 'Resume selected' }));
    await screen.findByText(/process 99/i);
    expect(sessionList.mock.calls.length).toBeGreaterThanOrEqual(2);
    expect(resume).toHaveBeenCalledWith(sourceID);
    expect(screen.getByRole('status').textContent).toMatch(/process 99/i);
  });

  it('states that fixture rows have no persisted body or resume authority', async () => {
    useShellStore.setState({ fixtureMode: true });
    render(<ActivitySurface />);
    await act(async () => {
      await useActivityStore.getState().load();
    });
    fireEvent.click(screen.getAllByRole('button', { name: /show details/i })[0]!);
    fireEvent.click(screen.getByRole('button', { name: 'Load session body' }));
    expect(screen.getByRole('alert').textContent).toMatch(/live daemon/i);
    fireEvent.click(screen.getByRole('button', { name: 'Resume session' }));
    expect(screen.getByRole('status').textContent).toMatch(/resume is unavailable/i);
  });

  it('announces result count via aria-live', async () => {
    useShellStore.setState({ fixtureMode: true });
    render(<ActivitySurface />);
    await act(async () => {
      await useActivityStore.getState().load();
    });
    expect(screen.getByText(/14 sessions shown/i)).toBeTruthy();
  });
});
