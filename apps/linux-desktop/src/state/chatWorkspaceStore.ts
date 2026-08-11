import { create, type StoreApi, type UseBoundStore } from 'zustand';
import type { ChatThreadSummary } from '../tauriBridge.js';
import {
  createChatController,
  type ChatControllerStore,
  type ChatState,
  useChatStore
} from './chatStore.js';
import { useShellStore } from './shellStore.js';
import {
  CHAT_WORKSPACE_CLOSED_TAB_LIMIT,
  CHAT_WORKSPACE_MAX_PANES,
  CHAT_WORKSPACE_STORAGE_KEY,
  CHAT_WORKSPACE_VERSION,
  clampChatWorkspaceFraction,
  collectPersistedPanes,
  createDefaultChatWorkspaceSnapshot,
  decodeChatWorkspaceSnapshot,
  encodeChatWorkspaceSnapshot,
  newChatWorkspaceID,
  type ChatWorkspaceColorToken,
  type ChatWorkspaceSnapshotV2,
  type ChatWorkspaceSplitAxis,
  type PersistedChatNode,
  type PersistedChatPane,
  type PersistedChatTab
} from './chatWorkspacePersistence.js';

export type ChatWorkspacePane = {
  kind: 'leaf';
  id: string;
  controller: ChatControllerStore;
  isPrimary: boolean;
  title: string | null;
  colorToken: ChatWorkspaceColorToken | null;
  unseenCompletionAt: string | null;
  alertsEnabled: boolean;
};

export type ChatWorkspaceSplit = {
  kind: 'split';
  id: string;
  axis: ChatWorkspaceSplitAxis;
  fraction: number;
  first: ChatWorkspaceNode;
  second: ChatWorkspaceNode;
};

export type ChatWorkspaceNode = ChatWorkspacePane | ChatWorkspaceSplit;

export type ChatWorkspaceTab = {
  id: string;
  title: string | null;
  colorToken: ChatWorkspaceColorToken | null;
  root: ChatWorkspaceNode;
  activePaneID: string;
  zoomedPaneID: string | null;
};

export type ChatWorkspaceState = {
  tabs: ChatWorkspaceTab[];
  selectedTabID: string;
  closedTabs: PersistedChatTab[];
  controllerRevision: number;
  disposed: boolean;
  setActive(paneID: string): void;
  focusPane(paneID: string): void;
  selectTab(tabID: string): void;
  selectAdjacentTab(offset: number): void;
  selectTabByIndex(index: number): void;
  focusAdjacentPane(offset: number): void;
  newTab(threadID?: string | null): void;
  closeTab(tabID?: string): void;
  reopenClosedTab(): void;
  closeOtherTabs(tabID: string): void;
  splitActive(axis: ChatWorkspaceSplitAxis): void;
  closeActive(): void;
  performCloseShortcut(): boolean;
  bindThread(threadID: string, paneID: string): Promise<boolean>;
  hydratePane(paneID: string): Promise<void>;
  renameTab(tabID: string, title: string | null): void;
  setTabColor(tabID: string, colorToken: ChatWorkspaceColorToken | null): void;
  renamePane(paneID: string, title: string | null): void;
  setPaneColor(paneID: string, colorToken: ChatWorkspaceColorToken | null): void;
  setPaneAlertsEnabled(paneID: string, enabled: boolean): void;
  setSplitFraction(splitID: string, fraction: number, persist?: boolean): void;
  toggleZoomActive(): void;
  clearZoom(): void;
  markSeen(paneID: string): void;
  jumpToMostRecentUnseen(): void;
  swapPanes(firstPaneID: string, secondPaneID: string): void;
  movePaneToNewTab(paneID: string): void;
  movePaneToTab(paneID: string, tabID: string): void;
  persist(): void;
  resetForTests(): void;
  dispose(): void;
};

export type ChatWorkspaceStore = UseBoundStore<StoreApi<ChatWorkspaceState>>;

export type ChatWorkspaceStoreOptions = {
  primaryController?: ChatControllerStore;
  storage?: Pick<Storage, 'getItem' | 'setItem' | 'removeItem'> | null;
  idFactory?: () => string;
  now?: () => Date;
  isWorkspaceFrontmost?: () => boolean;
  onHiddenCompletion?: (pane: ChatWorkspacePane, failed: boolean) => void;
};

type ControllerSubscription = {
  controller: ChatControllerStore;
  unsubscribe: () => void;
};

export function createChatWorkspaceStore(options: ChatWorkspaceStoreOptions = {}): ChatWorkspaceStore {
  const primaryController = options.primaryController ?? useChatStore;
  const storage = options.storage === undefined ? browserStorage() : options.storage;
  const idFactory = options.idFactory ?? newChatWorkspaceID;
  const now = options.now ?? (() => new Date());
  const isWorkspaceFrontmost = options.isWorkspaceFrontmost ?? defaultWorkspaceFrontmost;
  const raw = readStorage(storage, CHAT_WORKSPACE_STORAGE_KEY);
  const primaryAtRestore = primaryController.getState();
  const restored = decodeChatWorkspaceSnapshot(
    raw,
    primaryAtRestore.selectedThreadId,
    idFactory,
    {
      backend: primaryAtRestore.backend,
      modelLabel: primaryAtRestore.modelLabel,
      modelOptionID: primaryAtRestore.modelOptionID,
      thinkingLevel: primaryAtRestore.thinkingLevel
    }
  );
  const subscriptions = new Map<string, ControllerSubscription>();

  const makeIsolatedController = (pane: PersistedChatPane): ChatControllerStore => {
    const primary = primaryController.getState();
    const controller = createChatController({
      activeThreadStorageKey: null,
      controllerID: `workspace-pane-${pane.id}`,
      onDurableThreadMutation: (_source, payload) => {
        if (primaryController.getState().disposed) return;
        primaryController.setState({
          threads: payload.threads,
          config: payload.config,
          catalog: payload.catalog
        });
      }
    });
    controller.setState({
      threads: primary.threads,
      nextCursor: primary.nextCursor,
      selectedThreadId: pane.threadID,
      messages: [],
      messagesLoading: false,
      loadingOlderMessages: false,
      loadingAllMessages: false,
      hasMoreMessages: false,
      historyError: null,
      config: primary.config,
      catalog: primary.catalog,
      loading: false,
      error: null,
      query: '',
      visibleThreadCount: primary.visibleThreadCount,
      backend: pane.backend,
      modelLabel: pane.modelLabel,
      modelOptionID: pane.modelOptionID,
      thinkingLevel: pane.thinkingLevel,
      streaming: false,
      streamPhase: 'idle',
      streamError: null,
      gatewayStatus: primary.gatewayStatus,
      gatewayBaseURL: primary.gatewayBaseURL,
      activeAbortController: null,
      warnings: primary.warnings,
      sharedFeaturesAvailable: primary.sharedFeaturesAvailable
    });
    return controller;
  };

  const runtimePane = (pane: PersistedChatPane, allowPrimary: boolean): ChatWorkspacePane => {
    const usePrimary = allowPrimary && pane.isPrimary;
    if (usePrimary) {
      const current = primaryController.getState();
      primaryController.setState({
        selectedThreadId: pane.threadID,
        messages: current.selectedThreadId === pane.threadID ? current.messages : [],
        messagesLoading: false,
        loadingOlderMessages: false,
        loadingAllMessages: false,
        hasMoreMessages: false,
        historyError: null,
        backend: pane.backend,
        modelLabel: pane.modelLabel,
        modelOptionID: pane.modelOptionID,
        thinkingLevel: pane.thinkingLevel,
        streaming: false,
        streamPhase: 'idle',
        streamError: null,
        activeAbortController: null
      });
    }
    return {
      kind: 'leaf',
      id: pane.id,
      controller: usePrimary ? primaryController : makeIsolatedController(pane),
      isPrimary: usePrimary,
      title: pane.title,
      colorToken: pane.colorToken,
      unseenCompletionAt: pane.unseenCompletionAt,
      alertsEnabled: pane.alertsEnabled
    };
  };

  const runtimeNode = (node: PersistedChatNode, allowPrimary: boolean): ChatWorkspaceNode => {
    if (node.kind === 'leaf') return runtimePane(node, allowPrimary);
    return {
      kind: 'split',
      id: node.id,
      axis: node.axis,
      fraction: clampChatWorkspaceFraction(node.fraction),
      first: runtimeNode(node.first, allowPrimary),
      second: runtimeNode(node.second, allowPrimary)
    };
  };

  const runtimeTab = (tab: PersistedChatTab, allowPrimary: boolean): ChatWorkspaceTab => {
    const root = runtimeNode(tab.root, allowPrimary);
    const paneIDs = new Set(collectChatWorkspacePanes(root).map((pane) => pane.id));
    return {
      id: tab.id,
      title: tab.title,
      colorToken: tab.colorToken,
      root,
      activePaneID: paneIDs.has(tab.activePaneID) ? tab.activePaneID : firstChatWorkspacePane(root).id,
      zoomedPaneID: tab.zoomedPaneID && paneIDs.has(tab.zoomedPaneID) ? tab.zoomedPaneID : null
    };
  };

  const tabs = restored.tabs.map((tab) => runtimeTab(tab, true));

  const workspaceStore = create<ChatWorkspaceState>()((set, get) => ({
    tabs,
    selectedTabID: tabs.some((tab) => tab.id === restored.selectedTabID)
      ? restored.selectedTabID
      : tabs[0]!.id,
    closedTabs: restored.closedTabs,
    controllerRevision: 0,
    disposed: false,

    setActive(paneID) {
      const location = locatePane(get().tabs, paneID);
      if (!location) return;
      set((state) => ({
        tabs: state.tabs.map((tab) => tab.id === location.tab.id
          ? { ...tab, activePaneID: paneID }
          : tab),
        selectedTabID: location.tab.id
      }));
      get().markSeen(paneID);
      get().persist();
    },

    focusPane(paneID) {
      const location = locatePane(get().tabs, paneID);
      if (!location) return;
      set((state) => ({
        tabs: state.tabs.map((tab) => tab.id === location.tab.id
          ? {
              ...tab,
              activePaneID: paneID,
              zoomedPaneID: null
            }
          : tab),
        selectedTabID: location.tab.id
      }));
      get().markSeen(paneID);
      get().persist();
    },

    selectTab(tabID) {
      const tab = get().tabs.find((candidate) => candidate.id === tabID);
      if (!tab) return;
      set({ selectedTabID: tabID });
      get().markSeen(tab.activePaneID);
      get().persist();
    },

    selectAdjacentTab(offset) {
      const state = get();
      if (state.tabs.length <= 1) return;
      const index = state.tabs.findIndex((tab) => tab.id === state.selectedTabID);
      if (index < 0) return;
      const next = (index + offset + state.tabs.length) % state.tabs.length;
      get().selectTab(state.tabs[next]!.id);
    },

    selectTabByIndex(index) {
      const tab = get().tabs[index];
      if (tab) get().selectTab(tab.id);
    },

    focusAdjacentPane(offset) {
      const tab = selectedChatWorkspaceTab(get());
      const panes = collectChatWorkspacePanes(tab.root);
      if (panes.length <= 1) return;
      const index = panes.findIndex((pane) => pane.id === tab.activePaneID);
      if (index < 0) return;
      const next = (index + offset + panes.length) % panes.length;
      get().setActive(panes[next]!.id);
    },

    newTab(threadID = null) {
      if (allChatWorkspacePanes(get()).length >= CHAT_WORKSPACE_MAX_PANES) return;
      const source = activeChatWorkspacePane(get());
      const pane = freshPersistedPane(idFactory(), threadID, false, source?.controller.getState());
      const runtime = runtimePane(pane, false);
      const tab: ChatWorkspaceTab = {
        id: idFactory(),
        title: null,
        colorToken: null,
        root: runtime,
        activePaneID: runtime.id,
        zoomedPaneID: null
      };
      set((state) => ({
        tabs: [...state.tabs, tab],
        selectedTabID: tab.id
      }));
      syncSubscriptions();
      get().persist();
    },

    closeTab(tabID = get().selectedTabID) {
      const state = get();
      if (state.tabs.length <= 1) return;
      const index = state.tabs.findIndex((tab) => tab.id === tabID);
      if (index < 0) return;
      const closing = state.tabs[index]!;
      const closedSnapshot = snapshotTab(closing, true);
      const hasPrimary = collectChatWorkspacePanes(closing.root).some((pane) => pane.isPrimary);
      let nextTabs = state.tabs;
      let nextSelected = state.selectedTabID;

      if (hasPrimary) {
        const survivorIndex = index === 0 ? 1 : index - 1;
        const survivorTab = state.tabs[survivorIndex]!;
        const survivor = chatWorkspacePane(survivorTab.root, survivorTab.activePaneID)
          ?? firstChatWorkspacePane(survivorTab.root);
        if (isControllerBusy(survivor.controller)) {
          set({ selectedTabID: survivorTab.id });
          get().persist();
          return;
        }
        rehomePrimaryController(primaryController, survivor.controller);
        const replacement = {
          ...survivor,
          controller: primaryController,
          isPrimary: true
        };
        const repairedSurvivor = {
          ...survivorTab,
          root: replaceChatWorkspaceNode(survivorTab.root, survivor.id, replacement),
          activePaneID: survivor.id
        };
        survivor.controller.getState().dispose();
        for (const pane of collectChatWorkspacePanes(closing.root)) {
          if (!pane.isPrimary) pane.controller.getState().dispose();
        }
        nextTabs = state.tabs
          .filter((tab) => tab.id !== closing.id)
          .map((tab) => tab.id === survivorTab.id ? repairedSurvivor : tab);
        nextSelected = survivorTab.id;
      } else {
        for (const pane of collectChatWorkspacePanes(closing.root)) {
          pane.controller.getState().dispose();
        }
        nextTabs = state.tabs.filter((tab) => tab.id !== closing.id);
        if (state.selectedTabID === closing.id) {
          nextSelected = nextTabs[Math.min(index, nextTabs.length - 1)]!.id;
        }
      }

      set({
        tabs: nextTabs,
        selectedTabID: nextSelected,
        closedTabs: [...state.closedTabs, closedSnapshot].slice(-CHAT_WORKSPACE_CLOSED_TAB_LIMIT)
      });
      syncSubscriptions();
      get().persist();
    },

    reopenClosedTab() {
      const state = get();
      const snapshot = state.closedTabs.at(-1);
      if (!snapshot || allChatWorkspacePanes(state).length + collectPersistedPanes(snapshot.root).length > CHAT_WORKSPACE_MAX_PANES) {
        return;
      }
      const reopened = runtimeTab(snapshot, false);
      set({
        tabs: [...state.tabs, reopened],
        selectedTabID: reopened.id,
        closedTabs: state.closedTabs.slice(0, -1)
      });
      syncSubscriptions();
      get().persist();
    },

    closeOtherTabs(tabID) {
      if (!get().tabs.some((tab) => tab.id === tabID)) return;
      get().selectTab(tabID);
      for (const candidate of [...get().tabs]) {
        if (candidate.id !== tabID && get().tabs.length > 1) get().closeTab(candidate.id);
      }
    },

    splitActive(axis) {
      const state = get();
      if (allChatWorkspacePanes(state).length >= CHAT_WORKSPACE_MAX_PANES) return;
      const tab = selectedChatWorkspaceTab(state);
      const active = chatWorkspacePane(tab.root, tab.activePaneID);
      if (!active) return;
      const fresh = runtimePane(
        freshPersistedPane(idFactory(), null, false, active.controller.getState()),
        false
      );
      const split: ChatWorkspaceSplit = {
        kind: 'split',
        id: idFactory(),
        axis,
        fraction: 0.5,
        first: active,
        second: fresh
      };
      set((current) => ({
        tabs: current.tabs.map((candidate) => candidate.id === tab.id
          ? {
              ...candidate,
              root: replaceChatWorkspaceNode(candidate.root, active.id, split),
              activePaneID: fresh.id,
              zoomedPaneID: null
            }
          : candidate)
      }));
      syncSubscriptions();
      get().persist();
    },

    closeActive() {
      const state = get();
      const tab = selectedChatWorkspaceTab(state);
      const panes = collectChatWorkspacePanes(tab.root);
      if (panes.length <= 1) return;
      const target = chatWorkspacePane(tab.root, tab.activePaneID);
      if (!target) return;
      const detached = detachChatWorkspacePane(tab.root, target.id);
      if (!detached) return;
      let root = detached.root;
      let activePane = firstChatWorkspacePane(root);

      if (target.isPrimary) {
        if (isControllerBusy(activePane.controller)) {
          get().setActive(activePane.id);
          return;
        }
        rehomePrimaryController(primaryController, activePane.controller);
        const replacement: ChatWorkspacePane = {
          ...activePane,
          controller: primaryController,
          isPrimary: true
        };
        root = replaceChatWorkspaceNode(root, activePane.id, replacement);
        activePane.controller.getState().dispose();
        activePane = replacement;
      } else {
        target.controller.getState().dispose();
      }

      set((current) => ({
        tabs: current.tabs.map((candidate) => candidate.id === tab.id
          ? {
              ...candidate,
              root,
              activePaneID: activePane.id,
              zoomedPaneID: null
            }
          : candidate)
      }));
      syncSubscriptions();
      get().persist();
    },

    performCloseShortcut() {
      const state = get();
      const tab = selectedChatWorkspaceTab(state);
      if (collectChatWorkspacePanes(tab.root).length > 1) {
        get().closeActive();
        return true;
      }
      if (state.tabs.length > 1) {
        get().closeTab(tab.id);
        return true;
      }
      return false;
    },

    async bindThread(rawThreadID, paneID) {
      const threadID = rawThreadID.trim();
      const location = locatePane(get().tabs, paneID);
      if (!location || !threadID || isControllerBusy(location.pane.controller)) return false;
      await location.pane.controller.getState().selectThread(threadID);
      const controllerState = location.pane.controller.getState();
      if (controllerState.selectedThreadId !== threadID || controllerState.historyError) return false;
      const exactThread = controllerState.threads.find((thread) => thread.id === threadID);
      if (exactThread && location.pane.controller !== primaryController) {
        primaryController.setState((primary) => ({
          threads: primary.threads.some((thread) => thread.id === exactThread.id)
            ? primary.threads.map((thread) => thread.id === exactThread.id ? exactThread : thread)
            : [exactThread, ...primary.threads]
        }));
      }
      get().setActive(paneID);
      get().persist();
      return true;
    },

    async hydratePane(paneID) {
      const location = locatePane(get().tabs, paneID);
      if (!location || location.pane.controller.getState().disposed) return;
      const desiredThreadID = location.pane.controller.getState().selectedThreadId;
      await location.pane.controller.getState().load();
      if (desiredThreadID && location.pane.controller.getState().selectedThreadId !== desiredThreadID) {
        await location.pane.controller.getState().selectThread(desiredThreadID);
      }
      const hydrated = location.pane.controller.getState();
      if (desiredThreadID && hydrated.selectedThreadId === desiredThreadID && hydrated.historyError) {
        location.pane.controller.getState().startNewChat();
      }
      get().persist();
    },

    renameTab(tabID, title) {
      const normalized = normalizedTitle(title);
      set((state) => ({
        tabs: state.tabs.map((tab) => tab.id === tabID ? { ...tab, title: normalized } : tab)
      }));
      get().persist();
    },

    setTabColor(tabID, colorToken) {
      set((state) => ({
        tabs: state.tabs.map((tab) => tab.id === tabID ? { ...tab, colorToken } : tab)
      }));
      get().persist();
    },

    renamePane(paneID, title) {
      updatePaneState(set, get, paneID, (pane) => ({ ...pane, title: normalizedTitle(title) }));
    },

    setPaneColor(paneID, colorToken) {
      updatePaneState(set, get, paneID, (pane) => ({ ...pane, colorToken }));
    },

    setPaneAlertsEnabled(paneID, enabled) {
      updatePaneState(set, get, paneID, (pane) => ({ ...pane, alertsEnabled: enabled }));
    },

    setSplitFraction(splitID, fraction, shouldPersist = true) {
      const value = clampChatWorkspaceFraction(fraction);
      set((state) => ({
        tabs: state.tabs.map((tab) => ({
          ...tab,
          root: updateSplitFraction(tab.root, splitID, value)
        }))
      }));
      if (shouldPersist) get().persist();
    },

    toggleZoomActive() {
      const tab = selectedChatWorkspaceTab(get());
      if (collectChatWorkspacePanes(tab.root).length <= 1) return;
      set((state) => ({
        tabs: state.tabs.map((candidate) => candidate.id === tab.id
          ? {
              ...candidate,
              zoomedPaneID: candidate.zoomedPaneID === candidate.activePaneID
                ? null
                : candidate.activePaneID
            }
          : candidate)
      }));
      get().persist();
    },

    clearZoom() {
      const tab = selectedChatWorkspaceTab(get());
      if (!tab.zoomedPaneID) return;
      set((state) => ({
        tabs: state.tabs.map((candidate) => candidate.id === tab.id
          ? { ...candidate, zoomedPaneID: null }
          : candidate)
      }));
      get().persist();
    },

    markSeen(paneID) {
      const location = locatePane(get().tabs, paneID);
      if (!location || !location.pane.unseenCompletionAt) return;
      set((state) => ({
        tabs: state.tabs.map((tab) => ({
          ...tab,
          root: replaceChatWorkspaceNode(tab.root, paneID, {
            ...location.pane,
            unseenCompletionAt: null
          })
        }))
      }));
      get().persist();
    },

    jumpToMostRecentUnseen() {
      const unseen = allChatWorkspacePanes(get())
        .filter((pane) => pane.unseenCompletionAt)
        .sort((first, second) =>
          Date.parse(second.unseenCompletionAt!) - Date.parse(first.unseenCompletionAt!)
        )[0];
      if (unseen) get().focusPane(unseen.id);
    },

    swapPanes(firstPaneID, secondPaneID) {
      if (firstPaneID === secondPaneID) return;
      const state = get();
      const first = locatePane(state.tabs, firstPaneID);
      const second = locatePane(state.tabs, secondPaneID);
      if (!first || !second) return;
      set({
        tabs: state.tabs.map((tab) => {
          const involved = tab.id === first.tab.id || tab.id === second.tab.id;
          if (!involved) return tab;
          const sameTab = first.tab.id === second.tab.id;
          const root = swapChatWorkspaceNodes(
            tab.root,
            firstPaneID,
            second.pane,
            secondPaneID,
            first.pane
          );
          const activePaneID = sameTab
            ? tab.activePaneID
            : tab.activePaneID === firstPaneID
              ? secondPaneID
              : tab.activePaneID === secondPaneID
                ? firstPaneID
                : tab.activePaneID;
          const zoomedPaneID = sameTab
            ? tab.zoomedPaneID
            : tab.zoomedPaneID === firstPaneID
              ? secondPaneID
              : tab.zoomedPaneID === secondPaneID
                ? firstPaneID
                : tab.zoomedPaneID;
          return {
            ...tab,
            root,
            activePaneID,
            zoomedPaneID
          };
        })
      });
      get().persist();
    },

    movePaneToNewTab(paneID) {
      const state = get();
      const source = locatePane(state.tabs, paneID);
      if (!source || collectChatWorkspacePanes(source.tab.root).length <= 1) return;
      const detached = detachChatWorkspacePane(source.tab.root, paneID);
      if (!detached) return;
      const tab: ChatWorkspaceTab = {
        id: idFactory(),
        title: source.pane.title,
        colorToken: source.pane.colorToken,
        root: source.pane,
        activePaneID: source.pane.id,
        zoomedPaneID: null
      };
      set({
        tabs: state.tabs.map((candidate) => candidate.id === source.tab.id
          ? {
              ...candidate,
              root: detached.root,
              activePaneID: firstChatWorkspacePane(detached.root).id,
              zoomedPaneID: null
            }
          : candidate).concat(tab),
        selectedTabID: tab.id
      });
      get().persist();
    },

    movePaneToTab(paneID, tabID) {
      const state = get();
      const source = locatePane(state.tabs, paneID);
      const target = state.tabs.find((tab) => tab.id === tabID);
      if (!source || !target || source.tab.id === target.id || collectChatWorkspacePanes(source.tab.root).length <= 1) {
        return;
      }
      const detached = detachChatWorkspacePane(source.tab.root, paneID);
      const targetPane = chatWorkspacePane(target.root, target.activePaneID) ?? firstChatWorkspacePane(target.root);
      if (!detached) return;
      const split: ChatWorkspaceSplit = {
        kind: 'split',
        id: idFactory(),
        axis: 'horizontal',
        fraction: 0.5,
        first: targetPane,
        second: source.pane
      };
      set({
        tabs: state.tabs.map((candidate) => {
          if (candidate.id === source.tab.id) {
            return {
              ...candidate,
              root: detached.root,
              activePaneID: firstChatWorkspacePane(detached.root).id,
              zoomedPaneID: null
            };
          }
          if (candidate.id === target.id) {
            return {
              ...candidate,
              root: replaceChatWorkspaceNode(candidate.root, targetPane.id, split),
              activePaneID: source.pane.id,
              zoomedPaneID: null
            };
          }
          return candidate;
        }),
        selectedTabID: target.id
      });
      get().persist();
    },

    persist() {
      if (get().disposed) return;
      writeStorage(
        storage,
        CHAT_WORKSPACE_STORAGE_KEY,
        encodeChatWorkspaceSnapshot(snapshotWorkspace(get()))
      );
    },

    resetForTests() {
      for (const subscription of subscriptions.values()) subscription.unsubscribe();
      subscriptions.clear();
      for (const pane of allChatWorkspacePanes(get())) {
        if (!pane.isPrimary) pane.controller.getState().dispose();
      }
      removeStorage(storage, CHAT_WORKSPACE_STORAGE_KEY);
      const primary = primaryController.getState();
      const snapshot = createDefaultChatWorkspaceSnapshot(
        primary.selectedThreadId,
        idFactory,
        {
          backend: primary.backend,
          modelLabel: primary.modelLabel,
          modelOptionID: primary.modelOptionID,
          thinkingLevel: primary.thinkingLevel
        }
      );
      const tab = runtimeTab(snapshot.tabs[0]!, true);
      set((state) => ({
        tabs: [tab],
        selectedTabID: tab.id,
        closedTabs: [],
        controllerRevision: state.controllerRevision + 1,
        disposed: false
      }));
      syncSubscriptions();
      get().persist();
    },

    dispose() {
      if (get().disposed) return;
      for (const subscription of subscriptions.values()) subscription.unsubscribe();
      subscriptions.clear();
      for (const pane of allChatWorkspacePanes(get())) {
        if (!pane.isPrimary) pane.controller.getState().dispose();
      }
      set({ disposed: true });
    }
  }));

  const handleControllerChange = (
    paneID: string,
    next: ChatState,
    previous: ChatState
  ) => {
    if (workspaceStore.getState().disposed) return;
    if (
      next.selectedThreadId !== previous.selectedThreadId
      || next.backend !== previous.backend
      || next.modelLabel !== previous.modelLabel
      || next.modelOptionID !== previous.modelOptionID
      || next.thinkingLevel !== previous.thinkingLevel
    ) {
      workspaceStore.setState((state) => ({ controllerRevision: state.controllerRevision + 1 }));
      workspaceStore.getState().persist();
    }
    const previousBusy = previous.streamPhase === 'composing' || previous.streamPhase === 'streaming';
    const settled = previousBusy && (
      next.streamPhase === 'done'
      || next.streamPhase === 'error'
      || next.streamPhase === 'aborted'
    );
    if (!settled || next.streamPhase === 'aborted') return;
    const location = locatePane(workspaceStore.getState().tabs, paneID);
    if (!location) return;
    if (paneIsVisible(workspaceStore.getState(), paneID) && isWorkspaceFrontmost()) {
      workspaceStore.getState().markSeen(paneID);
      return;
    }
    const settledAt = now().toISOString();
    workspaceStore.setState((state) => ({
      tabs: state.tabs.map((tab) => ({
        ...tab,
        root: replaceChatWorkspaceNode(tab.root, paneID, {
          ...location.pane,
          unseenCompletionAt: settledAt
        })
      }))
    }));
    workspaceStore.getState().persist();
    if (location.pane.alertsEnabled) {
      options.onHiddenCompletion?.(location.pane, next.streamPhase === 'error');
    }
  };

  const syncSubscriptions = () => {
    const desired = new Map(allChatWorkspacePanes(workspaceStore.getState()).map((pane) => [pane.id, pane]));
    for (const [paneID, subscription] of subscriptions) {
      const pane = desired.get(paneID);
      if (!pane || pane.controller !== subscription.controller) {
        subscription.unsubscribe();
        subscriptions.delete(paneID);
      }
    }
    for (const pane of desired.values()) {
      if (subscriptions.has(pane.id)) continue;
      const unsubscribe = pane.controller.subscribe((next, previous) => {
        handleControllerChange(pane.id, next, previous);
      });
      subscriptions.set(pane.id, { controller: pane.controller, unsubscribe });
    }
  };

  syncSubscriptions();
  workspaceStore.getState().persist();
  return workspaceStore;
}

export function selectedChatWorkspaceTab(state: Pick<ChatWorkspaceState, 'tabs' | 'selectedTabID'>): ChatWorkspaceTab {
  return state.tabs.find((tab) => tab.id === state.selectedTabID) ?? state.tabs[0]!;
}

export function activeChatWorkspacePane(
  state: Pick<ChatWorkspaceState, 'tabs' | 'selectedTabID'>
): ChatWorkspacePane | null {
  const tab = selectedChatWorkspaceTab(state);
  return chatWorkspacePane(tab.root, tab.activePaneID);
}

export function allChatWorkspacePanes(state: Pick<ChatWorkspaceState, 'tabs'>): ChatWorkspacePane[] {
  return state.tabs.flatMap((tab) => collectChatWorkspacePanes(tab.root));
}

export function collectChatWorkspacePanes(node: ChatWorkspaceNode): ChatWorkspacePane[] {
  if (node.kind === 'leaf') return [node];
  return [...collectChatWorkspacePanes(node.first), ...collectChatWorkspacePanes(node.second)];
}

export function firstChatWorkspacePane(node: ChatWorkspaceNode): ChatWorkspacePane {
  return node.kind === 'leaf' ? node : firstChatWorkspacePane(node.first);
}

export function chatWorkspacePane(node: ChatWorkspaceNode, paneID: string): ChatWorkspacePane | null {
  if (node.kind === 'leaf') return node.id === paneID ? node : null;
  return chatWorkspacePane(node.first, paneID) ?? chatWorkspacePane(node.second, paneID);
}

export function chatWorkspaceTabTitle(
  tab: ChatWorkspaceTab,
  threads: ChatThreadSummary[]
): string {
  if (tab.title) return tab.title;
  const active = chatWorkspacePane(tab.root, tab.activePaneID) ?? firstChatWorkspacePane(tab.root);
  if (active.title) return active.title;
  const threadID = active.controller.getState().selectedThreadId;
  const threadTitle = threads.find((thread) => thread.id === threadID)?.title?.trim();
  if (threadTitle) return threadTitle;
  return active.controller.getState().backend === 'hermes'
    ? 'Hermes'
    : active.controller.getState().backend;
}

function freshPersistedPane(
  id: string,
  threadID: string | null,
  isPrimary: boolean,
  source?: ChatState
): PersistedChatPane {
  return {
    kind: 'leaf',
    id,
    threadID,
    isPrimary,
    title: null,
    colorToken: null,
    backend: source?.backend ?? 'hermes',
    modelLabel: source?.modelLabel ?? 'hermes',
    modelOptionID: source?.modelOptionID ?? 'hermes',
    thinkingLevel: source?.thinkingLevel ?? 'default',
    unseenCompletionAt: null,
    alertsEnabled: true
  };
}

function snapshotWorkspace(state: ChatWorkspaceState): ChatWorkspaceSnapshotV2 {
  return {
    version: CHAT_WORKSPACE_VERSION,
    tabs: state.tabs.map((tab) => snapshotTab(tab, false)),
    selectedTabID: state.selectedTabID,
    closedTabs: state.closedTabs
  };
}

function snapshotTab(tab: ChatWorkspaceTab, forceNonPrimary: boolean): PersistedChatTab {
  return {
    id: tab.id,
    title: tab.title,
    colorToken: tab.colorToken,
    root: snapshotNode(tab.root, forceNonPrimary),
    activePaneID: tab.activePaneID,
    zoomedPaneID: tab.zoomedPaneID
  };
}

function snapshotNode(node: ChatWorkspaceNode, forceNonPrimary: boolean): PersistedChatNode {
  if (node.kind === 'leaf') {
    const state = node.controller.getState();
    return {
      kind: 'leaf',
      id: node.id,
      threadID: state.selectedThreadId,
      isPrimary: forceNonPrimary ? false : node.isPrimary,
      title: node.title,
      colorToken: node.colorToken,
      backend: state.backend,
      modelLabel: state.modelLabel,
      modelOptionID: state.modelOptionID,
      thinkingLevel: state.thinkingLevel,
      unseenCompletionAt: forceNonPrimary ? null : node.unseenCompletionAt,
      alertsEnabled: node.alertsEnabled
    };
  }
  return {
    kind: 'split',
    id: node.id,
    axis: node.axis,
    fraction: clampChatWorkspaceFraction(node.fraction),
    first: snapshotNode(node.first, forceNonPrimary),
    second: snapshotNode(node.second, forceNonPrimary)
  };
}

function locatePane(
  tabs: ChatWorkspaceTab[],
  paneID: string
): { tab: ChatWorkspaceTab; pane: ChatWorkspacePane } | null {
  for (const tab of tabs) {
    const pane = chatWorkspacePane(tab.root, paneID);
    if (pane) return { tab, pane };
  }
  return null;
}

function replaceChatWorkspaceNode(
  node: ChatWorkspaceNode,
  targetID: string,
  replacement: ChatWorkspaceNode
): ChatWorkspaceNode {
  if (node.id === targetID) return replacement;
  if (node.kind === 'leaf') return node;
  const first = replaceChatWorkspaceNode(node.first, targetID, replacement);
  const second = replaceChatWorkspaceNode(node.second, targetID, replacement);
  return first === node.first && second === node.second ? node : { ...node, first, second };
}

function swapChatWorkspaceNodes(
  node: ChatWorkspaceNode,
  firstID: string,
  firstReplacement: ChatWorkspacePane,
  secondID: string,
  secondReplacement: ChatWorkspacePane
): ChatWorkspaceNode {
  if (node.id === firstID) return firstReplacement;
  if (node.id === secondID) return secondReplacement;
  if (node.kind === 'leaf') return node;
  const first = swapChatWorkspaceNodes(
    node.first,
    firstID,
    firstReplacement,
    secondID,
    secondReplacement
  );
  const second = swapChatWorkspaceNodes(
    node.second,
    firstID,
    firstReplacement,
    secondID,
    secondReplacement
  );
  return first === node.first && second === node.second ? node : { ...node, first, second };
}

function detachChatWorkspacePane(
  node: ChatWorkspaceNode,
  paneID: string
): { root: ChatWorkspaceNode; pane: ChatWorkspacePane } | null {
  if (node.kind === 'leaf') return null;
  if (node.first.kind === 'leaf' && node.first.id === paneID) {
    return { root: node.second, pane: node.first };
  }
  if (node.second.kind === 'leaf' && node.second.id === paneID) {
    return { root: node.first, pane: node.second };
  }
  const first = detachChatWorkspacePane(node.first, paneID);
  if (first) return { root: { ...node, first: first.root }, pane: first.pane };
  const second = detachChatWorkspacePane(node.second, paneID);
  if (second) return { root: { ...node, second: second.root }, pane: second.pane };
  return null;
}

function updateSplitFraction(
  node: ChatWorkspaceNode,
  splitID: string,
  fraction: number
): ChatWorkspaceNode {
  if (node.kind === 'leaf') return node;
  if (node.id === splitID) return { ...node, fraction };
  const first = updateSplitFraction(node.first, splitID, fraction);
  const second = updateSplitFraction(node.second, splitID, fraction);
  return first === node.first && second === node.second ? node : { ...node, first, second };
}

function updatePaneState(
  set: StoreApi<ChatWorkspaceState>['setState'],
  get: StoreApi<ChatWorkspaceState>['getState'],
  paneID: string,
  update: (pane: ChatWorkspacePane) => ChatWorkspacePane
): void {
  const location = locatePane(get().tabs, paneID);
  if (!location) return;
  set((state) => ({
    tabs: state.tabs.map((tab) => ({
      ...tab,
      root: replaceChatWorkspaceNode(tab.root, paneID, update(location.pane))
    }))
  }));
  get().persist();
}

function isControllerBusy(controller: ChatControllerStore): boolean {
  const state = controller.getState();
  return state.streaming || state.streamPhase === 'composing';
}

function rehomePrimaryController(primary: ChatControllerStore, source: ChatControllerStore): void {
  primary.getState().stopStreaming();
  const state = source.getState();
  primary.setState({
    threads: state.threads,
    nextCursor: state.nextCursor,
    selectedThreadId: state.selectedThreadId,
    messages: state.messages,
    messagesLoading: state.messagesLoading,
    loadingOlderMessages: state.loadingOlderMessages,
    loadingAllMessages: state.loadingAllMessages,
    hasMoreMessages: state.hasMoreMessages,
    historyError: state.historyError,
    config: state.config,
    catalog: state.catalog,
    loading: false,
    error: state.error,
    query: state.query,
    visibleThreadCount: state.visibleThreadCount,
    backend: state.backend,
    modelLabel: state.modelLabel,
    modelOptionID: state.modelOptionID,
    thinkingLevel: state.thinkingLevel,
    streaming: false,
    streamPhase: state.streamPhase === 'error' ? 'error' : 'idle',
    streamError: state.streamError,
    gatewayStatus: state.gatewayStatus,
    gatewayBaseURL: state.gatewayBaseURL,
    activeAbortController: null,
    warnings: state.warnings,
    sharedFeaturesAvailable: state.sharedFeaturesAvailable,
    disposed: false
  });
  if (state.selectedThreadId && useShellStore.getState().bridge) {
    queueMicrotask(() => void primary.getState().resumeThread());
  }
}

function paneIsVisible(state: ChatWorkspaceState, paneID: string): boolean {
  const location = locatePane(state.tabs, paneID);
  if (!location || location.tab.id !== state.selectedTabID) return false;
  return !location.tab.zoomedPaneID || location.tab.zoomedPaneID === paneID;
}

function normalizedTitle(value: string | null): string | null {
  const title = value?.trim().slice(0, 80) ?? '';
  return title || null;
}

function browserStorage(): Pick<Storage, 'getItem' | 'setItem' | 'removeItem'> | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

function readStorage(
  storage: Pick<Storage, 'getItem' | 'setItem'> | null,
  key: string
): string | null {
  try {
    return storage?.getItem(key) ?? null;
  } catch {
    return null;
  }
}

function writeStorage(
  storage: Pick<Storage, 'setItem'> | null,
  key: string,
  value: string
): void {
  try {
    storage?.setItem(key, value);
  } catch {
    // Workspace persistence is a recoverable convenience; the daemon remains authoritative.
  }
}

function removeStorage(
  storage: Pick<Storage, 'removeItem'> | null,
  key: string
): void {
  try {
    storage?.removeItem(key);
  } catch {
    // Test/reset cleanup must remain safe in privacy-restricted WebViews.
  }
}

function defaultWorkspaceFrontmost(): boolean {
  if (typeof document === 'undefined') return true;
  return document.visibilityState === 'visible' && (typeof document.hasFocus !== 'function' || document.hasFocus());
}

function postHiddenPaneCompletion(pane: ChatWorkspacePane, failed: boolean): void {
  const { fixtureMode, bridge } = useShellStore.getState();
  if (fixtureMode || !bridge?.nativeNotificationShow) return;
  const state = pane.controller.getState();
  const preview = [...state.messages]
    .reverse()
    .find((message) => message.role === 'assistant' && message.text.trim())
    ?.text.trim()
    .slice(0, 220);
  void bridge.nativeNotificationShow({
    id: `chat-pane-${pane.id}`.slice(0, 128),
    title: failed ? 'Chat needs attention' : 'Chat reply complete',
    body: preview || (failed ? state.streamError || 'The chat request failed.' : 'A hidden conversation finished.'),
    route: 'chat',
    action: 'open',
    urgency: failed ? 'critical' : 'normal'
  }).catch(() => {
    // Native notifications are optional; unseen state remains available in-app.
  });
}

export const useChatWorkspaceStore = createChatWorkspaceStore({
  onHiddenCompletion: postHiddenPaneCompletion
});
