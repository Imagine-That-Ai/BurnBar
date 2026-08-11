import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type PointerEvent as ReactPointerEvent
} from 'react';
import {
  activeChatWorkspacePane,
  allChatWorkspacePanes,
  chatWorkspaceTabTitle,
  collectChatWorkspacePanes,
  selectedChatWorkspaceTab,
  useChatWorkspaceStore,
  type ChatWorkspaceNode,
  type ChatWorkspacePane,
  type ChatWorkspaceSplit,
  type ChatWorkspaceStore
} from '../../state/chatWorkspaceStore.js';
import type { ChatWorkspaceColorToken } from '../../state/chatWorkspacePersistence.js';
import { useChatStore } from '../../state/chatStore.js';
import { ChatConversationPane } from './ChatConversationPane.js';
import { CHAT_THREAD_DRAG_TYPE, ThreadRail } from './ThreadRail.js';

export const CHAT_PANE_DRAG_TYPE = 'application/x-openburnbar-chat-pane';

type ChatPaneWorkspaceProps = {
  workspace?: ChatWorkspaceStore;
};

export function ChatPaneWorkspace({
  workspace = useChatWorkspaceStore
}: ChatPaneWorkspaceProps) {
  const rootRef = useRef<HTMLDivElement>(null);
  const hydratedControllers = useRef(new Map<string, string>());
  const tabs = workspace((state) => state.tabs);
  const selectedTabID = workspace((state) => state.selectedTabID);
  const closedTabs = workspace((state) => state.closedTabs);
  const controllerRevision = workspace((state) => state.controllerRevision);
  const selectedTab = selectedChatWorkspaceTab({ tabs, selectedTabID });
  const panes = useMemo(() => allChatWorkspacePanes({ tabs }), [tabs, controllerRevision]);
  const activePane = activeChatWorkspacePane({ tabs, selectedTabID })
    ?? collectChatWorkspacePanes(selectedTab.root)[0]!;
  const activeController = activePane.controller;
  const threads = useChatStore((state) => state.threads);
  const loading = useChatStore((state) => state.loading);
  const query = useChatStore((state) => state.query);
  const visibleThreadCount = useChatStore((state) => state.visibleThreadCount);
  const selectedThreadID = activeController((state) => state.selectedThreadId);
  const visibleThreads = threads.slice(0, visibleThreadCount);
  const openThreadIDs = new Set(
    panes.flatMap((pane) => {
      const threadID = pane.controller.getState().selectedThreadId;
      return threadID ? [threadID] : [];
    })
  );
  const unseenThreadIDs = new Set(
    panes.flatMap((pane) => {
      const threadID = pane.controller.getState().selectedThreadId;
      return pane.unseenCompletionAt && threadID ? [threadID] : [];
    })
  );

  useEffect(() => {
    for (const pane of panes) {
      const controllerID = pane.controller.getState().controllerID;
      if (hydratedControllers.current.get(pane.id) === controllerID) continue;
      hydratedControllers.current.set(pane.id, controllerID);
      if (pane.controller.getState().selectedThreadId) {
        void workspace.getState().hydratePane(pane.id);
      } else {
        void pane.controller.getState().reconnectGateway();
      }
    }
    for (const paneID of hydratedControllers.current.keys()) {
      if (!panes.some((pane) => pane.id === paneID)) hydratedControllers.current.delete(paneID);
    }
  }, [panes, workspace]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || !(event.ctrlKey || event.metaKey)) return;
      if (!rootRef.current?.contains(document.activeElement)) return;
      const key = event.key.toLowerCase();
      const state = workspace.getState();
      const selected = selectedChatWorkspaceTab(state);
      const paneCount = collectChatWorkspacePanes(selected.root).length;
      let handled = true;

      if (key === 'd' && event.shiftKey) {
        state.splitActive('vertical');
      } else if (key === 'd') {
        state.splitActive('horizontal');
      } else if (key === 't' && event.shiftKey) {
        state.reopenClosedTab();
      } else if (key === 't') {
        state.newTab();
      } else if (key === '[' && event.shiftKey) {
        state.selectAdjacentTab(-1);
      } else if (key === ']' && event.shiftKey) {
        state.selectAdjacentTab(1);
      } else if (key === 'enter' && event.shiftKey) {
        state.toggleZoomActive();
      } else if (key === 'u' && event.shiftKey) {
        state.jumpToMostRecentUnseen();
      } else if (event.key === 'ArrowLeft' && event.shiftKey) {
        state.focusAdjacentPane(-1);
      } else if (event.key === 'ArrowRight' && event.shiftKey) {
        state.focusAdjacentPane(1);
      } else if (/^[1-9]$/.test(key)) {
        state.selectTabByIndex(Number(key) - 1);
      } else if (key === 'w' && (paneCount > 1 || state.tabs.length > 1)) {
        state.performCloseShortcut();
      } else {
        handled = false;
      }

      if (handled) {
        event.preventDefault();
        event.stopPropagation();
      }
    };
    window.addEventListener('keydown', onKeyDown, { capture: true });
    return () => window.removeEventListener('keydown', onKeyDown, { capture: true });
  }, [workspace]);

  return (
    <div ref={rootRef} className="chat-workspace-shell" data-testid="chat-pane-workspace">
      <ConversationTabStrip
        workspace={workspace}
        tabs={tabs}
        selectedTabID={selectedTabID}
        closedTabCount={closedTabs.length}
        threads={threads}
      />
      <div className="chat-workspace">
        <ThreadRail
          threads={visibleThreads}
          selectedId={selectedThreadID}
          loading={loading && threads.length === 0}
          query={query}
          hasMore={threads.length > visibleThreadCount}
          onSelect={(threadID) => void activeController.getState().selectThread(threadID)}
          onSearch={(value) => void useChatStore.getState().search(value)}
          onLoadMore={() => useChatStore.getState().loadMoreThreads()}
          onNewChat={() => activeController.getState().startNewChat()}
          openThreadIDs={openThreadIDs}
          unseenThreadIDs={unseenThreadIDs}
        />
        <main className="chat-pane-canvas" aria-label="Conversation pane workspace">
          {selectedTab.zoomedPaneID ? (
            <ChatWorkspacePaneView
              key={selectedTab.zoomedPaneID}
              pane={
                collectChatWorkspacePanes(selectedTab.root).find((pane) => pane.id === selectedTab.zoomedPaneID)
                ?? activePane
              }
              workspace={workspace}
              selectedTabID={selectedTabID}
              showsChrome
              zoomed
            />
          ) : (
            <ChatWorkspaceNodeView
              key={selectedTab.root.id}
              node={selectedTab.root}
              workspace={workspace}
              selectedTabID={selectedTabID}
              showsChrome={collectChatWorkspacePanes(selectedTab.root).length > 1 || tabs.length > 1}
            />
          )}
        </main>
      </div>
    </div>
  );
}

type ConversationTabStripProps = {
  workspace: ChatWorkspaceStore;
  tabs: ReturnType<ChatWorkspaceStore['getState']>['tabs'];
  selectedTabID: string;
  closedTabCount: number;
  threads: ReturnType<typeof useChatStore.getState>['threads'];
};

function ConversationTabStrip({
  workspace,
  tabs,
  selectedTabID,
  closedTabCount,
  threads
}: ConversationTabStripProps) {
  const [editingTabID, setEditingTabID] = useState<string | null>(null);
  const [titleDraft, setTitleDraft] = useState('');

  return (
    <nav className="chat-tab-strip" aria-label="Conversation tabs">
      <div className="chat-tab-list" role="tablist" aria-label="Conversation tabs">
        {tabs.map((tab, index) => {
          const selected = tab.id === selectedTabID;
          const panes = collectChatWorkspacePanes(tab.root);
          const unseen = panes.some((pane) => pane.unseenCompletionAt);
          return (
            <div
              key={tab.id}
              className={[
                'chat-tab',
                selected ? 'is-selected' : '',
                tab.colorToken ? `is-${tab.colorToken}` : ''
              ].filter(Boolean).join(' ')}
            >
              <button
                type="button"
                role="tab"
                aria-selected={selected}
                tabIndex={selected ? 0 : -1}
                title={`${chatWorkspaceTabTitle(tab, threads)} · Ctrl+${Math.min(index + 1, 9)}`}
                onClick={() => workspace.getState().selectTab(tab.id)}
                onDoubleClick={() => {
                  setEditingTabID(tab.id);
                  setTitleDraft(chatWorkspaceTabTitle(tab, threads));
                }}
              >
                <span className="chat-tab-color" aria-hidden="true" />
                <span>{chatWorkspaceTabTitle(tab, threads)}</span>
                {unseen ? <span className="chat-tab-unseen"><span className="sr-only">Unread completion</span></span> : null}
                {panes.length > 1 ? <span className="chat-tab-layout" aria-label={`${panes.length} panes`}>◫</span> : null}
              </button>
              {tabs.length > 1 ? (
                <button
                  type="button"
                  className="chat-tab-close"
                  onClick={() => workspace.getState().closeTab(tab.id)}
                  aria-label={`Close ${chatWorkspaceTabTitle(tab, threads)}`}
                  title="Close tab"
                >
                  ×
                </button>
              ) : null}
              {selected ? (
                <details className="chat-tab-options">
                  <summary aria-label="Tab options" title="Tab options">⋯</summary>
                  <div className="chat-tab-options-menu">
                    <button
                      type="button"
                      onClick={() => {
                        setEditingTabID(tab.id);
                        setTitleDraft(chatWorkspaceTabTitle(tab, threads));
                      }}
                    >
                      Rename tab
                    </button>
                    <label>
                      <span>Color</span>
                      <select
                        value={tab.colorToken ?? ''}
                        onChange={(event) =>
                          workspace.getState().setTabColor(
                            tab.id,
                            (event.target.value || null) as ChatWorkspaceColorToken | null
                          )
                        }
                      >
                        <option value="">None</option>
                        {['whimsy', 'aureate', 'ember', 'amber', 'success', 'frost'].map((color) => (
                          <option key={color} value={color}>{color}</option>
                        ))}
                      </select>
                    </label>
                    <button type="button" onClick={() => workspace.getState().closeOtherTabs(tab.id)} disabled={tabs.length <= 1}>
                      Close other tabs
                    </button>
                  </div>
                </details>
              ) : null}
            </div>
          );
        })}
      </div>
      <div className="chat-tab-actions">
        <button type="button" onClick={() => workspace.getState().newTab()} aria-label="New tab" title="New tab · Ctrl+T">+</button>
        {closedTabCount > 0 ? (
          <button type="button" onClick={() => workspace.getState().reopenClosedTab()} aria-label="Reopen closed tab" title="Reopen closed tab · Ctrl+Shift+T">
            ↶
          </button>
        ) : null}
      </div>
      {editingTabID ? (
        <form
          className="chat-tab-rename"
          onSubmit={(event) => {
            event.preventDefault();
            workspace.getState().renameTab(editingTabID, titleDraft);
            setEditingTabID(null);
          }}
        >
          <label>
            <span className="sr-only">Tab title</span>
            <input
              autoFocus
              value={titleDraft}
              maxLength={80}
              onChange={(event) => setTitleDraft(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === 'Escape') setEditingTabID(null);
              }}
            />
          </label>
          <button type="submit">Save</button>
          <button type="button" onClick={() => setEditingTabID(null)}>Cancel</button>
        </form>
      ) : null}
    </nav>
  );
}

type ChatWorkspaceNodeViewProps = {
  node: ChatWorkspaceNode;
  workspace: ChatWorkspaceStore;
  selectedTabID: string;
  showsChrome: boolean;
};

function ChatWorkspaceNodeView({
  node,
  workspace,
  selectedTabID,
  showsChrome
}: ChatWorkspaceNodeViewProps) {
  if (node.kind === 'leaf') {
    return (
      <ChatWorkspacePaneView
        pane={node}
        workspace={workspace}
        selectedTabID={selectedTabID}
        showsChrome={showsChrome}
        zoomed={false}
      />
    );
  }
  return (
    <ChatWorkspaceSplitView
      split={node}
      workspace={workspace}
      selectedTabID={selectedTabID}
      showsChrome={showsChrome}
    />
  );
}

type ChatWorkspaceSplitViewProps = {
  split: ChatWorkspaceSplit;
  workspace: ChatWorkspaceStore;
  selectedTabID: string;
  showsChrome: boolean;
};

function ChatWorkspaceSplitView({
  split,
  workspace,
  selectedTabID,
  showsChrome
}: ChatWorkspaceSplitViewProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const dragState = useRef<{ start: number; fraction: number; latest: number } | null>(null);
  const horizontal = split.axis === 'horizontal';
  const style = {
    '--chat-split-first': `${split.fraction * 100}%`
  } as CSSProperties;

  const beginResize = (event: ReactPointerEvent<HTMLDivElement>) => {
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    dragState.current = {
      start: horizontal ? event.clientX : event.clientY,
      fraction: split.fraction,
      latest: split.fraction
    };
  };

  const moveResize = (event: ReactPointerEvent<HTMLDivElement>) => {
    const drag = dragState.current;
    const bounds = containerRef.current?.getBoundingClientRect();
    if (!drag || !bounds) return;
    const total = horizontal ? bounds.width : bounds.height;
    if (total <= 0) return;
    const current = horizontal ? event.clientX : event.clientY;
    drag.latest = drag.fraction + (current - drag.start) / total;
    workspace.getState().setSplitFraction(split.id, drag.latest, false);
  };

  const endResize = (event: ReactPointerEvent<HTMLDivElement>) => {
    const drag = dragState.current;
    if (!drag) return;
    dragState.current = null;
    event.currentTarget.releasePointerCapture(event.pointerId);
    workspace.getState().setSplitFraction(split.id, drag.latest, true);
  };

  return (
    <div
      ref={containerRef}
      className={`chat-pane-split is-${split.axis}`}
      style={style}
      data-chat-split-id={split.id}
    >
      <div className="chat-pane-split-child is-first">
        <ChatWorkspaceNodeView
          node={split.first}
          workspace={workspace}
          selectedTabID={selectedTabID}
          showsChrome={showsChrome}
        />
      </div>
      <div
        className="chat-pane-divider"
        role="separator"
        tabIndex={0}
        aria-label={`Resize ${split.axis} chat panes`}
        aria-orientation={horizontal ? 'vertical' : 'horizontal'}
        aria-valuemin={15}
        aria-valuemax={85}
        aria-valuenow={Math.round(split.fraction * 100)}
        onPointerDown={beginResize}
        onPointerMove={moveResize}
        onPointerUp={endResize}
        onPointerCancel={endResize}
        onKeyDown={(event) => {
          const decrease = horizontal ? event.key === 'ArrowLeft' : event.key === 'ArrowUp';
          const increase = horizontal ? event.key === 'ArrowRight' : event.key === 'ArrowDown';
          if (!decrease && !increase) return;
          event.preventDefault();
          workspace.getState().setSplitFraction(split.id, split.fraction + (increase ? 0.05 : -0.05));
        }}
      />
      <div className="chat-pane-split-child is-second">
        <ChatWorkspaceNodeView
          node={split.second}
          workspace={workspace}
          selectedTabID={selectedTabID}
          showsChrome={showsChrome}
        />
      </div>
    </div>
  );
}

type ChatWorkspacePaneViewProps = {
  pane: ChatWorkspacePane;
  workspace: ChatWorkspaceStore;
  selectedTabID: string;
  showsChrome: boolean;
  zoomed: boolean;
};

function ChatWorkspacePaneView({
  pane,
  workspace,
  selectedTabID,
  showsChrome,
  zoomed
}: ChatWorkspacePaneViewProps) {
  const [dropTarget, setDropTarget] = useState(false);
  const tabs = workspace((state) => state.tabs);
  const tab = tabs.find((candidate) => candidate.id === selectedTabID) ?? tabs[0]!;
  const active = tab.activePaneID === pane.id;
  const otherTabs = tabs
    .filter((candidate) => candidate.id !== selectedTabID)
    .map((candidate) => ({
      id: candidate.id,
      title: chatWorkspaceTabTitle(candidate, useChatStore.getState().threads)
    }));

  return (
    <div
      className={dropTarget ? 'chat-pane-drop-target is-targeted' : 'chat-pane-drop-target'}
      onDragEnter={(event) => {
        if (
          event.dataTransfer.types.includes(CHAT_THREAD_DRAG_TYPE)
          || event.dataTransfer.types.includes(CHAT_PANE_DRAG_TYPE)
        ) {
          event.preventDefault();
          setDropTarget(true);
        }
      }}
      onDragOver={(event) => {
        if (
          event.dataTransfer.types.includes(CHAT_THREAD_DRAG_TYPE)
          || event.dataTransfer.types.includes(CHAT_PANE_DRAG_TYPE)
        ) {
          event.preventDefault();
          event.dataTransfer.dropEffect = event.dataTransfer.types.includes(CHAT_PANE_DRAG_TYPE)
            ? 'move'
            : 'copy';
        }
      }}
      onDragLeave={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setDropTarget(false);
      }}
      onDrop={(event) => {
        event.preventDefault();
        setDropTarget(false);
        const draggedPaneID = event.dataTransfer.getData(CHAT_PANE_DRAG_TYPE);
        if (draggedPaneID) {
          workspace.getState().swapPanes(draggedPaneID, pane.id);
          return;
        }
        const threadID =
          event.dataTransfer.getData(CHAT_THREAD_DRAG_TYPE)
          || event.dataTransfer.getData('text/plain');
        if (threadID) void workspace.getState().bindThread(threadID, pane.id);
      }}
    >
      <ChatConversationPane
        paneID={pane.id}
        controller={pane.controller}
        active={active}
        showsChrome={showsChrome}
        zoomed={zoomed}
        title={pane.title}
        colorToken={pane.colorToken}
        alertsEnabled={pane.alertsEnabled}
        unseen={Boolean(pane.unseenCompletionAt)}
        otherTabs={otherTabs}
        onActivate={() => workspace.getState().setActive(pane.id)}
        onSplitHorizontal={() => {
          workspace.getState().setActive(pane.id);
          workspace.getState().splitActive('horizontal');
        }}
        onSplitVertical={() => {
          workspace.getState().setActive(pane.id);
          workspace.getState().splitActive('vertical');
        }}
        onClose={() => {
          workspace.getState().setActive(pane.id);
          workspace.getState().performCloseShortcut();
        }}
        onToggleZoom={() => {
          workspace.getState().setActive(pane.id);
          workspace.getState().toggleZoomActive();
        }}
        onRename={(title) => workspace.getState().renamePane(pane.id, title)}
        onColorChange={(color) => workspace.getState().setPaneColor(pane.id, color)}
        onAlertsChange={(enabled) => workspace.getState().setPaneAlertsEnabled(pane.id, enabled)}
        onMoveToNewTab={() => workspace.getState().movePaneToNewTab(pane.id)}
        onMoveToTab={(tabID) => workspace.getState().movePaneToTab(pane.id, tabID)}
        onMarkSeen={() => workspace.getState().markSeen(pane.id)}
        onPaneDragStart={(event) => {
          event.dataTransfer.effectAllowed = 'move';
          event.dataTransfer.setData(CHAT_PANE_DRAG_TYPE, pane.id);
          event.dataTransfer.setData('text/plain', pane.id);
        }}
      />
    </div>
  );
}
