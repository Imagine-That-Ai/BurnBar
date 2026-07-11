// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { fixtureSessionList } from '../../daemonFixture.js';
import { bridgeStubDefaults } from '../../testing/bridgeStubs.js';
import type { GatewayProxyRequest, LinuxShellBridge, SessionListResult } from '../../tauriBridge.js';
import { useChatStore } from '../../state/chatStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { availableRuntimeCapabilities } from '../../testing/bridgeStubs.js';
import { ChatSurface } from './ChatSurface.js';

function mockBridge(handlers: {
  sessionList?: () => Promise<SessionListResult>;
  sessionSearch?: (query: string) => Promise<SessionListResult>;
  gatewayProbe?: () => Promise<boolean>;
  gatewayChatStream?: (request: GatewayProxyRequest, onChunk: (chunk: string) => void) => Promise<void>;
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
    accountStatus: async () => ({ state: 'signed_out', signedIn: false, trustClass: 'linux-lower-trust', syncState: 'local-only', updatedAt: '2026-07-10T00:00:00Z' }),
    appVersionInfo: async () => ({
      shellVersion: '0',
      daemonVersion: '0',
      packageChannel: 'unknown',
      updateCheck: 'skipped'
    }),
    exportDiagnostics: async () => ({ path: '/tmp/diag.zip' }),
    sessionEnv: async () => ({}),
    gatewayProbe: handlers.gatewayProbe ?? (async () => false),
    gatewayChatStream: handlers.gatewayChatStream ?? (async () => undefined),
    gatewayChatCancel: async () => undefined,
    mediaStatus: async () => ({ capabilityAvailable: false, pairedDevices: [] }),
    integrationsStatus: async () => ({ integrations: [] })
  };
  return bridge;
}

const resetChatStore = () => {
  useChatStore.setState({
    threads: [],
    nextCursor: null,
    selectedThreadId: null,
    messages: [],
    messagesLoading: false,
    config: null,
    loading: false,
    error: null,
    query: '',
    visibleThreadCount: 40,
    backend: 'hermes',
    modelLabel: 'hermes',
    streaming: false,
    streamPhase: 'idle',
    streamError: null,
    gatewayStatus: 'unknown',
    gatewayBaseURL: null,
    activeAbortController: null,
    warnings: [],
    sharedFeaturesAvailable: true
  });
};

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  resetChatStore();
  useShellStore.setState({ bridge: null, bridgeReady: true, fixtureMode: false, health: null });
});

describe('ChatSurface', () => {
  it('shows offline notice without bridge', async () => {
    useShellStore.setState({ bridge: null, fixtureMode: false, bridgeReady: true });
    render(<ChatSurface />);
    expect(screen.getByText(/packaged shell/i)).toBeTruthy();
  });

  it('shows empty state when no threads', async () => {
    useShellStore.setState({
      bridge: mockBridge({ sessionList: async () => ({ sessions: [], nextCursor: null }) }),
      fixtureMode: false,
      bridgeReady: true
    });
    render(<ChatSurface />);
    await waitFor(() => {
      expect(screen.getByText(/No conversations yet/i)).toBeTruthy();
    });
  });

  it('renders thread rail and messages from fixture sessions', async () => {
    const list = fixtureSessionList();
    useShellStore.setState({
      bridge: mockBridge({ sessionList: async () => list }),
      fixtureMode: false,
      bridgeReady: true
    });
    render(<ChatSurface />);
    await waitFor(() => {
      expect(screen.getByRole('log')).toBeTruthy();
    });
    expect(screen.getAllByText(list.sessions[0].title).length).toBeGreaterThan(0);
  });

  it('shows error banner on fetch failure', async () => {
    useShellStore.setState({
      bridge: mockBridge({
        sessionList: async () => {
          throw new Error('daemon down');
        }
      }),
      fixtureMode: false,
      bridgeReady: true
    });
    render(<ChatSurface />);
    await waitFor(() => {
      expect(screen.getByRole('alert')).toBeTruthy();
    });
    expect(screen.getByText(/daemon down/i)).toBeTruthy();
  });

  it('shows fixture warning banners and via Hermes badge', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: null, bridgeReady: true });
    render(<ChatSurface />);
    await waitFor(() => {
      expect(screen.getByText(/Index stale/i)).toBeTruthy();
    });
    expect(screen.getByText(/Cloud \/ shared unavailable/i)).toBeTruthy();
    expect(screen.getByText(/via Hermes/i)).toBeTruthy();
  });

  it('shows streaming stop control when streaming flag is set', async () => {
    const list = fixtureSessionList();
    useShellStore.setState({
      bridge: mockBridge({ sessionList: async () => list }),
      fixtureMode: true,
      bridgeReady: true
    });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('log')).toBeTruthy());
    act(() => {
      useChatStore.setState({ streaming: true });
    });
    expect(screen.getByRole('button', { name: /Stop generating/i })).toBeTruthy();
  });

  it('announces stream completion and abort transitions politely', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: null, bridgeReady: true });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('log')).toBeTruthy());

    act(() => {
      useChatStore.setState({ streamPhase: 'streaming' });
    });
    act(() => {
      useChatStore.setState({ streamPhase: 'done' });
    });
    await waitFor(() => expect(screen.getByText('Response complete. 1')).toBeTruthy());

    act(() => {
      useChatStore.setState({ streamPhase: 'streaming' });
    });
    act(() => {
      useChatStore.setState({ streamPhase: 'done' });
    });
    await waitFor(() => expect(screen.getByText('Response complete. 2')).toBeTruthy());

    act(() => {
      useChatStore.setState({ streamPhase: 'streaming' });
    });
    act(() => {
      useChatStore.setState({ streamPhase: 'aborted' });
    });
    await waitFor(() => expect(screen.getByText('Stream stopped. 3')).toBeTruthy());
  });

  it('uses backend-specific composer placeholder for Codex', async () => {
    const list = fixtureSessionList();
    useShellStore.setState({
      bridge: mockBridge({ sessionList: async () => list }),
      fixtureMode: true,
      bridgeReady: true
    });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('log')).toBeTruthy());
    act(() => {
      useChatStore.setState({ backend: 'codex' });
    });
    await waitFor(() => {
      expect(screen.getByPlaceholderText(/Ask Codex/i)).toBeTruthy();
    });
  });


  it('streams a scripted fixture response from the composer', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: null, bridgeReady: true });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('log')).toBeTruthy());
    fireEvent.change(screen.getByLabelText(/Message composer/i), { target: { value: 'hello fixture' } });
    fireEvent.keyDown(screen.getByLabelText(/Message composer/i), { key: 'Enter' });
    await waitFor(() => {
      expect(screen.getByText(/Fixture stream online/i)).toBeTruthy();
    });
    // The tool_call frame arrives one fixture-stream tick after the first
    // delta, so it must be awaited too or the assertion races the stream.
    await waitFor(() => {
      expect(screen.getByText(/workspace.read/i)).toBeTruthy();
      expect(screen.getAllByTitle(/Approval flows ride agent runs/i).length).toBeGreaterThan(0);
    });
  });

  it('disables composer when gateway health is unreachable', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => {
        throw new TypeError('connection refused');
      })
    );
    useShellStore.setState({
      bridge: mockBridge({ sessionList: async () => ({ sessions: [], nextCursor: null }) }),
      fixtureMode: false,
      bridgeReady: true,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByText(/Gateway health check failed/i)).toBeTruthy());
    expect(screen.getByRole('button', { name: /Send message/i })).toHaveProperty('disabled', true);
  });

  it('renders an unimplemented response from the native gateway proxy honestly', async () => {
    useShellStore.setState({
      bridge: mockBridge({
        sessionList: async () => ({ sessions: [], nextCursor: null }),
        gatewayProbe: async () => true,
        gatewayChatStream: async () => {
          throw new Error('gateway_http:503:chat completions unimplemented');
        }
      }),
      fixtureMode: false,
      bridgeReady: true,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByLabelText(/Message composer/i)).toBeTruthy());
    const composer = screen.getByLabelText(/Message composer/i);
    fireEvent.change(composer, { target: { value: 'hello live gateway' } });
    await waitFor(() => {
      expect(screen.getByRole('button', { name: /Send message/i })).toHaveProperty('disabled', false);
    });
    fireEvent.click(screen.getByRole('button', { name: /Send message/i }));
    await waitFor(() => {
      expect(screen.getByText(/Gateway chat is not available in this Linux daemon build yet/i)).toBeTruthy();
    });
  });
});
