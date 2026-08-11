import { afterEach, describe, expect, it } from 'vitest';
import { createChatController, type ChatControllerStore } from './chatStore.js';
import { resetChatRuntimeForTests } from './chatRuntime.js';
import {
  activeChatWorkspacePane,
  allChatWorkspacePanes,
  collectChatWorkspacePanes,
  createChatWorkspaceStore,
  selectedChatWorkspaceTab,
  type ChatWorkspaceSplit
} from './chatWorkspaceStore.js';

class MemoryStorage implements Pick<Storage, 'getItem' | 'setItem' | 'removeItem'> {
  private values = new Map<string, string>();

  getItem(key: string): string | null {
    return this.values.get(key) ?? null;
  }

  setItem(key: string, value: string): void {
    this.values.set(key, value);
  }

  removeItem(key: string): void {
    this.values.delete(key);
  }
}

function ids() {
  let sequence = 0;
  return () => `id-${++sequence}`;
}

function primary(controllerID = 'workspace-primary'): ChatControllerStore {
  const controller = createChatController({ activeThreadStorageKey: null, controllerID });
  controller.setState({
    selectedThreadId: 'thread-primary',
    backend: 'codex',
    modelLabel: 'gpt-5.4-codex',
    modelOptionID: 'gpt-5.4-codex',
    thinkingLevel: 'high'
  });
  return controller;
}

afterEach(() => {
  resetChatRuntimeForTests();
});

describe('chat workspace store', () => {
  it('starts with one indestructible primary pane', () => {
    const primaryController = primary();
    const workspace = createChatWorkspaceStore({
      primaryController,
      storage: new MemoryStorage(),
      idFactory: ids()
    });

    expect(workspace.getState().tabs).toHaveLength(1);
    expect(allChatWorkspacePanes(workspace.getState())).toEqual([
      expect.objectContaining({ isPrimary: true, controller: primaryController })
    ]);
    expect(workspace.getState().performCloseShortcut()).toBe(false);
    expect(workspace.getState().tabs).toHaveLength(1);
    workspace.getState().dispose();
    expect(primaryController.getState().disposed).toBe(false);
  });

  it('splits horizontally and vertically with isolated controllers and inherited controls', () => {
    const primaryController = primary();
    const workspace = createChatWorkspaceStore({
      primaryController,
      storage: new MemoryStorage(),
      idFactory: ids()
    });

    workspace.getState().splitActive('horizontal');
    let tab = selectedChatWorkspaceTab(workspace.getState());
    expect(tab.root).toMatchObject({ kind: 'split', axis: 'horizontal', fraction: 0.5 });
    expect(collectChatWorkspacePanes(tab.root)).toHaveLength(2);
    const second = activeChatWorkspacePane(workspace.getState())!;
    expect(second.isPrimary).toBe(false);
    expect(second.controller).not.toBe(primaryController);
    expect(second.controller.getState()).toMatchObject({
      selectedThreadId: null,
      backend: 'codex',
      modelLabel: 'gpt-5.4-codex',
      thinkingLevel: 'high'
    });

    workspace.getState().splitActive('vertical');
    tab = selectedChatWorkspaceTab(workspace.getState());
    expect(collectChatWorkspacePanes(tab.root)).toHaveLength(3);
    expect(collectChatWorkspacePanes(tab.root).filter((pane) => pane.isPrimary)).toHaveLength(1);
    const nested = tab.root as ChatWorkspaceSplit;
    expect(nested.second).toMatchObject({ kind: 'split', axis: 'vertical' });
    workspace.getState().dispose();
  });

  it('closes a non-primary pane and reflows its sibling', () => {
    const primaryController = primary();
    const workspace = createChatWorkspaceStore({
      primaryController,
      storage: new MemoryStorage(),
      idFactory: ids()
    });
    workspace.getState().splitActive('horizontal');
    const closing = activeChatWorkspacePane(workspace.getState())!;

    workspace.getState().closeActive();

    const panes = allChatWorkspacePanes(workspace.getState());
    expect(panes).toHaveLength(1);
    expect(panes[0]).toMatchObject({ isPrimary: true, controller: primaryController });
    expect(closing.controller.getState().disposed).toBe(true);
    workspace.getState().dispose();
  });

  it('re-homes the primary controller when its pane closes', () => {
    const primaryController = primary();
    const workspace = createChatWorkspaceStore({
      primaryController,
      storage: new MemoryStorage(),
      idFactory: ids()
    });
    const primaryPaneID = activeChatWorkspacePane(workspace.getState())!.id;
    workspace.getState().splitActive('horizontal');
    const survivor = activeChatWorkspacePane(workspace.getState())!;
    survivor.controller.setState({
      selectedThreadId: 'thread-survivor',
      backend: 'claude',
      modelLabel: 'claude-sonnet-4',
      modelOptionID: 'claude-sonnet-4',
      thinkingLevel: 'medium',
      messages: [{ id: 'survivor-message', role: 'assistant', text: 'Keep me', threadID: 'thread-survivor' }]
    });
    workspace.getState().setActive(primaryPaneID);

    workspace.getState().closeActive();

    const pane = activeChatWorkspacePane(workspace.getState())!;
    expect(allChatWorkspacePanes(workspace.getState())).toHaveLength(1);
    expect(pane.controller).toBe(primaryController);
    expect(pane.isPrimary).toBe(true);
    expect(primaryController.getState()).toMatchObject({
      selectedThreadId: 'thread-survivor',
      backend: 'claude',
      modelLabel: 'claude-sonnet-4'
    });
    expect(primaryController.getState().messages).toEqual([
      expect.objectContaining({ id: 'survivor-message', text: 'Keep me' })
    ]);
    expect(survivor.controller.getState().disposed).toBe(true);
    workspace.getState().dispose();
  });

  it('supports tabs, adjacent selection, close, and LIFO reopen without duplicating primary', () => {
    const primaryController = primary();
    const workspace = createChatWorkspaceStore({
      primaryController,
      storage: new MemoryStorage(),
      idFactory: ids()
    });
    const firstTabID = workspace.getState().selectedTabID;
    workspace.getState().newTab();
    const secondTabID = workspace.getState().selectedTabID;
    workspace.getState().renameTab(secondTabID, 'Second');
    workspace.getState().newTab();
    const thirdTabID = workspace.getState().selectedTabID;
    workspace.getState().renameTab(thirdTabID, 'Third');

    workspace.getState().selectAdjacentTab(-1);
    expect(workspace.getState().selectedTabID).toBe(secondTabID);
    workspace.getState().selectTabByIndex(0);
    expect(workspace.getState().selectedTabID).toBe(firstTabID);

    workspace.getState().closeTab(thirdTabID);
    workspace.getState().closeTab(secondTabID);
    expect(workspace.getState().tabs).toHaveLength(1);
    expect(workspace.getState().closedTabs.map((tab) => tab.title)).toEqual(['Third', 'Second']);

    workspace.getState().reopenClosedTab();
    expect(selectedChatWorkspaceTab(workspace.getState()).title).toBe('Second');
    workspace.getState().reopenClosedTab();
    expect(selectedChatWorkspaceTab(workspace.getState()).title).toBe('Third');
    expect(allChatWorkspacePanes(workspace.getState()).filter((pane) => pane.isPrimary)).toHaveLength(1);
    workspace.getState().dispose();
  });

  it('persists and restores layout, active focus, zoom, metadata, controls, and divider fractions', () => {
    const storage = new MemoryStorage();
    const idFactory = ids();
    const firstPrimary = primary('persistence-primary-1');
    const first = createChatWorkspaceStore({
      primaryController: firstPrimary,
      storage,
      idFactory
    });
    const tabID = first.getState().selectedTabID;
    first.getState().renameTab(tabID, 'Release');
    first.getState().setTabColor(tabID, 'frost');
    first.getState().splitActive('horizontal');
    const pane = activeChatWorkspacePane(first.getState())!;
    first.getState().renamePane(pane.id, 'Logs');
    first.getState().setPaneColor(pane.id, 'amber');
    first.getState().setPaneAlertsEnabled(pane.id, false);
    pane.controller.setState({
      selectedThreadId: 'thread-logs',
      backend: 'claude',
      modelLabel: 'claude-sonnet-4',
      modelOptionID: 'claude-sonnet-4',
      thinkingLevel: 'medium'
    });
    const split = selectedChatWorkspaceTab(first.getState()).root as ChatWorkspaceSplit;
    first.getState().setSplitFraction(split.id, 0.73);
    first.getState().toggleZoomActive();
    first.getState().persist();
    first.getState().dispose();

    const secondPrimary = primary('persistence-primary-2');
    const restored = createChatWorkspaceStore({
      primaryController: secondPrimary,
      storage,
      idFactory
    });
    const restoredTab = selectedChatWorkspaceTab(restored.getState());
    const restoredPane = activeChatWorkspacePane(restored.getState())!;

    expect(restoredTab).toMatchObject({
      title: 'Release',
      colorToken: 'frost',
      activePaneID: restoredPane.id,
      zoomedPaneID: restoredPane.id
    });
    expect(restoredTab.root).toMatchObject({ kind: 'split', fraction: 0.73 });
    expect(restoredPane).toMatchObject({
      title: 'Logs',
      colorToken: 'amber',
      alertsEnabled: false
    });
    expect(restoredPane.controller.getState()).toMatchObject({
      selectedThreadId: 'thread-logs',
      backend: 'claude',
      modelLabel: 'claude-sonnet-4',
      thinkingLevel: 'medium'
    });
    expect(allChatWorkspacePanes(restored.getState()).filter((candidate) => candidate.isPrimary)).toHaveLength(1);
    restored.getState().dispose();
  });

  it('marks hidden completion unseen, jumps to it, and clears it when focused', async () => {
    const primaryController = primary();
    const completionEvents: Array<{ paneID: string; failed: boolean }> = [];
    const workspace = createChatWorkspaceStore({
      primaryController,
      storage: new MemoryStorage(),
      idFactory: ids(),
      now: () => new Date('2026-08-11T15:30:00.000Z'),
      isWorkspaceFrontmost: () => false,
      onHiddenCompletion: (pane, failed) => completionEvents.push({ paneID: pane.id, failed })
    });
    workspace.getState().newTab();
    const hiddenPane = activeChatWorkspacePane(workspace.getState())!;
    const firstTab = workspace.getState().tabs[0]!;
    workspace.getState().selectTab(firstTab.id);

    hiddenPane.controller.setState({ streamPhase: 'streaming', streaming: true });
    hiddenPane.controller.setState({ streamPhase: 'done', streaming: false });
    await Promise.resolve();

    const unseen = allChatWorkspacePanes(workspace.getState()).find((pane) => pane.id === hiddenPane.id)!;
    expect(unseen.unseenCompletionAt).toBe('2026-08-11T15:30:00.000Z');
    expect(completionEvents).toEqual([{ paneID: hiddenPane.id, failed: false }]);

    workspace.getState().jumpToMostRecentUnseen();
    expect(activeChatWorkspacePane(workspace.getState())!.id).toBe(hiddenPane.id);
    expect(activeChatWorkspacePane(workspace.getState())!.unseenCompletionAt).toBeNull();
    workspace.getState().dispose();
  });

  it('focuses an exact pane across tabs and retargets an existing zoom', () => {
    const workspace = createChatWorkspaceStore({
      primaryController: primary(),
      storage: new MemoryStorage(),
      idFactory: ids()
    });
    workspace.getState().splitActive('horizontal');
    const firstTab = selectedChatWorkspaceTab(workspace.getState());
    const target = collectChatWorkspacePanes(firstTab.root)[0]!;
    workspace.getState().toggleZoomActive();
    expect(selectedChatWorkspaceTab(workspace.getState()).zoomedPaneID).not.toBe(target.id);
    workspace.getState().newTab();

    workspace.getState().focusPane(target.id);

    expect(workspace.getState().selectedTabID).toBe(firstTab.id);
    expect(activeChatWorkspacePane(workspace.getState())!.id).toBe(target.id);
    expect(selectedChatWorkspaceTab(workspace.getState()).zoomedPaneID).toBeNull();
    workspace.getState().dispose();
  });

  it('moves panes between tabs and preserves exactly one primary controller', () => {
    const primaryController = primary();
    const workspace = createChatWorkspaceStore({
      primaryController,
      storage: new MemoryStorage(),
      idFactory: ids()
    });
    workspace.getState().splitActive('horizontal');
    const moving = activeChatWorkspacePane(workspace.getState())!;
    const originalTabID = workspace.getState().selectedTabID;

    workspace.getState().movePaneToNewTab(moving.id);

    expect(workspace.getState().tabs).toHaveLength(2);
    expect(workspace.getState().selectedTabID).not.toBe(originalTabID);
    expect(collectChatWorkspacePanes(workspace.getState().tabs.find((tab) => tab.id === originalTabID)!.root)).toHaveLength(1);
    expect(allChatWorkspacePanes(workspace.getState()).filter((pane) => pane.isPrimary)).toHaveLength(1);

    workspace.getState().splitActive('vertical');
    workspace.getState().movePaneToTab(moving.id, originalTabID);
    expect(workspace.getState().selectedTabID).toBe(originalTabID);
    expect(collectChatWorkspacePanes(selectedChatWorkspaceTab(workspace.getState()).root)).toHaveLength(2);
    expect(allChatWorkspacePanes(workspace.getState()).filter((pane) => pane.isPrimary)).toHaveLength(1);
    workspace.getState().dispose();
  });
});
