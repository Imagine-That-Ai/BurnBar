import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { OpenBurnBarControllerSnapshotSource } from '../../src/state/controller';
import type { BurnBarRunProjection } from '../../src/types';
import { createSnapshotController } from '../helpers/controllerMock';
import { themeIconId } from '../helpers/vscodeTestHelpers';

// Mock vscode
vi.mock('vscode', () => ({
  TreeItem: class MockTreeItem {
    constructor(
      public label: string,
      public collapsibleState: number
    ) {
      this.id = undefined;
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
  OpenBurnBarRunTreeItem,
  OpenBurnBarRunListTreeDataProvider
} from '../../src/views/runListView';

describe('OpenBurnBarRunTreeItem', () => {
  it('should create tree item with run title', () => {
    const run = createMockRun({ title: 'Test Run' });
    const item = new OpenBurnBarRunTreeItem(run);

    expect(item.label).toBe('Test Run');
  });

  it('should use run id as item id', () => {
    const run = createMockRun({ id: 'run-123' });
    const item = new OpenBurnBarRunTreeItem(run);

    expect(item.id).toBe('run-123');
  });

  it('should set tooltip from run note', () => {
    const run = createMockRun({ note: 'Test note tooltip' });
    const item = new OpenBurnBarRunTreeItem(run);

    expect(item.tooltip).toBe('Test note tooltip');
  });

  it('should set context value for daemon source', () => {
    const run = createMockRun({ source: 'daemon' });
    const item = new OpenBurnBarRunTreeItem(run);

    expect(item.contextValue).toBe('openburnbar.run.daemon');
  });

  it('should set context value for projected source', () => {
    const run = createMockRun({ source: 'projected' });
    const item = new OpenBurnBarRunTreeItem(run);

    expect(item.contextValue).toBe('openburnbar.run.projected');
  });

  describe('icon mapping', () => {
    it('should map completed phase to pass icon', () => {
      const run = createMockRun({ phase: 'completed' });
      const item = new OpenBurnBarRunTreeItem(run);

      expect(item.iconPath).toBeInstanceOf(vscode.ThemeIcon);
      expect(themeIconId(item.iconPath)).toBe('pass');
    });

    it('should map failed phase to warning icon', () => {
      const run = createMockRun({ phase: 'failed' });
      const item = new OpenBurnBarRunTreeItem(run);

      expect(item.iconPath).toBeInstanceOf(vscode.ThemeIcon);
      expect(themeIconId(item.iconPath)).toBe('warning');
    });

    it('should map waiting_on_companion phase to clock icon', () => {
      const run = createMockRun({ phase: 'waiting_on_companion' });
      const item = new OpenBurnBarRunTreeItem(run);

      expect(item.iconPath).toBeInstanceOf(vscode.ThemeIcon);
      expect(themeIconId(item.iconPath)).toBe('clock');
    });

    it('should map planning phase to pulse icon', () => {
      const run = createMockRun({ phase: 'planning' });
      const item = new OpenBurnBarRunTreeItem(run);

      expect(item.iconPath).toBeInstanceOf(vscode.ThemeIcon);
      expect(themeIconId(item.iconPath)).toBe('pulse');
    });

    it('should map model_streaming phase to pulse icon', () => {
      const run = createMockRun({ phase: 'model_streaming' });
      const item = new OpenBurnBarRunTreeItem(run);

      expect(item.iconPath).toBeInstanceOf(vscode.ThemeIcon);
      expect(themeIconId(item.iconPath)).toBe('pulse');
    });

    it('should map executing_tool phase to pulse icon', () => {
      const run = createMockRun({ phase: 'executing_tool' });
      const item = new OpenBurnBarRunTreeItem(run);

      expect(item.iconPath).toBeInstanceOf(vscode.ThemeIcon);
      expect(themeIconId(item.iconPath)).toBe('pulse');
    });

    it('should map cancelled phase to circle-slash icon', () => {
      const run = createMockRun({ phase: 'cancelled' });
      const item = new OpenBurnBarRunTreeItem(run);

      expect(item.iconPath).toBeInstanceOf(vscode.ThemeIcon);
      expect(themeIconId(item.iconPath)).toBe('circle-slash');
    });

    it('should map awaiting_approval phase to question icon', () => {
      const run = createMockRun({ phase: 'awaiting_approval' });
      const item = new OpenBurnBarRunTreeItem(run);

      expect(item.iconPath).toBeInstanceOf(vscode.ThemeIcon);
      expect(themeIconId(item.iconPath)).toBe('question');
    });

    it('should map idle phase to circle-large-outline icon', () => {
      const run = createMockRun({ phase: 'idle' });
      const item = new OpenBurnBarRunTreeItem(run);

      expect(item.iconPath).toBeInstanceOf(vscode.ThemeIcon);
      expect(themeIconId(item.iconPath)).toBe('circle-large-outline');
    });
  });

  describe('description', () => {
    it('should include phase and modelId for daemon runs', () => {
      const run = createMockRun({
        source: 'daemon',
        phase: 'completed',
        modelId: 'claude-3-5-sonnet'
      });
      const item = new OpenBurnBarRunTreeItem(run);

      expect(item.description).toContain('completed');
      expect(item.description).toContain('claude-3-5-sonnet');
    });

    it('should include phase and shell for projected runs', () => {
      const run = createMockRun({
        source: 'projected',
        phase: 'planning'
      });
      const item = new OpenBurnBarRunTreeItem(run);

      expect(item.description).toContain('planning');
      expect(item.description).toContain('shell');
    });

    it('should replace underscores in phase with spaces', () => {
      const run = createMockRun({
        source: 'daemon',
        phase: 'waiting_on_companion'
      });
      const item = new OpenBurnBarRunTreeItem(run);

      expect(item.description).not.toContain('_');
      expect(item.description).toContain('waiting on companion');
    });
  });
});

describe('OpenBurnBarRunListTreeDataProvider', () => {
  let mockController: OpenBurnBarControllerSnapshotSource;
  let provider: OpenBurnBarRunListTreeDataProvider;

  beforeEach(() => {
    mockController = createSnapshotController({ runs: [] });

    provider = new OpenBurnBarRunListTreeDataProvider(mockController);
  });

  describe('constructor', () => {
    it('should subscribe to controller state changes', () => {
      expect(mockController.onDidChangeState).toHaveBeenCalled();
    });

    it('should create event emitter', () => {
      expect(provider.onDidChangeTreeData).toBeDefined();
    });
  });

  describe('getTreeItem', () => {
    it('should return the tree item as-is', () => {
      const run = createMockRun({ title: 'Test Run' });
      const treeItem = new OpenBurnBarRunTreeItem(run);

      const result = provider.getTreeItem(treeItem);

      expect(result).toBe(treeItem);
    });
  });

  describe('getChildren', () => {
    it('should return empty array for child elements', async () => {
      const run = createMockRun({ title: 'Test Run' });
      const treeItem = new OpenBurnBarRunTreeItem(run);

      const children = await provider.getChildren(treeItem);

      expect(children).toEqual([]);
    });

    it('should return runs from controller snapshot', async () => {
      const runs = [
        createMockRun({ id: 'run-1', title: 'Run 1' }),
        createMockRun({ id: 'run-2', title: 'Run 2' })
      ];
      mockController.snapshot = createMockState(runs);

      const children = await provider.getChildren();

      expect(children.length).toBe(2);
      children.forEach(item => {
        expect(item).toBeInstanceOf(OpenBurnBarRunTreeItem);
      });
    });

    it('should handle empty runs list', async () => {
      mockController.snapshot = createMockState([]);

      const children = await provider.getChildren();

      expect(children).toEqual([]);
    });

    it('should handle multiple runs', async () => {
      const runs = Array.from({ length: 5 }, (_, i) =>
        createMockRun({ id: `run-${i}`, title: `Run ${i}` })
      );
      mockController.snapshot = createMockState(runs);

      const children = await provider.getChildren();

      expect(children.length).toBe(5);
    });
  });

  describe('dispose', () => {
    it('should clean up without errors', () => {
      // dispose should not throw
      expect(() => provider.dispose()).not.toThrow();
    });

    it('should be callable multiple times safely', () => {
      provider.dispose();
      expect(() => provider.dispose()).not.toThrow();
    });
  });
});

describe('Run List View Integration', () => {
  it('should create tree items for all run phases', () => {
    const phases: BurnBarRunProjection['phase'][] = [
      'completed', 'failed', 'waiting_on_companion', 'planning',
      'model_streaming', 'executing_tool', 'cancelled', 'awaiting_approval', 'idle'
    ];

    phases.forEach(phase => {
      const run = createMockRun({ phase });
      const item = new OpenBurnBarRunTreeItem(run);

      expect(item.iconPath).toBeInstanceOf(vscode.ThemeIcon);
    });
  });

  it('should handle mixed run sources', () => {
    const runs = [
      createMockRun({ id: 'run-1', source: 'daemon' }),
      createMockRun({ id: 'run-2', source: 'projected' })
    ];

    const items = runs.map(run => new OpenBurnBarRunTreeItem(run));

    expect(items[0].contextValue).toBe('openburnbar.run.daemon');
    expect(items[1].contextValue).toBe('openburnbar.run.projected');
  });
});

// Helper functions

function createMockRun(overrides: Partial<BurnBarRunProjection>): BurnBarRunProjection {
  return {
    id: 'run-default',
    title: 'Default Run',
    phase: 'idle',
    source: 'daemon',
    startedAt: new Date().toISOString(),
    usage: undefined,
    note: undefined,
    modelId: undefined,
    provider: undefined,
    ...overrides
  };
}

function createMockState(runs: BurnBarRunProjection[]): OpenBurnBarState {
  return {
    connected: true,
    workspaceTrusted: true,
    daemonVersion: '1.0.0',
    daemonStatus: 'connected',
    runs,
    approval: null,
    panelVisible: false,
    theme: 'dark' as const,
    runsLoading: false
  };
}
