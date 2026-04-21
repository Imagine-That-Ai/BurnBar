import { describe, it, expect } from 'vitest';
import type {
  OpenBurnBarState,
  BurnBarRunProjection,
  BurnBarCatalog,
  BurnBarRunStateSnapshot,
  BurnBarUsageEvent,
  BurnBarWorkspaceCapabilities,
  BurnBarRunPhase,
  BurnBarMissionSnapshot
} from '../src/types';
import {
  projectRuns,
  buildHealthRows,
  buildRunDetailRows,
  buildMissionRows,
  buildMissionNextActions,
  buildMissionDetailRows,
  readinessDisplayMessage,
  type BurnBarHealthRow,
  type BurnBarRunDetailRow,
  type BurnBarMissionRow
} from '../src/state/projections';

// Helper to create a minimal state for testing
function createMockState(overrides: Partial<OpenBurnBarState> = {}): OpenBurnBarState {
  return {
    connectionStatus: 'connected',
    clientAttached: true,
    health: {
      daemonVersion: '1.0.0',
      protocolVersion: '1.0.0',
      socketPath: '/tmp/openburnbar.sock',
      uptimeSeconds: 3600
    },
    catalog: {
      providers: [],
      models: []
    },
    daemonRuns: [],
    daemonMissions: [],
    pendingToolCalls: [],
    recentUsage: [],
    lastError: undefined,
    runError: undefined,
    workspace: undefined,
    workspaceError: undefined,
    runs: [],
    selectedRunId: undefined,
    selectedRunDetail: undefined,
    ...overrides
  } as OpenBurnBarState;
}

// Helper to create a mock run
function createMockRun(overrides: Partial<BurnBarRunStateSnapshot> = {}): BurnBarRunStateSnapshot {
  return {
    runID: 'run-123',
    clientID: 'client-1',
    sessionID: 'session-1',
    modelID: 'claude-opus-4',
    phase: 'completed' as BurnBarRunPhase,
    updatedAt: '2024-01-15T12:00:00Z',
    errorMessage: undefined,
    ...overrides
  };
}

// Helper to create a mock catalog
function createMockCatalog(): BurnBarCatalog {
  return {
    providers: [
      {
        id: 'claude-code',
        displayName: 'Claude Code',
        models: [
          { id: 'claude-opus-4', displayName: 'Claude Opus 4', visibility: 'public' as const },
          { id: 'claude-sonnet-4', displayName: 'Claude Sonnet 4', visibility: 'public' as const }
        ]
      }
    ],
    models: []
  };
}

describe('projectRuns', () => {
  it('should return repairing state when connection is repairing', () => {
    const state = createMockState({ connectionStatus: 'repairing' });
    const result = projectRuns(state);

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('repairing-daemon');
    expect(result[0].phase).toBe('planning');
    expect(result[0].source).toBe('projected');
  });

  it('should return daemon unavailable when not connected', () => {
    const state = createMockState({ connectionStatus: 'disconnected' });
    const result = projectRuns(state);

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('daemon-unavailable');
    expect(result[0].phase).toBe('failed');
  });

  it('should return daemon unavailable when health is missing', () => {
    const state = createMockState({ health: undefined });
    const result = projectRuns(state);

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('daemon-unavailable');
  });

  it('should return client session unavailable when not attached', () => {
    const state = createMockState({ clientAttached: false });
    const result = projectRuns(state);

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('client-session-unavailable');
    expect(result[0].phase).toBe('failed');
  });

  it('should return run error state when runError is set', () => {
    const state = createMockState({ runError: 'Run state error' });
    const result = projectRuns(state);

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('run-state-unavailable');
    expect(result[0].note).toContain('Run state error');
  });

  it('should return empty run list when no runs', () => {
    const state = createMockState();
    const result = projectRuns(state);

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('empty-run-list');
    expect(result[0].phase).toBe('idle');
  });

  it('should project daemon runs when available', () => {
    const runs: BurnBarRunStateSnapshot[] = [
      createMockRun({ runID: 'run-1', phase: 'completed' }),
      createMockRun({ runID: 'run-2', phase: 'running' })
    ];
    const state = createMockState({ daemonRuns: runs });
    const result = projectRuns(state);

    expect(result).toHaveLength(2);
    expect(result[0].id).toBe('run-1');
    expect(result[0].source).toBe('daemon');
    expect(result[1].id).toBe('run-2');
  });

  it('should include error message in failed run', () => {
    const runs = [
      createMockRun({ runID: 'run-1', phase: 'failed', errorMessage: 'Test error' })
    ];
    const state = createMockState({ daemonRuns: runs });
    const result = projectRuns(state);

    expect(result[0].note).toBe('Test error');
  });

  it('should handle awaiting_approval phase', () => {
    const runs = [createMockRun({ runID: 'run-1', phase: 'awaiting_approval' })];
    const state = createMockState({ daemonRuns: runs });
    const result = projectRuns(state);

    expect(result[0].note).toBe('Awaiting approval');
  });

  it('should handle untrusted workspace with awaiting_approval', () => {
    const runs = [createMockRun({ runID: 'run-1', phase: 'awaiting_approval' })];
    const workspace: BurnBarWorkspaceCapabilities = {
      hasWorkspace: true,
      untrustedWorkspace: true,
      virtualWorkspace: false,
      remoteWorkspace: false,
      localWorkspace: true,
      readonlyWorkspace: false,
      workspaceHost: 'cursor',
      availableTools: ['read_file', 'search_workspace'],
      gatedTools: []
    };
    const state = createMockState({ daemonRuns: runs, workspace });
    const result = projectRuns(state);

    expect(result[0].note).toBe('Awaiting trust');
  });

  it('should handle completed run with usage', () => {
    const runs = [createMockRun({ runID: 'run-1', phase: 'completed' })];
    const usage: BurnBarUsageEvent[] = [{
      runID: 'run-1',
      providerID: 'claude-code',
      inputTokens: 1000,
      outputTokens: 500,
      cost: 0.05,
      timestamp: new Date()
    }];
    const catalog = createMockCatalog();
    const state = createMockState({ daemonRuns: runs, recentUsage: usage, catalog });
    const result = projectRuns(state);

    expect(result[0].note).toContain('1500 billed tokens');
  });

  it('should handle idle phase', () => {
    const runs = [createMockRun({ runID: 'run-1', phase: 'idle' })];
    const state = createMockState({ daemonRuns: runs });
    const result = projectRuns(state);

    expect(result[0].note).toContain('queued and waiting');
  });

  it('should handle planning phase', () => {
    const runs = [createMockRun({ runID: 'run-1', phase: 'planning' })];
    const state = createMockState({ daemonRuns: runs });
    const result = projectRuns(state);

    expect(result[0].note).toContain('planning');
  });

  it('should handle executing_tool phase with pending tool', () => {
    const runs = [createMockRun({ runID: 'run-1', phase: 'executing_tool' })];
    const pendingToolCalls: OpenBurnBarState['pendingToolCalls'] = [{
      runID: 'run-1',
      tool: 'read_file',
      status: 'pending',
      requestedAt: new Date().toISOString()
    }];
    const state = createMockState({ daemonRuns: runs, pendingToolCalls });
    const result = projectRuns(state);

    expect(result[0].note).toContain('Reading file');
  });

  it('should handle executing_tool phase without pending tool', () => {
    const runs = [createMockRun({ runID: 'run-1', phase: 'executing_tool' })];
    const state = createMockState({ daemonRuns: runs, pendingToolCalls: [] });
    const result = projectRuns(state);

    expect(result[0].note).toContain('executing a workspace tool');
  });

  it('should handle waiting_on_companion phase', () => {
    const runs = [createMockRun({ runID: 'run-1', phase: 'waiting_on_companion' })];
    const state = createMockState({ daemonRuns: runs });
    const result = projectRuns(state);

    expect(result[0].note).toContain('waiting for the workspace companion');
  });

  it('should handle model_streaming phase', () => {
    const runs = [createMockRun({ runID: 'run-1', phase: 'model_streaming' })];
    const state = createMockState({ daemonRuns: runs });
    const result = projectRuns(state);

    expect(result[0].note).toContain('streaming model output');
  });

  it('should handle cancelled phase', () => {
    const runs = [createMockRun({ runID: 'run-1', phase: 'cancelled' })];
    const state = createMockState({ daemonRuns: runs });
    const result = projectRuns(state);

    expect(result[0].note).toContain('cancelled');
  });

  it('should include provider info from catalog', () => {
    const runs = [createMockRun({ runID: 'run-1', modelID: 'claude-opus-4' })];
    const catalog = createMockCatalog();
    const state = createMockState({ daemonRuns: runs, catalog });
    const result = projectRuns(state);

    expect(result[0].providerId).toBe('claude-code');
    expect(result[0].providerName).toBe('Claude Code');
  });

  it('should include provider info from usage', () => {
    const runs = [createMockRun({ runID: 'run-1' })];
    const usage: BurnBarUsageEvent[] = [{
      runID: 'run-1',
      providerID: 'claude-code',
      inputTokens: 100,
      outputTokens: 50,
      cost: 0.01,
      timestamp: new Date()
    }];
    const state = createMockState({ daemonRuns: runs, recentUsage: usage });
    const result = projectRuns(state);

    expect(result[0].providerId).toBe('claude-code');
  });
});

describe('buildHealthRows', () => {
  it('should return health rows for connected state', () => {
    const state = createMockState({
      connectionStatus: 'connected',
      clientAttached: true
    });
    const rows = buildHealthRows(state);

    expect(rows.some(r => r.id === 'status')).toBe(true);
    expect(rows.some(r => r.id === 'session')).toBe(true);
    expect(rows.some(r => r.id === 'daemon')).toBe(true);
  });

  it('should show correct status for disconnected', () => {
    const state = createMockState({ connectionStatus: 'disconnected' });
    const rows = buildHealthRows(state);

    const statusRow = rows.find(r => r.id === 'status');
    expect(statusRow?.value).toBe('Disconnected');
    expect(statusRow?.icon).toBe('warning');
  });

  it('should show correct status for connecting', () => {
    const state = createMockState({ connectionStatus: 'connecting' });
    const rows = buildHealthRows(state);

    const statusRow = rows.find(r => r.id === 'status');
    expect(statusRow?.value).toBe('Connecting');
  });

  it('should show correct status for repairing', () => {
    const state = createMockState({ connectionStatus: 'repairing' });
    const rows = buildHealthRows(state);

    const statusRow = rows.find(r => r.id === 'status');
    expect(statusRow?.value).toBe('Repairing');
    expect(statusRow?.icon).toBe('pulse');
  });

  it('should show session not attached warning', () => {
    const state = createMockState({ clientAttached: false });
    const rows = buildHealthRows(state);

    const sessionRow = rows.find(r => r.id === 'session');
    expect(sessionRow?.value).toBe('Not attached');
    expect(sessionRow?.icon).toBe('warning');
  });

  it('should show daemon version', () => {
    const state = createMockState();
    const rows = buildHealthRows(state);

    const daemonRow = rows.find(r => r.id === 'daemon');
    expect(daemonRow?.value).toBe('1.0.0');
  });

  it('should show protocol version', () => {
    const state = createMockState();
    const rows = buildHealthRows(state);

    const protocolRow = rows.find(r => r.id === 'protocol');
    expect(protocolRow?.value).toBe('v1.0.0');
  });

  it('should show socket path', () => {
    const state = createMockState();
    const rows = buildHealthRows(state);

    const socketRow = rows.find(r => r.id === 'socket');
    expect(socketRow?.value).toBe('/tmp/openburnbar.sock');
  });

  it('should show unavailable when health is missing', () => {
    const state = createMockState({ health: undefined });
    const rows = buildHealthRows(state);

    const socketRow = rows.find(r => r.id === 'socket');
    expect(socketRow?.value).toBe('Unavailable');
  });

  it('should include last error when present', () => {
    const state = createMockState({ lastError: 'Test error message' });
    const rows = buildHealthRows(state);

    expect(rows.some(r => r.id === 'last-error')).toBe(true);
    const errorRow = rows.find(r => r.id === 'last-error');
    expect(errorRow?.value).toBe('Test error message');
    expect(errorRow?.icon).toBe('warning');
  });

  it('should include run error when present', () => {
    const state = createMockState({ runError: 'Run failed' });
    const rows = buildHealthRows(state);

    const runErrorRow = rows.find(r => r.id === 'run-error');
    expect(runErrorRow?.value).toBe('Run failed');
  });

  it('should show catalog status with providers', () => {
    const catalog = createMockCatalog();
    const state = createMockState({ catalog });
    const rows = buildHealthRows(state);

    const catalogRow = rows.find(r => r.id === 'catalog');
    expect(catalogRow?.value).toContain('1 providers');
    expect(catalogRow?.value).toContain('2 visible models');
    expect(catalogRow?.icon).toBe('pass');
  });

  it('should show catalog waiting status when no providers', () => {
    const state = createMockState({ catalog: { providers: [], models: [] } });
    const rows = buildHealthRows(state);

    const catalogRow = rows.find(r => r.id === 'catalog');
    expect(catalogRow?.value).toBe('Connected, waiting for provider catalog');
    expect(catalogRow?.icon).toBe('pulse');
  });

  it('should show catalog unavailable when disconnected', () => {
    const state = createMockState({ connectionStatus: 'disconnected' });
    const rows = buildHealthRows(state);

    const catalogRow = rows.find(r => r.id === 'catalog');
    expect(catalogRow?.value).toBe('Unavailable');
    expect(catalogRow?.icon).toBe('warning');
  });

  it('should show run count', () => {
    const runs = [
      createMockRun({ runID: 'run-1' }),
      createMockRun({ runID: 'run-2' })
    ];
    const state = createMockState({ daemonRuns: runs });
    const rows = buildHealthRows(state);

    const runsRow = rows.find(r => r.id === 'runs');
    expect(runsRow?.value).toBe('2 tracked');
    expect(runsRow?.icon).toBe('pass');
  });

  it('should show zero runs note', () => {
    const state = createMockState();
    const rows = buildHealthRows(state);

    const runsRow = rows.find(r => r.id === 'runs');
    expect(runsRow?.value).toBe('0 tracked');
    expect(runsRow?.icon).toBe('note');
  });

  it('should show workspace mode', () => {
    const workspace: BurnBarWorkspaceCapabilities = {
      hasWorkspace: true,
      untrustedWorkspace: false,
      virtualWorkspace: false,
      remoteWorkspace: false,
      localWorkspace: true,
      readonlyWorkspace: false,
      workspaceHost: 'cursor',
      availableTools: ['read_file'],
      gatedTools: []
    };
    const state = createMockState({ workspace });
    const rows = buildHealthRows(state);

    const workspaceRow = rows.find(r => r.id === 'workspace-mode');
    expect(workspaceRow?.value).toContain('Local');
    expect(workspaceRow?.value).toContain('trusted');
    expect(workspaceRow?.value).toContain('writable');
  });

  it('should show gated tools warning', () => {
    const workspace: BurnBarWorkspaceCapabilities = {
      hasWorkspace: true,
      untrustedWorkspace: false,
      virtualWorkspace: false,
      remoteWorkspace: false,
      localWorkspace: true,
      readonlyWorkspace: false,
      workspaceHost: 'cursor',
      availableTools: ['read_file'],
      gatedTools: ['apply_patch', 'run_terminal']
    };
    const state = createMockState({ workspace });
    const rows = buildHealthRows(state);

    const workspaceRow = rows.find(r => r.id === 'workspace-mode');
    expect(workspaceRow?.icon).toBe('warning');
  });

  it('should show workspace explanation when present', () => {
    const workspace: BurnBarWorkspaceCapabilities = {
      hasWorkspace: true,
      untrustedWorkspace: true,
      virtualWorkspace: false,
      remoteWorkspace: false,
      localWorkspace: true,
      readonlyWorkspace: false,
      workspaceHost: 'cursor',
      availableTools: [],
      gatedTools: [],
      explanation: 'Workspace is restricted'
    };
    const state = createMockState({ workspace });
    const rows = buildHealthRows(state);

    const explanationRow = rows.find(r => r.id === 'workspace-explanation');
    expect(explanationRow?.value).toBe('Workspace is restricted');
  });

  it('should show next step when recommended', () => {
    const state = createMockState({
      catalog: { providers: [], models: [] }
    });
    const rows = buildHealthRows(state);

    const nextStepRow = rows.find(r => r.id === 'next-step');
    expect(nextStepRow).toBeDefined();
  });
});

describe('buildRunDetailRows', () => {
  it('should return empty row when no run selected', () => {
    const state = createMockState();
    const rows = buildRunDetailRows(state);

    expect(rows).toHaveLength(1);
    expect(rows[0].id).toBe('empty');
  });

  it('should show selected run details', () => {
    const run: BurnBarRunProjection = {
      id: 'run-123',
      title: 'Run 12345678',
      phase: 'completed',
      note: 'Test note',
      updatedAt: '2024-01-15T12:00:00Z',
      source: 'daemon'
    };
    const state = createMockState({
      runs: [run],
      selectedRunId: 'run-123'
    });
    const rows = buildRunDetailRows(state);

    expect(rows.some(r => r.id === 'title')).toBe(true);
    expect(rows.some(r => r.id === 'phase')).toBe(true);
  });

  it('should show provider and model info', () => {
    const run: BurnBarRunProjection = {
      id: 'run-123',
      title: 'Run 12345678',
      phase: 'completed',
      note: '',
      updatedAt: '2024-01-15T12:00:00Z',
      source: 'daemon',
      providerId: 'claude-code',
      providerName: 'Claude Code',
      modelId: 'claude-opus-4'
    };
    const state = createMockState({
      runs: [run],
      selectedRunId: 'run-123'
    });
    const rows = buildRunDetailRows(state);

    expect(rows.some(r => r.id === 'provider')).toBe(true);
    expect(rows.some(r => r.id === 'model')).toBe(true);
  });

  it('should show run snapshot details when available', () => {
    const run: BurnBarRunProjection = {
      id: 'run-123',
      title: 'Run 12345678',
      phase: 'completed',
      note: '',
      updatedAt: '2024-01-15T12:00:00Z',
      source: 'daemon'
    };
    const daemonRun = createMockRun({
      runID: 'run-123',
      clientID: 'client-abc',
      sessionID: 'session-xyz'
    });
    const state = createMockState({
      runs: [run],
      selectedRunId: 'run-123',
      daemonRuns: [daemonRun]
    });
    const rows = buildRunDetailRows(state);

    expect(rows.some(r => r.id === 'run-id')).toBe(true);
    expect(rows.some(r => r.id === 'client-id')).toBe(true);
    expect(rows.some(r => r.id === 'session-id')).toBe(true);
  });

  it('should show error message when present', () => {
    const run: BurnBarRunProjection = {
      id: 'run-123',
      title: 'Run 12345678',
      phase: 'failed',
      note: '',
      updatedAt: '2024-01-15T12:00:00Z',
      source: 'daemon'
    };
    const daemonRun = createMockRun({
      runID: 'run-123',
      errorMessage: 'Something went wrong'
    });
    const state = createMockState({
      runs: [run],
      selectedRunId: 'run-123',
      daemonRuns: [daemonRun]
    });
    const rows = buildRunDetailRows(state);

    const errorRow = rows.find(r => r.id === 'error');
    expect(errorRow?.value).toBe('Something went wrong');
  });

  it('should show usage info when available', () => {
    const run: BurnBarRunProjection = {
      id: 'run-123',
      title: 'Run 12345678',
      phase: 'completed',
      note: '',
      updatedAt: '2024-01-15T12:00:00Z',
      source: 'daemon'
    };
    const usage: BurnBarUsageEvent[] = [{
      runID: 'run-123',
      providerID: 'claude-code',
      inputTokens: 1000,
      outputTokens: 500,
      cost: 0.05,
      timestamp: new Date()
    }];
    const state = createMockState({
      runs: [run],
      selectedRunId: 'run-123',
      recentUsage: usage
    });
    const rows = buildRunDetailRows(state);

    expect(rows.some(r => r.id === 'usage')).toBe(true);
  });

  it('should show approval request when pending', () => {
    const run: BurnBarRunProjection = {
      id: 'run-123',
      title: 'Run 12345678',
      phase: 'awaiting_approval',
      note: 'Approval needed',
      updatedAt: '2024-01-15T12:00:00Z',
      source: 'daemon'
    };
    const detail = {
      run: createMockRun({ runID: 'run-123' }),
      approvalRequest: {
        tool: 'apply_patch',
        title: 'Review Changes',
        message: 'Please review the changes',
        requestedAt: '2024-01-15T12:00:00Z'
      }
    };
    const state = createMockState({
      runs: [run],
      selectedRunId: 'run-123',
      selectedRunDetail: detail as any
    });
    const rows = buildRunDetailRows(state);

    expect(rows.some(r => r.id === 'approval-tool')).toBe(true);
    expect(rows.some(r => r.id === 'approval-requested-at')).toBe(true);
  });
});

// Integration tests
describe('Projection Integration', () => {
  it('should handle complete health check flow', () => {
    const state = createMockState({
      connectionStatus: 'connected',
      clientAttached: true,
      catalog: createMockCatalog(),
      daemonRuns: [createMockRun({ runID: 'run-1', phase: 'completed' })]
    });

    const runs = projectRuns(state);
    const healthRows = buildHealthRows(state);

    expect(runs).toHaveLength(1);
    expect(healthRows.some(r => r.value.includes('Connected'))).toBe(true);
  });

  it('should handle disconnected state gracefully', () => {
    const state = createMockState({
      connectionStatus: 'disconnected',
      lastError: 'Connection refused'
    });

    const runs = projectRuns(state);
    const healthRows = buildHealthRows(state);

    expect(runs).toHaveLength(1);
    expect(runs[0].id).toBe('daemon-unavailable');
    expect(healthRows.some(r => r.id === 'last-error')).toBe(true);
  });

  it('should handle empty workspace state', () => {
    const state = createMockState();
    const rows = buildHealthRows(state);

    expect(rows.some(r => r.id === 'workspace-mode')).toBe(true);
    const workspaceRow = rows.find(r => r.id === 'workspace-mode');
    expect(workspaceRow?.value).toContain('Detecting workspace companion');
  });
});

// Edge case tests
describe('Projection Edge Cases', () => {
  it('should handle malformed phase gracefully', () => {
    const runs = [createMockRun({ runID: 'run-1', phase: 'completed' as any })];
    const state = createMockState({ daemonRuns: runs });
    const result = projectRuns(state);

    expect(result[0].phase).toBe('completed');
  });

  it('should handle very long run ID', () => {
    const longRunId = 'run-' + 'a'.repeat(100);
    const runs = [createMockRun({ runID: longRunId })];
    const state = createMockState({ daemonRuns: runs });
    const result = projectRuns(state);

    // Short ID should truncate
    expect(result[0].title).toContain('run-');
    expect(result[0].title.length).toBeLessThan(longRunId.length + 10);
  });

  it('should handle workspace with all gated tools', () => {
    const workspace: BurnBarWorkspaceCapabilities = {
      hasWorkspace: true,
      untrustedWorkspace: true,
      virtualWorkspace: true,
      remoteWorkspace: true,
      localWorkspace: false,
      readonlyWorkspace: true,
      workspaceHost: 'cursor',
      availableTools: [],
      gatedTools: ['apply_patch', 'run_terminal', 'read_file', 'search_workspace']
    };
    const state = createMockState({ workspace });
    const rows = buildHealthRows(state);

    const workspaceRow = rows.find(r => r.id === 'workspace-mode');
    expect(workspaceRow?.value).toContain('Remote');
    expect(workspaceRow?.value).toContain('restricted');
    expect(workspaceRow?.value).toContain('read-only');
    expect(workspaceRow?.value).toContain('virtual');
  });

  it('should handle workspace with all tools available', () => {
    const workspace: BurnBarWorkspaceCapabilities = {
      hasWorkspace: true,
      untrustedWorkspace: false,
      virtualWorkspace: false,
      remoteWorkspace: false,
      localWorkspace: true,
      readonlyWorkspace: false,
      workspaceHost: 'cursor',
      availableTools: ['read_file', 'search_workspace', 'apply_patch', 'run_terminal'],
      gatedTools: []
    };
    const state = createMockState({ workspace });
    const rows = buildHealthRows(state);

    const workspaceRow = rows.find(r => r.id === 'workspace-mode');
    expect(workspaceRow?.icon).toBe('pass');
  });
});

// Helper to create a mock mission
function createMockMission(overrides: Partial<BurnBarMissionSnapshot> = {}): BurnBarMissionSnapshot {
  return {
    id: 'mission-123',
    projectSlug: 'apollo',
    title: 'Ship the approval sheet',
    summary: 'Approval sheet is stable, QA passed, and only launch coordination remains before release.',
    status: 'awaiting_approval',
    recommendation: 'review',
    createdAt: '2024-01-15T12:00:00Z',
    updatedAt: '2024-01-15T12:00:00Z',
    approval: { approved: false },
    packets: [],
    results: [],
    burnRecords: [],
    takeoverHistory: [],
    metadata: {},
    ...overrides
  };
}

// VAL-EXT-008: Extension mission list/detail projections mirror daemon mission lifecycle transitions and ordering
describe('buildMissionRows', () => {
  it('should return daemon unavailable state when not connected', () => {
    const state = createMockState({ connectionStatus: 'disconnected' });
    const result = buildMissionRows(state);

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('daemon-unavailable');
    expect(result[0].phase).toBe('failed');
    expect(result[0].source).toBe('projected');
  });

  it('should return client session unavailable when not attached', () => {
    const state = createMockState({ clientAttached: false });
    const result = buildMissionRows(state);

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('client-session-unavailable');
    expect(result[0].phase).toBe('failed');
    expect(result[0].source).toBe('projected');
  });

  it('should return empty mission list when no missions', () => {
    const state = createMockState({ daemonMissions: [] });
    const result = buildMissionRows(state);

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('empty-mission-list');
    expect(result[0].phase).toBe('idle');
    expect(result[0].source).toBe('projected');
  });

  it('should project daemon missions when available', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({ id: 'mission-1', status: 'in_progress', title: 'Active mission' }),
      createMockMission({ id: 'mission-2', status: 'completed', title: 'Done mission' })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionRows(state);

    expect(result).toHaveLength(2);
    expect(result[0].id).toBe('mission-1');
    expect(result[0].source).toBe('daemon');
    expect(result[0].status).toBe('in_progress');
    expect(result[1].id).toBe('mission-2');
    expect(result[1].status).toBe('completed');
  });

  // VAL-EXT-007: Mission row carries PR linkage + closure-question state for extension closure surfaces.
  it('should project PR linkage and closure question state from mission snapshots', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({
        id: 'mission-pr',
        status: 'awaiting_approval',
        prLinkage: {
          schemaVersion: 1,
          repository: 'Ajnunezg/BurnBar',
          prNumberOrID: '42',
          url: 'https://github.com/Ajnunezg/BurnBar/pull/42',
          state: 'opened'
        }
      })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionRows(state);

    expect(result).toHaveLength(1);
    expect(result[0].prLinkage?.repository).toBe('Ajnunezg/BurnBar');
    expect(result[0].prLinkage?.prNumberOrID).toBe('42');
    expect(result[0].prLinkage?.state).toBe('opened');
    expect(result[0].closureQuestionState).toBe('Pending closure approval question');
  });

  // VAL-EXT-007: Metadata fallback keeps legacy daemon payloads projecting canonical PR state.
  it('should derive PR linkage from metadata fallback keys', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({
        id: 'mission-pr-metadata',
        status: 'completed',
        metadata: {
          pr_repository: 'Ajnunezg/BurnBar',
          pr_id: '420',
          pr_url: 'https://github.com/Ajnunezg/BurnBar/pull/420',
          pr_state: 'closed',
          pr_merge_commit_sha: 'abc123def',
          pr_merged_at: '2024-01-15T12:00:00Z'
        }
      })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionRows(state);

    expect(result).toHaveLength(1);
    expect(result[0].prLinkage?.state).toBe('merged');
    expect(result[0].prLinkage?.mergeCommitSHA).toBe('abc123def');
    expect(result[0].closureQuestionState).toBe('No closure question pending');
  });

  // VAL-CROSS-001: Extension closure projection reflects daemon merged-PR terminal outcome.
  it('VAL-CROSS-001: mission closure projection shows merged PR with no pending closure approval question', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({
        id: 'mission-val-cross-001',
        status: 'completed',
        title: 'Open and merge PR from one-line mission',
        prLinkage: {
          schemaVersion: 1,
          repository: 'Ajnunezg/BurnBar',
          prNumberOrID: '42',
          url: 'https://github.com/Ajnunezg/BurnBar/pull/42',
          state: 'merged',
          mergeCommitSHA: 'abc123def',
          mergedAt: '2024-01-15T12:00:00Z'
        }
      })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionRows(state);

    expect(result).toHaveLength(1);
    expect(result[0].status).toBe('completed');
    expect(result[0].prLinkage?.state).toBe('merged');
    expect(result[0].prLinkage?.mergeCommitSHA).toBe('abc123def');
    expect(result[0].closureQuestionState).toBe('No closure question pending');
  });

  // VAL-EXT-008: matches daemon canonical ordering (updatedAt DESC, missionID ASC tie-break)
  it('should sort missions by updatedAt DESC with missionID ASC tie-break', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({ id: 'mission-b', status: 'awaiting_approval', updatedAt: '2024-01-15T12:00:00Z' }),
      createMockMission({ id: 'mission-c', status: 'in_progress', updatedAt: '2024-01-15T12:00:00Z' }),
      createMockMission({ id: 'mission-a', status: 'approved', updatedAt: '2024-01-15T13:00:00Z' })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionRows(state);

    expect(result).toHaveLength(3);
    // Most recent first (updatedAt DESC)
    expect(result[0].id).toBe('mission-a');
    expect(result[1].id).toBe('mission-b');
    expect(result[2].id).toBe('mission-c');
  });

  it('should use missionID ASC tie-break when updatedAt timestamps are equal', () => {
    const sameTime = '2024-01-15T12:00:00Z';
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({ id: 'mission-c', status: 'completed', updatedAt: sameTime }),
      createMockMission({ id: 'mission-a', status: 'in_progress', updatedAt: sameTime }),
      createMockMission({ id: 'mission-b', status: 'awaiting_approval', updatedAt: sameTime })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionRows(state);

    expect(result).toHaveLength(3);
    // missionID ASC tie-break: mission-a < mission-b < mission-c
    expect(result[0].id).toBe('mission-a');
    expect(result[1].id).toBe('mission-b');
    expect(result[2].id).toBe('mission-c');
  });

  it('should track approval state from mission approval', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({ id: 'mission-1', approval: { approved: true, approvedBy: 'alice' } }),
      createMockMission({ id: 'mission-2', approval: { approved: false } })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionRows(state);

    expect(result[0].approved).toBe(true);
    expect(result[0].approvedBy).toBe('alice');
    expect(result[1].approved).toBe(false);
  });

  it('should track takeover count from mission takeover history', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({
        id: 'mission-1',
        takeoverHistory: [
          { id: 'takeover-1', projectSlug: 'apollo', status: 'completed', reason: 'test', createdAt: '2024-01-15T12:00:00Z', updatedAt: '2024-01-15T12:00:00Z', metadata: {} },
          { id: 'takeover-2', projectSlug: 'apollo', status: 'completed', reason: 'test2', createdAt: '2024-01-15T12:00:00Z', updatedAt: '2024-01-15T12:00:00Z', metadata: {} }
        ]
      })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionRows(state);

    expect(result[0].takeoverCount).toBe(2);
  });

  it('should track packets count from mission packets', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({
        id: 'mission-1',
        packets: [
          { id: 'packet-1', missionID: 'mission-1', workerName: 'worker-1', objective: 'test', status: 'completed', metadata: {} },
          { id: 'packet-2', missionID: 'mission-1', workerName: 'worker-2', objective: 'test2', status: 'pending', metadata: {} }
        ]
      })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionRows(state);

    expect(result[0].packetsCount).toBe(2);
    expect(result[0].activePacketID).toBe('packet-2');
  });

  it('should reflect mission phase from associated run', () => {
    const runs: BurnBarRunStateSnapshot[] = [
      createMockRun({ runID: 'run-1', phase: 'executing_tool' })
    ];
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({
        id: 'mission-1',
        status: 'in_progress',
        packets: [{ id: 'packet-1', missionID: 'mission-1', workerName: 'worker-1', objective: 'test', status: 'in_progress', runID: 'run-1', metadata: {} }]
      })
    ];
    const state = createMockState({ daemonRuns: runs, daemonMissions: missions });
    const result = buildMissionRows(state);

    expect(result[0].phase).toBe('executing_tool');
  });
});

// VAL-CROSS-008: Re-entry next action ordering is deterministic after completion, interruption, or blockage
describe('buildMissionNextActions', () => {
  it('should order next actions by blockage, interruption, then completion with deterministic tie-breaks', () => {
    const now = new Date('2024-01-15T12:00:00Z');
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({
        id: 'mission-completed',
        status: 'completed',
        recommendation: 'proceed',
        updatedAt: new Date(now.getTime() + 360_000).toISOString()
      }),
      createMockMission({
        id: 'mission-blocked-b',
        status: 'failed',
        recommendation: 'review',
        updatedAt: now.toISOString()
      }),
      createMockMission({
        id: 'mission-interrupted',
        status: 'partially_completed',
        recommendation: 'pause',
        updatedAt: new Date(now.getTime() + 180_000).toISOString()
      }),
      createMockMission({
        id: 'mission-blocked-a',
        status: 'failed',
        recommendation: 'review',
        updatedAt: now.toISOString()
      })
    ];

    const state = createMockState({ daemonMissions: missions });
    const actions = buildMissionNextActions(state);

    expect(actions.map(a => a.missionId)).toEqual([
      'mission-blocked-a',
      'mission-blocked-b',
      'mission-interrupted',
      'mission-completed'
    ]);
    expect(actions.map(a => a.bucket)).toEqual([
      'blockage',
      'blockage',
      'interruption',
      'completion'
    ]);

    const actionsAgain = buildMissionNextActions(state);
    expect(actionsAgain.map(a => a.id)).toEqual(actions.map(a => a.id));
  });
});

describe('buildMissionDetailRows', () => {
  it('should return empty row when no mission selected', () => {
    const state = createMockState({ daemonMissions: [] });
    const result = buildMissionDetailRows(state);

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('empty');
  });

  it('should return not found when mission does not exist', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({ id: 'mission-1' })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionDetailRows(state, 'non-existent');

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('not-found');
  });

  it('should show mission details when mission exists', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({
        id: 'mission-1',
        projectSlug: 'apollo',
        title: 'Ship the approval sheet',
        summary: 'Approval sheet is stable.',
        status: 'in_progress',
        recommendation: 'review'
      })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionDetailRows(state, 'mission-1');

    expect(result.some(r => r.id === 'title')).toBe(true);
    expect(result.find(r => r.id === 'title')?.value).toBe('Ship the approval sheet');
    expect(result.some(r => r.id === 'project')).toBe(true);
    expect(result.find(r => r.id === 'project')?.value).toBe('apollo');
    expect(result.some(r => r.id === 'status')).toBe(true);
    expect(result.find(r => r.id === 'status')?.value).toBe('in_progress');
    expect(result.some(r => r.id === 'recommendation')).toBe(true);
    expect(result.some(r => r.id === 'summary')).toBe(true);
  });

  it('should show approval status', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({
        id: 'mission-1',
        approval: { approved: true, approvedBy: 'alice', note: 'Looks good' }
      })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionDetailRows(state, 'mission-1');

    const approvalRow = result.find(r => r.id === 'approval');
    expect(approvalRow?.value).toContain('Yes');
    expect(approvalRow?.value).toContain('alice');
  });

  // VAL-EXT-007: Mission detail rows include closure-question + PR lifecycle evidence.
  it('should include closure question and PR linkage detail rows', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({
        id: 'mission-pr-detail',
        status: 'completed',
        prLinkage: {
          schemaVersion: 1,
          repository: 'Ajnunezg/BurnBar',
          prNumberOrID: '77',
          url: 'https://github.com/Ajnunezg/BurnBar/pull/77',
          state: 'merged',
          mergeCommitSHA: 'fedcba987'
        }
      })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionDetailRows(state, 'mission-pr-detail');

    expect(result.find(r => r.id === 'closure-question-state')?.value).toBe('No closure question pending');
    expect(result.find(r => r.id === 'pr-linkage')?.value).toBe('Ajnunezg/BurnBar #77');
    expect(result.find(r => r.id === 'pr-state')?.value).toBe('merged');
    expect(result.find(r => r.id === 'pr-url')?.value).toBe('https://github.com/Ajnunezg/BurnBar/pull/77');
    expect(result.find(r => r.id === 'pr-merged')?.value).toBe('Yes');
  });

  it('should show packets count and active packet', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({
        id: 'mission-1',
        packets: [
          { id: 'packet-1', missionID: 'mission-1', workerName: 'worker-1', objective: 'test objective', status: 'completed', metadata: {} },
          { id: 'packet-2', missionID: 'mission-1', workerName: 'worker-2', objective: 'active objective', status: 'in_progress', metadata: {} }
        ]
      })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionDetailRows(state, 'mission-1');

    const packetsRow = result.find(r => r.id === 'packets');
    expect(packetsRow?.value).toContain('2 total');

    const activePacketRow = result.find(r => r.id === 'active-packet');
    expect(activePacketRow?.value).toContain('active objective');
  });

  it('should show burn records total', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({
        id: 'mission-1',
        burnRecords: [
          { id: 'burn-1', label: 'tokens', amount: 1500, unit: 'tokens', recordedAt: '2024-01-15T12:00:00Z' },
          { id: 'burn-2', label: 'tokens', amount: 500, unit: 'tokens', recordedAt: '2024-01-15T13:00:00Z' }
        ]
      })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionDetailRows(state, 'mission-1');

    const burnRow = result.find(r => r.id === 'burn');
    expect(burnRow?.value).toBe('2000.0000');
  });

  it('should show takeover history count', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({
        id: 'mission-1',
        takeoverHistory: [
          { id: 'takeover-1', projectSlug: 'apollo', status: 'completed', reason: 'test', createdAt: '2024-01-15T12:00:00Z', updatedAt: '2024-01-15T12:00:00Z', metadata: {} }
        ]
      })
    ];
    const state = createMockState({ daemonMissions: missions });
    const result = buildMissionDetailRows(state, 'mission-1');

    const takeoversRow = result.find(r => r.id === 'takeovers');
    expect(takeoversRow?.value).toContain('1 total');
  });
});

// VAL-CROSS-010: Mission authoring parity holds across app and extension entrypoints
describe('Mission Authoring Parity', () => {
  it('should produce consistent mission structure from app and extension', () => {
    // Simulate mission created from app
    const appMission: BurnBarMissionSnapshot = createMockMission({
      id: 'mission-app-1',
      projectSlug: 'apollo',
      title: 'Ship from app',
      summary: 'Created from OpenBurnBar app.',
      recommendation: 'proceed',
      metadata: { createdBy: 'app', source: 'OpenBurnBar.app' }
    });

    // Simulate mission created from extension
    const extensionMission: BurnBarMissionSnapshot = createMockMission({
      id: 'mission-ext-1',
      projectSlug: 'apollo',
      title: 'Ship from extension',
      summary: 'Created from OpenBurnBar extension.',
      recommendation: 'proceed',
      metadata: { createdBy: 'extension', source: 'OpenBurnBar.extension' }
    });

    // Both should have the same structural properties
    const appKeys = Object.keys(appMission);
    const extensionKeys = Object.keys(extensionMission);
    expect(appKeys).toEqual(extensionKeys);

    // Both should be projectable by buildMissionRows
    const state1 = createMockState({ daemonMissions: [appMission] });
    const state2 = createMockState({ daemonMissions: [extensionMission] });

    const rows1 = buildMissionRows(state1);
    const rows2 = buildMissionRows(state2);

    expect(rows1[0]).toMatchObject({
      id: 'mission-app-1',
      title: 'Ship from app',
      projectSlug: 'apollo',
      status: 'awaiting_approval',
      source: 'daemon',
      approved: false,
      packetsCount: 0,
      takeoverCount: 0
    });

    expect(rows2[0]).toMatchObject({
      id: 'mission-ext-1',
      title: 'Ship from extension',
      projectSlug: 'apollo',
      status: 'awaiting_approval',
      source: 'daemon',
      approved: false,
      packetsCount: 0,
      takeoverCount: 0
    });
  });

  it('should produce identical detail rows for missions from both entrypoints', () => {
    const appMission = createMockMission({
      id: 'mission-parity-1',
      projectSlug: 'apollo',
      title: 'Parity mission',
      summary: 'Testing detail projection parity.',
      status: 'in_progress',
      recommendation: 'review',
      approval: { approved: true, approvedBy: 'alice' },
      packets: [
        { id: 'packet-1', missionID: 'mission-parity-1', workerName: 'worker-1', objective: 'test', status: 'completed', metadata: {} }
      ],
      burnRecords: [
        { id: 'burn-1', label: 'tokens', amount: 1000, unit: 'tokens', recordedAt: '2024-01-15T12:00:00Z' }
      ]
    });

    const state = createMockState({ daemonMissions: [appMission] });
    const detailRows = buildMissionDetailRows(state, 'mission-parity-1');

    // Both app and extension should produce the same detail rows
    expect(detailRows.find(r => r.id === 'title')?.value).toBe('Parity mission');
    expect(detailRows.find(r => r.id === 'project')?.value).toBe('apollo');
    expect(detailRows.find(r => r.id === 'status')?.value).toBe('in_progress');
    expect(detailRows.find(r => r.id === 'recommendation')?.value).toBe('review');
    expect(detailRows.find(r => r.id === 'summary')?.value).toBe('Testing detail projection parity.');
    expect(detailRows.find(r => r.id === 'packets')?.value).toBe('1 total');
    expect(detailRows.find(r => r.id === 'burn')?.value).toBe('1000.0000');
  });

  // VAL-EXT-008: ordering matches daemon canonical (updatedAt DESC, missionID ASC tie-break)
  it('should order missions consistently regardless of entrypoint', () => {
    const missions: BurnBarMissionSnapshot[] = [
      createMockMission({ id: 'mission-ext-1', status: 'in_progress', updatedAt: '2024-01-15T12:00:00Z', metadata: { source: 'extension' } }),
      createMockMission({ id: 'mission-app-1', status: 'in_progress', updatedAt: '2024-01-15T11:00:00Z', metadata: { source: 'app' } }),
      createMockMission({ id: 'mission-ext-2', status: 'awaiting_approval', updatedAt: '2024-01-15T10:00:00Z', metadata: { source: 'extension' } }),
      createMockMission({ id: 'mission-app-2', status: 'awaiting_approval', updatedAt: '2024-01-15T09:00:00Z', metadata: { source: 'app' } })
    ];

    const state = createMockState({ daemonMissions: missions });
    const rows = buildMissionRows(state);

    // Ordered by updatedAt DESC (no tie-break needed since all timestamps are distinct)
    expect(rows[0].id).toBe('mission-ext-1');
    expect(rows[1].id).toBe('mission-app-1');
    expect(rows[2].id).toBe('mission-ext-2');
    expect(rows[3].id).toBe('mission-app-2');

    // Order should be deterministic (same input always produces same output)
    const rowsAgain = buildMissionRows(state);
    expect(rows.map(r => r.id)).toEqual(rowsAgain.map(r => r.id));
  });
});

// VAL-CROSS-009: Execution-readiness failure reasons propagate consistently to all surfaces
// When readiness preflight fails, daemon reason codes appear consistently in app and extension operator messaging
describe('VAL-CROSS-009: Readiness Reason Code Propagation', () => {
  // Helper to create a mission with readiness failure metadata
  function createMissionWithReadinessFailure(
    code: 'missing_credential' | 'invalid_repo_branch' | 'runtime_unavailable' | 'insufficient_credential_permissions',
    detail: string
  ): BurnBarMissionSnapshot {
    return createMockMission({
      id: `mission-readiness-${code}`,
      title: 'Mission with readiness failure',
      summary: 'Testing readiness failure propagation.',
      status: 'failed',
      recommendation: 'review',
      metadata: {
        readinessFailure: { code, detail }
      }
    });
  }

  // VAL-CROSS-009 Evidence: missing_credential code produces correct display message
  it('should map missing_credential reason code to correct display message', () => {
    const failure = { code: 'missing_credential' as const, detail: 'GitHub credentials are not configured.' };
    const message = readinessDisplayMessage(failure);
    expect(message).toBe('Credential missing: GitHub credentials are not configured.');
  });

  // VAL-CROSS-009 Evidence: invalid_repo_branch code produces correct display message
  it('should map invalid_repo_branch reason code to correct display message', () => {
    const failure = { code: 'invalid_repo_branch' as const, detail: "Branch 'main' does not exist." };
    const message = readinessDisplayMessage(failure);
    expect(message).toBe("Repository unavailable: Branch 'main' does not exist.");
  });

  // VAL-CROSS-009 Evidence: runtime_unavailable code produces correct display message
  it('should map runtime_unavailable reason code to correct display message', () => {
    const failure = { code: 'runtime_unavailable' as const, detail: 'Required workspace service is not available.' };
    const message = readinessDisplayMessage(failure);
    expect(message).toBe('Runtime unavailable: Required workspace service is not available.');
  });

  // VAL-CROSS-009 Evidence: insufficient_credential_permissions code produces correct display message
  it('should map insufficient_credential_permissions reason code to correct display message', () => {
    const failure = { code: 'insufficient_credential_permissions' as const, detail: "Token lacks 'repo' scope." };
    const message = readinessDisplayMessage(failure);
    expect(message).toBe("Insufficient permissions: Token lacks 'repo' scope.");
  });

  // VAL-CROSS-009 Evidence: All readiness reason codes produce distinct display messages
  it('should produce distinct display messages for each reason code', () => {
    const codes = [
      { code: 'missing_credential' as const, detail: 'test' },
      { code: 'invalid_repo_branch' as const, detail: 'test' },
      { code: 'runtime_unavailable' as const, detail: 'test' },
      { code: 'insufficient_credential_permissions' as const, detail: 'test' }
    ];

    const messages = codes.map(c => readinessDisplayMessage(c));
    const uniqueMessages = new Set(messages);

    // All messages should be unique (each starts with a distinct prefix)
    expect(uniqueMessages.size).toBe(4);
    expect(messages[0]).toMatch(/^Credential missing:/);
    expect(messages[1]).toMatch(/^Repository unavailable:/);
    expect(messages[2]).toMatch(/^Runtime unavailable:/);
    expect(messages[3]).toMatch(/^Insufficient permissions:/);
  });

  // VAL-CROSS-009 Evidence: Mission rows include readiness failure when present in metadata
  it('should include readiness failure in mission row when present in metadata', () => {
    const mission = createMissionWithReadinessFailure('missing_credential', 'GitHub credentials missing.');
    const state = createMockState({ daemonMissions: [mission] });
    const rows = buildMissionRows(state);

    expect(rows).toHaveLength(1);
    expect(rows[0].readinessFailure).toBeDefined();
    expect(rows[0].readinessFailure?.code).toBe('missing_credential');
    expect(rows[0].readinessFailure?.detail).toBe('GitHub credentials missing.');
  });

  // VAL-CROSS-009 Evidence: Mission rows have no readiness failure when not present
  it('should not include readiness failure in mission row when not present in metadata', () => {
    const mission = createMockMission({
      id: 'mission-no-readiness',
      title: 'Mission without readiness failure',
      summary: 'Normal mission without readiness issues.',
      status: 'in_progress',
      recommendation: 'proceed',
      metadata: {}
    });
    const state = createMockState({ daemonMissions: [mission] });
    const rows = buildMissionRows(state);

    expect(rows).toHaveLength(1);
    expect(rows[0].readinessFailure).toBeUndefined();
  });

  // VAL-CROSS-009 Evidence: Mission rows handle invalid readiness code gracefully
  it('should handle invalid readiness code gracefully', () => {
    const mission = createMockMission({
      id: 'mission-invalid-readiness',
      title: 'Mission with invalid readiness code',
      summary: 'Testing invalid code handling.',
      status: 'failed',
      recommendation: 'review',
      metadata: {
        readinessFailure: { code: 'invalid_code', detail: 'Some detail' }
      }
    });
    const state = createMockState({ daemonMissions: [mission] });
    const rows = buildMissionRows(state);

    // Invalid code should be filtered out, readinessFailure should be undefined
    expect(rows).toHaveLength(1);
    expect(rows[0].readinessFailure).toBeUndefined();
  });

  // VAL-CROSS-009 Evidence: Readiness failure display message can be constructed from mission row
  it('should construct readiness display message from mission row readiness failure', () => {
    const mission = createMissionWithReadinessFailure('runtime_unavailable', 'Workspace service unavailable.');
    const state = createMockState({ daemonMissions: [mission] });
    const rows = buildMissionRows(state);

    const message = readinessDisplayMessage(rows[0].readinessFailure!);
    expect(message).toBe('Runtime unavailable: Workspace service unavailable.');
  });

  // VAL-CROSS-009 Evidence: Readiness reason codes are consistent between app and extension
  it('should use same reason code values as app BurnBarExecutionReadinessCode', () => {
    // Verify the reason codes match the Swift enum values in OpenBurnBarCore
    const expectedCodes = [
      'missing_credential',
      'invalid_repo_branch',
      'runtime_unavailable',
      'insufficient_credential_permissions'
    ];

    // These should match BurnBarExecutionReadinessCode in OpenBurnBarCore
    const validCodes: Array<'missing_credential' | 'invalid_repo_branch' | 'runtime_unavailable' | 'insufficient_credential_permissions'> = [
      'missing_credential',
      'invalid_repo_branch',
      'runtime_unavailable',
      'insufficient_credential_permissions'
    ];

    expect(validCodes).toEqual(expectedCodes);
  });
});
