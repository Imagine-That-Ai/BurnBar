import { create } from 'zustand';
import {
  GatewayChatError,
  probeGatewayHealth,
  streamGatewayChat,
  type GatewayChatStreamEvent
} from '../chat/gatewayClient.js';
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
  toolArgsSummary?: string;
  toolState?: 'proposed' | 'approved' | 'denied' | 'done' | 'running';
  viaHermes?: boolean;
  /** Indexed/live session provider id when known (codex, claude-code, hermes, …). */
  provider?: string;
  memoryCitations?: MemoryCitation[];
};

export type ChatStreamPhase = 'idle' | 'composing' | 'streaming' | 'done' | 'error' | 'aborted';
export type ChatGatewayStatus = 'unknown' | 'reachable' | 'unreachable' | 'disabled';

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
  streamPhase: ChatStreamPhase;
  streamError: string | null;
  gatewayStatus: ChatGatewayStatus;
  gatewayBaseURL: string | null;
  activeAbortController: AbortController | null;
  warnings: ChatWarningBanner[];
  sharedFeaturesAvailable: boolean;
  load(): Promise<void>;
  search(query: string): Promise<void>;
  selectThread(id: string | null): Promise<void>;
  loadMoreThreads(): void;
  setBackend(id: ChatBackendId): void;
  startNewChat(): void;
  sendMessage(text: string): Promise<void>;
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
    provider: session.provider,
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
      return 'hermes';
  }
}

function gatewayBaseURLFromHealth(): string | null {
  const health = useShellStore.getState().health;
  if (!health?.ok || !health.gatewayEnabled) return null;
  const host = health.gatewayHost?.trim() || '127.0.0.1';
  const port = health.gatewayPort;
  if (!port) return null;
  return `http://${host}:${port}`;
}

async function resolveGatewayStatus(
  fixtureMode: boolean
): Promise<{ status: ChatGatewayStatus; baseURL: string | null; bearerToken?: string }> {
  if (fixtureMode) return { status: 'reachable', baseURL: 'fixture://gateway' };
  const baseURL = gatewayBaseURLFromHealth();
  if (!baseURL) return { status: 'disabled', baseURL: null };
  const bridge = useShellStore.getState().bridge;
  const bearerToken = (await bridge?.gatewayAuthToken?.().catch(() => null)) ?? undefined;
  const reachable = await probeGatewayHealth(baseURL, bearerToken);
  return { status: reachable ? 'reachable' : 'unreachable', baseURL, bearerToken };
}

function newId(prefix: string): string {
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

function summarizeToolArgs(args: string): string {
  const trimmed = args.trim();
  if (!trimmed) return 'No arguments';
  try {
    const parsed = JSON.parse(trimmed) as Record<string, unknown>;
    for (const key of ['path', 'command', 'url', 'selector', 'text', 'query']) {
      const value = parsed[key];
      if (typeof value === 'string' && value.trim()) return value.slice(0, 160);
    }
  } catch {
    // Raw streamed fragments are still useful as an args summary.
  }
  return trimmed.slice(0, 160);
}

export function applyChatStreamEvent(messages: ChatMessage[], assistantId: string, event: GatewayChatStreamEvent): ChatMessage[] {
  switch (event.type) {
    case 'delta':
      return messages.map((message) =>
        message.id === assistantId ? { ...message, text: message.text + event.text } : message
      );
    case 'thinking':
      return [
        ...messages,
        {
          id: newId('thinking'),
          role: 'thinking',
          text: event.text
        }
      ];
    case 'tool_call':
      if (messages.some((message) => message.id === event.toolCall.id && message.role === 'tool')) {
        return messages.map((message) =>
          message.id === event.toolCall.id
            ? {
                ...message,
                text: summarizeToolArgs(event.toolCall.arguments),
                toolName: event.toolCall.name,
                toolArgsSummary: summarizeToolArgs(event.toolCall.arguments)
              }
            : message
        );
      }
      return [
        ...messages,
        {
          id: event.toolCall.id,
          role: 'tool',
          text: summarizeToolArgs(event.toolCall.arguments),
          toolName: event.toolCall.name,
          toolArgsSummary: summarizeToolArgs(event.toolCall.arguments),
          toolState: 'proposed'
        }
      ];
    case 'usage':
      return messages;
    case 'done':
      return messages;
    default: {
      const exhaustive: never = event;
      return exhaustive;
    }
  }
}

async function* fixtureChatStream(): AsyncGenerator<GatewayChatStreamEvent, void, void> {
  const events: GatewayChatStreamEvent[] = [
    { type: 'thinking', text: 'Checking the local Linux shell context and current gateway readiness.' },
    { type: 'delta', text: 'Fixture stream online. ' },
    { type: 'tool_call', toolCall: { id: 'fixture-tool-call', name: 'workspace.read', arguments: '{"path":"README.md"}' } },
    { type: 'delta', text: 'The live chat client can append streamed assistant text, show thinking, and preserve tool approval as an explicit gap.' },
    { type: 'usage', usage: { promptTokens: 42, completionTokens: 31, totalTokens: 73 } },
    { type: 'done', finishReason: 'stop' }
  ];
  for (const event of events) {
    await new Promise((resolve) => globalThis.setTimeout(resolve, 5));
    yield event;
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
  modelLabel: 'hermes',
  streaming: false,
  streamPhase: 'idle',
  streamError: null,
  gatewayStatus: 'unknown',
  gatewayBaseURL: null,
  activeAbortController: null,
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
      const gateway = await resolveGatewayStatus(fixtureMode);
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
        streaming: false,
        streamPhase: 'idle',
        streamError: null,
        gatewayStatus: gateway.status,
        gatewayBaseURL: gateway.baseURL,
        activeAbortController: null
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
        streaming: false,
        streamPhase: 'error',
        streamError: e instanceof Error ? e.message : 'Request failed',
        activeAbortController: null
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
        streaming: false,
        streamPhase: 'idle',
        streamError: null
      });
      return;
    }
    const thread = get().threads.find((t) => t.id === id);
    if (!thread) {
      set({ selectedThreadId: id, messages: [], messagesLoading: false, streaming: false, streamPhase: 'idle', streamError: null });
      return;
    }
    set({
      selectedThreadId: id,
      messagesLoading: true,
      modelLabel: modelLabelForThread(thread, get().backend),
      streaming: false,
      streamPhase: 'idle',
      streamError: null
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
      streamPhase: 'idle',
      streamError: null,
      modelLabel: modelLabelForThread(null, get().backend)
    });
  },

  async sendMessage(text: string) {
    const prompt = text.trim();
    if (!prompt || get().streaming) return;
    const { fixtureMode, bridge } = useShellStore.getState();
    const user: ChatMessage = { id: newId('user'), role: 'user', text: prompt };
    const assistantId = newId('assistant');
    const backend = get().backend;
    const assistant: ChatMessage = {
      id: assistantId,
      role: 'assistant',
      text: '',
      viaHermes: backend === 'hermes',
      provider: backend === 'cli' ? undefined : backend
    };
    const controller = new AbortController();
    const outboundHistory = [
      ...get()
        .messages.filter((message) => message.role === 'user' || (message.role === 'assistant' && message.text.trim()))
        .map((message) => ({
          role: message.role as 'user' | 'assistant',
          content: message.text
        })),
      { role: 'user' as const, content: prompt }
    ];
    set((state) => ({
      selectedThreadId: null,
      messages: [...state.messages, user, assistant],
      streaming: false,
      streamPhase: 'composing',
      streamError: null,
      activeAbortController: controller,
      modelLabel: modelLabelForThread(null, state.backend)
    }));

    try {
      const gateway = await resolveGatewayStatus(fixtureMode);
      set({ gatewayStatus: gateway.status, gatewayBaseURL: gateway.baseURL });
      if (!fixtureMode && gateway.status !== 'reachable') {
        throw new GatewayChatError('unreachable', gateway.status === 'disabled' ? 'Gateway chat is disabled in daemon health.' : 'Gateway health check failed.');
      }
      const model = get().modelLabel.trim() || 'hermes';
      const stream = fixtureMode
        ? fixtureChatStream()
        : streamGatewayChat({
            baseURL: gateway.baseURL ?? '',
            model,
            messages: [{ role: 'system', content: 'You are Hermes inside OpenBurnBar.' }, ...outboundHistory],
            bearerToken: gateway.bearerToken,
            signal: controller.signal
          });
      let firstText = false;
      set({ streaming: true, streamPhase: 'streaming' });
      for await (const event of stream) {
        if (event.type === 'delta' && !firstText) {
          firstText = true;
          if (bridge) void bridge.measurePerfOperation('chat.firstToken.progress');
        }
        set((state) => ({
          messages: applyChatStreamEvent(state.messages, assistantId, event)
        }));
      }
      set({ streaming: false, streamPhase: 'done', activeAbortController: null });
    } catch (error) {
      const aborted = error instanceof GatewayChatError && error.kind === 'aborted';
      const unimplemented = error instanceof GatewayChatError && error.kind === 'unimplemented';
      set({
        streaming: false,
        streamPhase: aborted ? 'aborted' : 'error',
        streamError: unimplemented
          ? 'Gateway chat is not available in this Linux daemon build yet.'
          : error instanceof Error
            ? error.message
            : 'Chat stream failed.',
        activeAbortController: null
      });
    }
  },

  stopStreaming() {
    get().activeAbortController?.abort();
    set({ streaming: false, streamPhase: 'aborted', activeAbortController: null });
  }
}));
