import { describe, it, expect, vi } from 'vitest';
import type { OpenBurnBarState } from '../../src/types';
import { buildHealthRows, type BurnBarHealthRow } from '../../src/state/projections';
import { createSnapshotController, createTestState } from '../helpers/controllerMock';

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
  OpenBurnBarHealthTreeDataProvider
} from '../../src/views/healthView';

// Create a minimal mock state
function createMinimalState(partial: Partial<OpenBurnBarState> = {}): OpenBurnBarState {
  return createTestState(partial);
}

// Create a mock controller
function createMockController(partialState: Partial<OpenBurnBarState> = {}) {
  return createSnapshotController(partialState);
}

describe('OpenBurnBarHealthTreeDataProvider', () => {
  describe('constructor', () => {
    it('should subscribe to controller state changes', () => {
      const controller = createMockController();
      const provider = new OpenBurnBarHealthTreeDataProvider(controller);

      expect(controller.onDidChangeState).toHaveBeenCalled();
      expect(provider.onDidChangeTreeData).toBeDefined();
    });

    it('should create event emitter', () => {
      const controller = createMockController();
      const provider = new OpenBurnBarHealthTreeDataProvider(controller);

      // Verify provider was created with event emitter
      expect(provider).toBeDefined();
      expect(provider.onDidChangeTreeData).toBeDefined();
    });
  });

  describe('getTreeItem', () => {
    it('should return the tree item as-is', async () => {
      const controller = createMockController({ connectionStatus: 'connected', clientAttached: true });
      const provider = new OpenBurnBarHealthTreeDataProvider(controller);
      const [mockItem] = await provider.getChildren();
      expect(mockItem).toBeDefined();
      const result = provider.getTreeItem(mockItem);
      expect(result).toBe(mockItem);
    });
  });

  describe('getChildren', () => {
    it('should return empty array for child elements', async () => {
      const controller = createMockController({ connectionStatus: 'connected', clientAttached: true });
      const provider = new OpenBurnBarHealthTreeDataProvider(controller);
      const [mockItem] = await provider.getChildren();
      expect(mockItem).toBeDefined();
      const children = await provider.getChildren(mockItem);

      expect(children).toEqual([]);
    });

    it('should return health rows from controller snapshot', async () => {
      const controller = createMockController({
        connectionStatus: 'connected',
        clientAttached: true
      });

      const provider = new OpenBurnBarHealthTreeDataProvider(controller);
      const children = await provider.getChildren();

      expect(Array.isArray(children)).toBe(true);
    });

    it('should handle disconnected state', async () => {
      const controller = createMockController({
        connectionStatus: 'disconnected'
      });

      const provider = new OpenBurnBarHealthTreeDataProvider(controller);
      const children = await provider.getChildren();

      expect(Array.isArray(children)).toBe(true);
    });

    it('should handle connecting state', async () => {
      const controller = createMockController({
        connectionStatus: 'connecting'
      });

      const provider = new OpenBurnBarHealthTreeDataProvider(controller);
      const children = await provider.getChildren();

      expect(Array.isArray(children)).toBe(true);
    });
  });

  describe('dispose', () => {
    it('should clean up without errors', () => {
      const controller = createMockController();
      const provider = new OpenBurnBarHealthTreeDataProvider(controller);

      expect(() => provider.dispose()).not.toThrow();
    });

    it('should be callable multiple times safely', () => {
      const controller = createMockController();
      const provider = new OpenBurnBarHealthTreeDataProvider(controller);

      provider.dispose();
      expect(() => provider.dispose()).not.toThrow();
    });
  });
});

describe('Health View Integration', () => {
  it('should build health rows for connected state', () => {
    const rows = buildHealthRows(createMinimalState({
      connectionStatus: 'connected',
      clientAttached: true
    }));

    expect(Array.isArray(rows)).toBe(true);
  });

  it('should build health rows for disconnected state', () => {
    const rows = buildHealthRows(createMinimalState({ connectionStatus: 'disconnected' }));

    expect(Array.isArray(rows)).toBe(true);
  });

  it('should build health rows for connecting state', () => {
    const rows = buildHealthRows(createMinimalState({ connectionStatus: 'connecting' }));

    expect(Array.isArray(rows)).toBe(true);
  });

  it('should build health rows with health data', () => {
    const rows = buildHealthRows(createMinimalState({
      connectionStatus: 'connected',
      clientAttached: true,
      health: {
        parserHealth: [
          { provider: 'claude_code', healthy: true, message: 'OK' },
          { provider: 'factory', healthy: true, message: 'OK' }
        ]
      }
    }));

    expect(Array.isArray(rows)).toBe(true);
    // Should have pass icons for healthy parsers
    const passIcons = rows.filter(r => r.icon === 'pass');
    expect(passIcons.length).toBeGreaterThan(0);
  });

  it('should build health rows with unhealthy parsers', () => {
    const rows = buildHealthRows(createMinimalState({
      connectionStatus: 'connected',
      health: {
        parserHealth: [
          { provider: 'claude_code', healthy: true, message: 'OK' },
          { provider: 'factory', healthy: false, message: 'Parser error' }
        ]
      }
    }));

    expect(Array.isArray(rows)).toBe(true);
    // Should have at least one warning
    const warningIcons = rows.filter(r => r.icon === 'warning');
    expect(warningIcons.length).toBeGreaterThan(0);
  });

  it('should create tree items for health rows', () => {
    const healthRows: BurnBarHealthRow[] = [
      { label: 'Parser Health', value: '3/3', icon: 'pass', tooltip: 'All parsers working' },
      { label: 'Daemon', value: 'Connected', icon: 'pass', tooltip: 'v1.0.0' },
      { label: 'Warning', value: 'Issue', icon: 'warning', tooltip: 'Some issue' },
      { label: 'Note', value: 'Info', icon: 'note' }
    ];

    // Test that tree items can be created for each row type
    healthRows.forEach(row => {
      const treeItem = new vscode.TreeItem(row.label, 0);
      treeItem.description = row.value;
      treeItem.iconPath = new vscode.ThemeIcon(row.icon);

      expect(treeItem.label).toBe(row.label);
      expect(treeItem.description).toBe(row.value);
    });
  });

  it('should handle state with lastError', () => {
    const rows = buildHealthRows(createMinimalState({
      connectionStatus: 'error',
      lastError: 'Connection refused'
    }));

    expect(Array.isArray(rows)).toBe(true);
    // Should have warning icons for error state
    const warningIcons = rows.filter(r => r.icon === 'warning');
    expect(warningIcons.length).toBeGreaterThan(0);
  });

  it('should handle state with runError', () => {
    const rows = buildHealthRows(createMinimalState({
      connectionStatus: 'connected',
      runError: 'Run failed'
    }));

    expect(Array.isArray(rows)).toBe(true);
  });
});
