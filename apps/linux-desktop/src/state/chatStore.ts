import { create } from 'zustand';
import { fixtureConfigSnapshot, fixtureSessionList } from '../daemonFixture.js';
import type { ConfigSnapshot, SessionEntry, SessionListResult } from '../tauriBridge.js';
import type { ChatBackendId, ChatWarningBanner, MemoryCitation } from '../surfaces/chat/chatTypes.js';
import { useShellStore } from './shellStore.js';

export const CHAT_THREAD_PAGE_SIZE = 40;

export type ChatMessageRole = 'user' | 'assistant' | 'tool' | 'thinking';

export type ChatMessage = {
  id: string;
  role: ChatMessageRole;
  text: string;
  toolName?: string;
  toolState?: 'proposed' | 'approved' | 'denied' | 'done';
  viaHermes?: boolean;
  memoryCitations?: MemoryCitation[];
};

export type ChatState = {
  threads: SessionEntry[];
  nextCursor: string | null;
  selectedThreadId: string | null;
  messages: ChatMessage[];
  messagesLoading: boolean;
  config: ConfigSnapshot | null;
  loading: boolean;
  error: string | null;
  query: string;
  visibleThreadCount: number;
  backend: ChatBackendId;
  modelLabel: string;
  streaming: boolean;
  warnings: ChatWarningBanner[];
  sharedFeaturesAvailable: boolean;
  load(): Promise<void>;
  search(query: string): Promise<void>;
  selectThread(id: string | null): Promise<void>;
  loadMoreThreads(): void;
  setBackend(id: ChatBackendId): void;
  startNewChat(): void;
  stopStreaming(): void;
};

function filterFixtureThreads(sessions: SessionEntry[], query: string): SessionEntry[] {
  const q = query.trim().toLowerCase();
  if (!q) return sessions;
  return sessions.filter(
    (s) =>
      s.title.toLowerCase().includes(q) ||
      s.provider.toLowerCase().includes(q) ||
      s.model.toLowerCase().includes(q) ||
      s.id.toLowerCase().includes(q)
  );
}

function fixtureWarnings(): ChatWarningBanner[] {
  return [
    {
      id: 'index-stale',
      title: 'Index stale',
      message: 'Session index is older than the live gateway feed. Retrieval may miss recent turns until the daemon finishes re-indexing.'
    },
    {
      id: 'cloud-shared',
      title: 'Cloud / shared unavailable',
      message: 'Shared cloud memory and cross-device citations are offline in this Linux shell build. Local indexed sessions still load.'
    }
  ];
}

function messagesForSession(session: SessionEntry, fixtureMode: boolean): ChatMessage[] {
  const started = new Date(session.startedAt).toLocaleString();
  const user: ChatMessage = {
    id: `${session.id}-user`,
    role: 'user',
    text: session.title || 'Untitled conversation'
  };
  const thinking: ChatMessage = {
    id: `${session.id}-thinking`,
    role: 'thinking',
    text: fixtureMode
      ? 'Reviewing provider logs and prior context before drafting a reply.'
      : 'Reasoning stream is not wired on Linux v1 — showing session index metadata only.'
  };
  const assistant: ChatMessage = {
    id: `${session.id}-assistant`,
    role: 'assistant',
    text: fixtureMode
      ? 'Pulled indexed excerpts for this thread and drafted a concise answer from your recent provider spend and session metadata.'
      : `Indexed session · ${session.provider} / ${session.model} · ${started} · ${session.tokens.toLocaleString()} tokens · $${session.costUsd.toFixed(2)}. Full transcript replay ships when the daemon exposes thread messages on this bridge.`,
    viaHermes: fixtureMode || session.provider === 'hermes' || session.provider === 'openclaw',
    memoryCitations: fixtureMode
      ? [
          { id: 'mem-1', label: 'BurnBar memory · quota pacing', messageId: `${session.id}-assistant` },
          { id: 'mem-2', label: 'Indexed session · provider mix', messageId: `${session.id}-assistant` }
        ]
      : undefined
  };
  const tool: ChatMessage = {
    id: `${session.id}-tool`,
    role: 'tool',
    text: 'Tool invocation summary',
    toolName: 'hermes.tool',
    toolState: fixtureMode ? 'done' : 'proposed'
  };
  return fixtureMode ? [user, thinking, assistant, tool] : [user, assistant];
}

async function fetchThreads(
  query: string
): Promise<{ result: SessionListResult; config: ConfigSnapshot | null }> {
  const { fixtureMode, bridge } = useShellStore.getState();
  if (fixtureMode) {
    const all = fixtureSessionList();
    const sessions = query ? filterFixtureThreads(all.sessions, query) : all.sessions;
    return {
      result: { sessions, nextCursor: all.nextCursor },
      config: fixtureConfigSnapshot()
    };
  }
  if (!bridge) {
    return { result: { sessions: [], nextCursor: null }, config: null };
  }
  const result = query ? await bridge.sessionSearch(query) : await bridge.sessionList();
  let config: ConfigSnapshot | null = null;
  try {
    config = await bridge.configSnapshot();
  } catch {
    config = null;
  }
  return { result, config };
}

function modelLabelForThread(thread: SessionEntry | null, backend: ChatBackendId): string {
  if (thread) return `${thread.provider} / ${thread.model}`;
  switch (backend) {
    case 'codex':
      return 'gpt-5.4-codex';
    case 'claude':
      return 'claude-sonnet-4';
    case 'pi-agent':
      return 'pi-agent';
    case 'cli':
      return 'CLI assistant';
    default:
      return 'hermes-gateway';
  }
}

export const useChatStore = create<ChatState>()((set, get) => ({
  threads: [],
  nextCursor: null,
  selectedThreadId: null,
  messages: [],
  messagesLoading: false,
  config: null,
  loading: false,
  error: null,
  query: '',
  visibleThreadCount: CHAT_THREAD_PAGE_SIZE,
  backend: 'hermes',
  modelLabel: 'hermes-gateway',
  streaming: false,
  warnings: [],
  sharedFeaturesAvailable: true,

  async load() {
    const { query } = get();
    const { fixtureMode, bridge } = useShellStore.getState();
    if (!fixtureMode && !bridge) {
      set({
        threads: [],
        nextCursor: null,
        config: null,
        loading: false,
        error: null,
        visibleThreadCount: CHAT_THREAD_PAGE_SIZE,
        messages: [],
        selectedThreadId: null,
        warnings: [],
        sharedFeaturesAvailable: true,
        streaming: false
      });
      return;
    }
    set({ loading: true, error: null });
    try {
      const { result, config } = await fetchThreads(query);
      const prevSelected = get().selectedThreadId;
      const stillThere = prevSelected && result.sessions.some((t) => t.id === prevSelected);
      const selectedThreadId = stillThere ? prevSelected : result.sessions[0]?.id ?? null;
      const selected = result.sessions.find((t) => t.id === selectedThreadId) ?? null;
      set({
        threads: result.sessions,
        nextCursor: result.nextCursor,
        config,
        loading: false,
        error: null,
        visibleThreadCount: CHAT_THREAD_PAGE_SIZE,
        selectedThreadId,
        warnings: fixtureMode ? fixtureWarnings() : [],
        sharedFeaturesAvailable: fixtureMode ? false : true,
        modelLabel: modelLabelForThread(selected, get().backend),
        streaming: false
      });
      await get().selectThread(selectedThreadId);
    } catch (e) {
      set({
        threads: [],
        nextCursor: null,
        config: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Request failed',
        messages: [],
        selectedThreadId: null,
        warnings: [],
        streaming: false
      });
    }
  },

  async search(query: string) {
    set({ query, visibleThreadCount: CHAT_THREAD_PAGE_SIZE });
    await get().load();
  },

  async selectThread(id: string | null) {
    const { fixtureMode } = useShellStore.getState();
    if (!id) {
      set({
        selectedThreadId: null,
        messages: [],
        messagesLoading: false,
        modelLabel: modelLabelForThread(null, get().backend),
        streaming: false
      });
      return;
    }
    const thread = get().threads.find((t) => t.id === id);
    if (!thread) {
      set({ selectedThreadId: id, messages: [], messagesLoading: false, streaming: false });
      return;
    }
    set({
      selectedThreadId: id,
      messagesLoading: true,
      modelLabel: modelLabelForThread(thread, get().backend),
      streaming: false
    });
    const messages = messagesForSession(thread, fixtureMode);
    set({ messages, messagesLoading: false });
  },

  loadMoreThreads() {
    set((s) => ({ visibleThreadCount: s.visibleThreadCount + CHAT_THREAD_PAGE_SIZE }));
  },

  setBackend(id: ChatBackendId) {
    const thread = get().threads.find((t) => t.id === get().selectedThreadId) ?? null;
    set({ backend: id, modelLabel: modelLabelForThread(thread, id) });
  },

  startNewChat() {
    set({
      selectedThreadId: null,
      messages: [],
      messagesLoading: false,
      streaming: false,
      modelLabel: modelLabelForThread(null, get().backend)
    });
  },

  stopStreaming() {
    set({ streaming: false });
  }
}));