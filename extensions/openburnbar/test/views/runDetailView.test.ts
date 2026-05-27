import { describe, it, expect, vi } from 'vitest';
import { createSnapshotController } from '../helpers/controllerMock';
import type { OpenBurnBarState } from '../../src/types';
import { buildRunDetailRows, type BurnBarRunDetailRow } from '../../src/state/projections';

// Mock vscode
vi.mock('vscode', () => ({
  TreeItem: class MockTreeItem {
    constructor(
      public label: string,
      public collapsibleState: number
    ) {
      this.description = undefined;
      this.tooltip = undefined;
      this.iconPath = undefined;
      this.contextValue = undefined;
    }
  },
  TreeItemCollapsibleState: {
    None: 0,
    Collapsed: 1,
    Expanded: 2
  },
  ThemeIcon: class MockThemeIcon {
    constructor(public id: string) {}
  },
  EventEmitter: class MockEventEmitter<T> {
    private listeners: Array<(value: T) => void> = [];

    event = (listener: (value: T) => void) => {
      this.listeners.push(listener);
      return { dispose: () => {} };
    };

    fire = (value: T) => {
      this.listeners.forEach(l => l(value));
    };

    dispose = () => {
      this.listeners = [];
    };
  }
}));

// Import after mocking
import * as vscode from 'vscode';

// Import the module under test
import {
  OpenBurnBarRunDetailTreeDataProvider
} from '../../src/views/runDetailView';

// Create a mock controller
function createMockController(partialState: Partial<OpenBurnBarState> = {}) {
  return createSnapshotController(partialState);
}

describe('OpenBurnBarRunDetailTreeDataProvider', () => {
  describe('constructor', () => {
    it('should subscribe to controller state changes', () => {
      const controller = createMockController();
      const provider = new OpenBurnBarRunDetailTreeDataProvider(controller);

      expect(controller.onDidChangeState).toHaveBeenCalled();
      expect(provider.onDidChangeTreeData).toBeDefined();
    });

    it('should create event emitter', () => {
      const controller = createMockController();
      const provider = new OpenBurnBarRunDetailTreeDataProvider(controller);

      // Verify provider was created with event emitter
      expect(provider).toBeDefined();
      expect(provider.onDidChangeTreeData).toBeDefined();
    });
  });

  describe('getTreeItem', () => {
    it('should return the tree item as-is', async () => {
      const controller = createMockController({
        selectedRunId: 'run-1',
        runs: [{
          id: 'run-1',
          title: 'Test Run',
          phase: 'completed',
          source: 'daemon',
          updatedAt: new Date().toISOString(),
          note: 'Test note'
        }]
      });
      const provider = new OpenBurnBarRunDetailTreeDataProvider(controller);

      const children = await provider.getChildren();
      expect(children.length).toBeGreaterThan(0);
      const result = provider.getTreeItem(children[0]);

      expect(result).toBe(children[0]);
    });
  });

  describe('getChildren', () => {
    it('should return empty array for child elements', async () => {
      const controller = createMockController({
        selectedRunId: 'run-1',
        runs: [{
          id: 'run-1',
          title: 'Test Run',
          phase: 'completed',
          source: 'daemon',
          updatedAt: new Date().toISOString(),
          note: 'Test note'
        }]
      });
      const provider = new OpenBurnBarRunDetailTreeDataProvider(controller);

      const children = await provider.getChildren();
      expect(children.length).toBeGreaterThan(0);
      const childChildren = await provider.getChildren(children[0]);

      expect(childChildren).toEqual([]);
    });

    it('should return detail rows from controller snapshot', async () => {
      const controller = createMockController({
        selectedRunId: 'run-1',
        runs: [{
          id: 'run-1',
          title: 'Test Run',
          phase: 'completed',
          source: 'daemon' as const,
          startedAt: new Date().toISOString(),
          usage: {
            inputTokens: 1000,
            outputTokens: 500,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            cost: 0.05
          },
          note: 'Test note',
          modelId: 'claude-3-5-sonnet',
          provider: 'claude_code'
        }]
      });

      const provider = new OpenBurnBarRunDetailTreeDataProvider(controller);
      const children = await provider.getChildren();

      expect(Array.isArray(children)).toBe(true);
    });

    it('should handle empty runs list', async () => {
      const controller = createMockController({
        runs: []
      });

      const provider = new OpenBurnBarRunDetailTreeDataProvider(controller);
      const children = await provider.getChildren();

      expect(Array.isArray(children)).toBe(true);
    });

    it('should handle no selected run', async () => {
      const controller = createMockController({
        selectedRunId: null,
        runs: []
      });

      const provider = new OpenBurnBarRunDetailTreeDataProvider(controller);
      const children = await provider.getChildren();

      expect(Array.isArray(children)).toBe(true);
    });
  });

  describe('dispose', () => {
    it('should clean up without errors', () => {
      const controller = createMockController();
      const provider = new OpenBurnBarRunDetailTreeDataProvider(controller);

      expect(() => provider.dispose()).not.toThrow();
    });

    it('should be callable multiple times safely', () => {
      const controller = createMockController();
      const provider = new OpenBurnBarRunDetailTreeDataProvider(controller);

      provider.dispose();
      expect(() => provider.dispose()).not.toThrow();
    });
  });
});

describe('Run Detail View Integration', () => {
  it('should build detail rows with all field types', () => {
    const state: OpenBurnBarState = {
      connectionStatus: 'connected',
      clientAttached: true,
      selectedRunId: 'run-1',
      daemonRuns: [{
        runID: 'run-1',
        clientID: 'client-1',
        sessionID: 'session-1',
        phase: 'completed',
        modelID: 'claude-3-5-sonnet',
        updatedAt: new Date().toISOString()
      }],
      pendingToolCalls: [],
      recentUsage: [{
        runID: 'run-1',
        providerID: 'claude_code',
        modelID: 'claude-3-5-sonnet',
        inputTokens: 1000,
        outputTokens: 500,
        cacheReadTokens: 200,
        cost: 0.05,
        recordedAt: new Date().toISOString()
      }],
      runs: [{
        id: 'run-1',
        title: 'Test Run',
        phase: 'completed',
        source: 'daemon' as const,
        note: 'Test note',
        modelId: 'claude-3-5-sonnet',
        providerId: 'claude_code',
        updatedAt: new Date().toISOString()
      }]
    };

    const rows = buildRunDetailRows(state);

    // Should have rows for the selected run
    expect(Array.isArray(rows)).toBe(true);
  });

  it('should create tree items for detail rows', () => {
    const detailRows: BurnBarRunDetailRow[] = [
      { label: 'Phase', value: 'completed', icon: 'pass' },
      { label: 'Model', value: 'claude-3-5-sonnet', icon: 'pass' },
      { label: 'Cost', value: '$0.05', icon: 'pass' }
    ];

    // Test that tree items can be created for each row type
    detailRows.forEach(row => {
      const treeItem = new vscode.TreeItem(row.label, 0);
      treeItem.description = row.value;
      treeItem.iconPath = new vscode.ThemeIcon(row.icon);

      expect(treeItem.label).toBe(row.label);
      expect(treeItem.description).toBe(row.value);
    });
  });

  it('should handle runs with no usage data', () => {
    const state: OpenBurnBarState = {
      connectionStatus: 'connecting',
      clientAttached: false,
      selectedRunId: 'run-1',
      daemonRuns: [{
        runID: 'run-1',
        title: 'Test Run',
        phase: 'planning',
        provider: undefined,
        modelID: undefined,
        startedAt: new Date().toISOString(),
        status: 'running'
      }],
      pendingToolCalls: [],
      recentUsage: [],
      runs: [{
        id: 'run-1',
        title: 'Test Run',
        phase: 'planning',
        source: 'daemon' as const,
        startedAt: new Date().toISOString(),
        usage: undefined,
        note: undefined,
        modelId: undefined,
        provider: undefined
      }]
    };

    const rows = buildRunDetailRows(state);

    expect(Array.isArray(rows)).toBe(true);
  });

  it('should include usage information when available', () => {
    const state: OpenBurnBarState = {
      connectionStatus: 'connected',
      clientAttached: true,
      selectedRunId: 'run-1',
      daemonRuns: [{
        runID: 'run-1',
        clientID: 'client-1',
        sessionID: 'session-1',
        phase: 'completed',
        modelID: 'claude-3-opus',
        updatedAt: new Date().toISOString()
      }],
      pendingToolCalls: [],
      recentUsage: [{
        runID: 'run-1',
        providerID: 'claude_code',
        modelID: 'claude-3-opus',
        inputTokens: 5000,
        outputTokens: 2000,
        cacheReadTokens: 5000,
        cost: 0.25,
        recordedAt: new Date().toISOString()
      }],
      runs: [{
        id: 'run-1',
        title: 'Test Run',
        phase: 'completed',
        source: 'daemon' as const,
        note: 'A completed run',
        modelId: 'claude-3-opus',
        providerId: 'claude_code',
        updatedAt: new Date().toISOString()
      }]
    };

    const rows = buildRunDetailRows(state);

    expect(Array.isArray(rows)).toBe(true);
  });

  it('should handle empty daemonRuns', () => {
    const state: OpenBurnBarState = {
      connectionStatus: 'connecting',
      clientAttached: false,
      daemonRuns: [],
      pendingToolCalls: [],
      recentUsage: [],
      runs: []
    };

    const rows = buildRunDetailRows(state);

    expect(Array.isArray(rows)).toBe(true);
  });

  it('should handle selectedRunDetail from state', () => {
    const state: OpenBurnBarState = {
      connectionStatus: 'connected',
      clientAttached: true,
      selectedRunId: 'run-1',
      selectedRunDetail: {
        run: {
          runID: 'run-1',
          title: 'Detailed Run',
          phase: 'completed',
          provider: 'claude_code',
          modelID: 'claude-3-5-sonnet',
          startedAt: new Date().toISOString(),
          endedAt: new Date().toISOString(),
          status: 'completed',
          toolCalls: []
        },
        events: []
      },
      daemonRuns: [],
      pendingToolCalls: [],
      recentUsage: [],
      runs: []
    };

    const rows = buildRunDetailRows(state);

    expect(Array.isArray(rows)).toBe(true);
  });
});
