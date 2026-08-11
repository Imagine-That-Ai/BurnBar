// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createChatController } from '../../state/chatStore.js';
import { resetChatRuntimeForTests } from '../../state/chatRuntime.js';
import {
  activeChatWorkspacePane,
  collectChatWorkspacePanes,
  createChatWorkspaceStore,
  selectedChatWorkspaceTab
} from '../../state/chatWorkspaceStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { ChatPaneWorkspace, CHAT_PANE_DRAG_TYPE } from './ChatPaneWorkspace.js';
import { CHAT_THREAD_DRAG_TYPE } from './ThreadRail.js';

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
  return () => `pane-ui-${++sequence}`;
}

function createWorkspace() {
  const primary = createChatController({
    activeThreadStorageKey: null,
    controllerID: 'pane-workspace-ui-primary'
  });
  primary.setState({
    gatewayStatus: 'reachable',
    threads: [{
      id: 'thread-one',
      title: 'Thread one',
      preview: 'First transcript',
      messageCount: 1,
      createdAt: '2026-08-11T12:00:00Z',
      updatedAt: '2026-08-11T12:00:00Z'
    }],
    selectedThreadId: 'thread-one',
    messages: [{
      id: 'message-one',
      threadID: 'thread-one',
      role: 'assistant',
      text: 'First transcript'
    }]
  });
  return createChatWorkspaceStore({
    primaryController: primary,
    storage: new MemoryStorage(),
    idFactory: ids()
  });
}

function dragTransfer(entries: Record<string, string>) {
  const values = new Map(Object.entries(entries));
  return {
    effectAllowed: 'all',
    dropEffect: 'none',
    types: [...values.keys()],
    getData: (type: string) => values.get(type) ?? '',
    setData: (type: string, value: string) => {
      values.set(type, value);
    }
  } as unknown as DataTransfer;
}

beforeEach(() => {
  useShellStore.setState({
    bridge: null,
    bridgeReady: true,
    fixtureMode: true,
    route: 'chat',
    routeHash: '#/chat',
    routeRevision: 0
  });
});

afterEach(() => {
  cleanup();
  resetChatRuntimeForTests();
  vi.restoreAllMocks();
  useShellStore.setState({
    bridge: null,
    bridgeReady: true,
    fixtureMode: false
  });
});

describe('ChatPaneWorkspace', () => {
  it('supports split, keyboard resize, zoom, tab close, and LIFO reopen', async () => {
    const workspace = createWorkspace();
    render(<ChatPaneWorkspace workspace={workspace} />);
    const composer = screen.getByRole('textbox', { name: 'Message composer' });
    composer.focus();

    fireEvent.keyDown(window, { key: 'd', ctrlKey: true });
    expect(document.querySelectorAll('[data-chat-pane-id]')).toHaveLength(2);
    expect(collectChatWorkspacePanes(selectedChatWorkspaceTab(workspace.getState()).root)).toHaveLength(2);

    const separator = screen.getByRole('separator', { name: 'Resize horizontal chat panes' });
    expect(separator.getAttribute('aria-valuenow')).toBe('50');
    fireEvent.keyDown(separator, { key: 'ArrowRight' });
    expect(separator.getAttribute('aria-valuenow')).toBe('55');

    const composers = screen.getAllByRole('textbox', { name: 'Message composer' });
    composers[1]!.focus();
    fireEvent.keyDown(window, { key: 'Enter', ctrlKey: true, shiftKey: true });
    expect(workspace.getState().tabs[0]!.zoomedPaneID).toBeTruthy();
    expect(document.querySelectorAll('[data-chat-pane-id]')).toHaveLength(1);

    screen.getByRole('textbox', { name: 'Message composer' }).focus();
    fireEvent.keyDown(window, { key: 'Enter', ctrlKey: true, shiftKey: true });
    expect(workspace.getState().tabs[0]!.zoomedPaneID).toBeNull();

    screen.getAllByRole('textbox', { name: 'Message composer' })[0]!.focus();
    fireEvent.keyDown(window, { key: 't', ctrlKey: true });
    expect(workspace.getState().tabs).toHaveLength(2);
    expect(screen.getAllByRole('tab')).toHaveLength(2);

    screen.getByRole('textbox', { name: 'Message composer' }).focus();
    fireEvent.keyDown(window, { key: 'w', ctrlKey: true });
    expect(workspace.getState().tabs).toHaveLength(1);
    expect(workspace.getState().closedTabs).toHaveLength(1);

    screen.getAllByRole('textbox', { name: 'Message composer' })[0]!.focus();
    fireEvent.keyDown(window, { key: 't', ctrlKey: true, shiftKey: true });
    expect(workspace.getState().tabs).toHaveLength(2);
    expect(workspace.getState().closedTabs).toHaveLength(0);
    workspace.getState().dispose();
  });

  it('drops a thread onto the exact pane and swaps panes without changing controller ownership', async () => {
    const workspace = createWorkspace();
    workspace.getState().splitActive('horizontal');
    const original = collectChatWorkspacePanes(selectedChatWorkspaceTab(workspace.getState()).root);
    const first = original[0]!;
    const second = original[1]!;
    const selectThread = vi.fn(async (threadID: string) => {
      first.controller.setState({
        selectedThreadId: threadID,
        historyError: null,
        threads: [{
          id: threadID,
          title: 'Dropped thread',
          preview: 'Dropped transcript',
          messageCount: 1,
          createdAt: '2026-08-11T13:00:00Z',
          updatedAt: '2026-08-11T13:00:00Z'
        }]
      });
    });
    first.controller.setState({ selectThread });

    render(<ChatPaneWorkspace workspace={workspace} />);
    const firstDropTarget = screen.getByTestId(`chat-pane-${first.id}`).parentElement!;
    const threadTransfer = dragTransfer({
      [CHAT_THREAD_DRAG_TYPE]: 'thread-dropped',
      'text/plain': 'thread-dropped'
    });
    fireEvent.dragEnter(firstDropTarget, { dataTransfer: threadTransfer });
    fireEvent.drop(firstDropTarget, { dataTransfer: threadTransfer });

    await waitFor(() => expect(selectThread).toHaveBeenCalledWith('thread-dropped'));
    expect(activeChatWorkspacePane(workspace.getState())!.id).toBe(first.id);

    const paneTransfer = dragTransfer({
      [CHAT_PANE_DRAG_TYPE]: second.id,
      'text/plain': second.id
    });
    fireEvent.drop(firstDropTarget, { dataTransfer: paneTransfer });
    const swapped = collectChatWorkspacePanes(selectedChatWorkspaceTab(workspace.getState()).root);
    expect(swapped.map((pane) => pane.id)).toEqual([second.id, first.id]);
    expect(swapped.filter((pane) => pane.isPrimary)).toHaveLength(1);
    workspace.getState().dispose();
  });

  it('exposes tab and separator semantics and focuses the active pane', async () => {
    const workspace = createWorkspace();
    workspace.getState().splitActive('vertical');
    render(<ChatPaneWorkspace workspace={workspace} />);

    expect(screen.getByRole('navigation', { name: 'Conversation tabs' })).toBeTruthy();
    expect(screen.getByRole('tab', { selected: true })).toBeTruthy();
    const separator = screen.getByRole('separator', { name: 'Resize vertical chat panes' });
    expect(separator.getAttribute('aria-orientation')).toBe('horizontal');
    expect(separator.getAttribute('aria-valuemin')).toBe('15');
    expect(separator.getAttribute('aria-valuemax')).toBe('85');

    const firstPane = collectChatWorkspacePanes(selectedChatWorkspaceTab(workspace.getState()).root)[0]!;
    await act(async () => {
      workspace.getState().setActive(firstPane.id);
    });
    expect(activeChatWorkspacePane(workspace.getState())!.id).toBe(firstPane.id);
    workspace.getState().dispose();
  });
});
