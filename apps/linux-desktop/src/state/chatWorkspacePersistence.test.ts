import { describe, expect, it } from 'vitest';
import {
  CHAT_WORKSPACE_MAX_FRACTION,
  CHAT_WORKSPACE_MIN_FRACTION,
  CHAT_WORKSPACE_VERSION,
  clampChatWorkspaceFraction,
  collectPersistedPanes,
  createDefaultChatWorkspaceSnapshot,
  decodeChatWorkspaceSnapshot,
  encodeChatWorkspaceSnapshot,
  type ChatWorkspaceSnapshotV2,
  type PersistedChatPane
} from './chatWorkspacePersistence.js';

function ids() {
  let sequence = 0;
  return () => `generated-${++sequence}`;
}

function pane(id: string, isPrimary = false): PersistedChatPane {
  return {
    kind: 'leaf',
    id,
    threadID: `thread-${id}`,
    isPrimary,
    title: null,
    colorToken: null,
    backend: 'codex',
    modelLabel: 'gpt-5.4-codex',
    modelOptionID: 'gpt-5.4-codex',
    thinkingLevel: 'high',
    unseenCompletionAt: null,
    alertsEnabled: true
  };
}

function snapshot(overrides: Partial<ChatWorkspaceSnapshotV2> = {}): ChatWorkspaceSnapshotV2 {
  return {
    version: CHAT_WORKSPACE_VERSION,
    tabs: [{
      id: 'tab-1',
      title: null,
      colorToken: null,
      root: pane('pane-1', true),
      activePaneID: 'pane-1',
      zoomedPaneID: null
    }],
    selectedTabID: 'tab-1',
    closedTabs: [],
    ...overrides
  };
}

describe('chat workspace persistence', () => {
  it('creates one primary pane bound to the legacy selected thread', () => {
    const value = createDefaultChatWorkspaceSnapshot('thread-primary', ids());
    const leaves = collectPersistedPanes(value.tabs[0]!.root);

    expect(value.tabs).toHaveLength(1);
    expect(leaves).toEqual([
      expect.objectContaining({ threadID: 'thread-primary', isPrimary: true })
    ]);
    expect(value.tabs[0]!.activePaneID).toBe(leaves[0]!.id);
    expect(value.selectedTabID).toBe(value.tabs[0]!.id);
  });

  it('round-trips tabs, split fractions, pane metadata, zoom, and the closed-tab stack', () => {
    const value = snapshot({
      tabs: [{
        id: 'tab-main',
        title: 'Release work',
        colorToken: 'frost',
        root: {
          kind: 'split',
          id: 'split-main',
          axis: 'vertical',
          fraction: 0.64,
          first: pane('pane-primary', true),
          second: {
            ...pane('pane-secondary'),
            title: 'Logs',
            colorToken: 'amber',
            unseenCompletionAt: '2026-08-11T12:00:00.000Z',
            alertsEnabled: false
          }
        },
        activePaneID: 'pane-secondary',
        zoomedPaneID: 'pane-secondary'
      }],
      selectedTabID: 'tab-main',
      closedTabs: [{
        id: 'tab-closed',
        title: 'Closed',
        colorToken: 'ember',
        root: pane('pane-closed'),
        activePaneID: 'pane-closed',
        zoomedPaneID: null
      }]
    });

    const decoded = decodeChatWorkspaceSnapshot(encodeChatWorkspaceSnapshot(value), null, ids());

    expect(decoded).toEqual(value);
  });

  it('repairs missing and duplicate primary panes to exactly one', () => {
    const missing = snapshot({
      tabs: [{
        id: 'tab-1',
        title: null,
        colorToken: null,
        root: {
          kind: 'split',
          id: 'split-1',
          axis: 'horizontal',
          fraction: 0.5,
          first: pane('pane-1'),
          second: pane('pane-2')
        },
        activePaneID: 'pane-2',
        zoomedPaneID: null
      }]
    });
    const repairedMissing = decodeChatWorkspaceSnapshot(JSON.stringify(missing), null, ids());
    expect(collectPersistedPanes(repairedMissing.tabs[0]!.root).filter((leaf) => leaf.isPrimary)).toHaveLength(1);
    expect(collectPersistedPanes(repairedMissing.tabs[0]!.root)[0]!.isPrimary).toBe(true);

    const duplicate = structuredClone(missing);
    for (const leaf of collectPersistedPanes(duplicate.tabs[0]!.root)) leaf.isPrimary = true;
    const repairedDuplicate = decodeChatWorkspaceSnapshot(JSON.stringify(duplicate), null, ids());
    expect(collectPersistedPanes(repairedDuplicate.tabs[0]!.root).filter((leaf) => leaf.isPrimary)).toHaveLength(1);
  });

  it('repairs invalid selected, active, and zoomed identifiers', () => {
    const value = snapshot({
      tabs: [{
        id: 'tab-valid',
        title: null,
        colorToken: null,
        root: pane('pane-valid', true),
        activePaneID: 'missing-pane',
        zoomedPaneID: 'missing-pane'
      }],
      selectedTabID: 'missing-tab'
    });

    const decoded = decodeChatWorkspaceSnapshot(JSON.stringify(value), null, ids());

    expect(decoded.selectedTabID).toBe('tab-valid');
    expect(decoded.tabs[0]!.activePaneID).toBe('pane-valid');
    expect(decoded.tabs[0]!.zoomedPaneID).toBeNull();
  });

  it('clamps divider fractions and normalizes non-finite values', () => {
    expect(clampChatWorkspaceFraction(-10)).toBe(CHAT_WORKSPACE_MIN_FRACTION);
    expect(clampChatWorkspaceFraction(10)).toBe(CHAT_WORKSPACE_MAX_FRACTION);
    expect(clampChatWorkspaceFraction(Number.NaN)).toBe(0.5);

    const value = snapshot({
      tabs: [{
        id: 'tab-1',
        title: null,
        colorToken: null,
        root: {
          kind: 'split',
          id: 'split-1',
          axis: 'horizontal',
          fraction: 99,
          first: pane('pane-1', true),
          second: pane('pane-2')
        },
        activePaneID: 'pane-1',
        zoomedPaneID: null
      }]
    });
    const decoded = decodeChatWorkspaceSnapshot(JSON.stringify(value), null, ids());
    expect(decoded.tabs[0]!.root).toMatchObject({ kind: 'split', fraction: CHAT_WORKSPACE_MAX_FRACTION });
  });

  it('repairs duplicate node and tab identifiers without dropping panes', () => {
    const value = snapshot({
      tabs: [
        {
          id: 'duplicate-tab',
          title: null,
          colorToken: null,
          root: {
            kind: 'split',
            id: 'duplicate-node',
            axis: 'horizontal',
            fraction: 0.5,
            first: pane('duplicate-node', true),
            second: pane('duplicate-node')
          },
          activePaneID: 'duplicate-node',
          zoomedPaneID: null
        },
        {
          id: 'duplicate-tab',
          title: null,
          colorToken: null,
          root: pane('duplicate-node'),
          activePaneID: 'duplicate-node',
          zoomedPaneID: null
        }
      ]
    });

    const decoded = decodeChatWorkspaceSnapshot(JSON.stringify(value), null, ids());
    const tabIDs = decoded.tabs.map((tab) => tab.id);
    const paneIDs = decoded.tabs.flatMap((tab) => collectPersistedPanes(tab.root).map((leaf) => leaf.id));

    expect(new Set(tabIDs).size).toBe(tabIDs.length);
    expect(new Set(paneIDs).size).toBe(paneIDs.length);
    expect(paneIDs).toHaveLength(3);
  });

  it('sanitizes unsafe thread IDs, metadata, backend choices, and timestamps', () => {
    const unsafe = {
      ...pane('pane-1', true),
      threadID: `bad\nthread`,
      title: 'x'.repeat(81),
      colorToken: 'not-a-color',
      backend: 'untrusted-provider',
      modelLabel: 'x'.repeat(201),
      modelOptionID: '',
      thinkingLevel: 'impossible',
      unseenCompletionAt: 'not-a-date'
    };
    const value = snapshot({
      tabs: [{
        id: 'tab-1',
        title: '  Useful tab  ',
        colorToken: null,
        root: unsafe as PersistedChatPane,
        activePaneID: 'pane-1',
        zoomedPaneID: null
      }]
    });

    const decoded = decodeChatWorkspaceSnapshot(JSON.stringify(value), null, ids());
    const leaf = collectPersistedPanes(decoded.tabs[0]!.root)[0]!;

    expect(decoded.tabs[0]!.title).toBe('Useful tab');
    expect(leaf).toMatchObject({
      threadID: null,
      title: null,
      colorToken: null,
      backend: 'hermes',
      modelLabel: 'hermes',
      modelOptionID: 'hermes',
      thinkingLevel: 'default',
      unseenCompletionAt: null
    });
  });

  it('forces restored closed tabs to remain non-primary and bounded to five', () => {
    const closedTabs = Array.from({ length: 8 }, (_, index) => ({
      id: `closed-${index}`,
      title: null,
      colorToken: null,
      root: pane(`closed-pane-${index}`, true),
      activePaneID: `closed-pane-${index}`,
      zoomedPaneID: null
    }));
    const decoded = decodeChatWorkspaceSnapshot(JSON.stringify(snapshot({ closedTabs })), null, ids());

    expect(decoded.closedTabs).toHaveLength(5);
    expect(decoded.closedTabs.flatMap((tab) => collectPersistedPanes(tab.root)).every((leaf) => !leaf.isPrimary)).toBe(true);
  });

  it('falls back safely for malformed, unsupported, empty, or excessively deep snapshots', () => {
    const fallbackA = decodeChatWorkspaceSnapshot('{', 'thread-safe', ids());
    const fallbackB = decodeChatWorkspaceSnapshot(JSON.stringify({ version: 99, tabs: [] }), 'thread-safe', ids());
    const fallbackC = decodeChatWorkspaceSnapshot(JSON.stringify(snapshot({ tabs: [] })), 'thread-safe', ids());
    let deep: unknown = pane('deep-leaf', true);
    for (let depth = 0; depth < 10; depth += 1) {
      deep = {
        kind: 'split',
        id: `deep-${depth}`,
        axis: 'horizontal',
        fraction: 0.5,
        first: deep,
        second: pane(`deep-side-${depth}`)
      };
    }
    const fallbackD = decodeChatWorkspaceSnapshot(JSON.stringify(snapshot({
      tabs: [{
        id: 'deep-tab',
        title: null,
        colorToken: null,
        root: deep as PersistedChatPane,
        activePaneID: 'deep-leaf',
        zoomedPaneID: null
      }]
    })), 'thread-safe', ids());

    for (const value of [fallbackA, fallbackB, fallbackC, fallbackD]) {
      const leaves = collectPersistedPanes(value.tabs[0]!.root);
      expect(leaves).toHaveLength(1);
      expect(leaves[0]).toMatchObject({ threadID: 'thread-safe', isPrimary: true });
    }
  });
});
