import { create } from 'zustand';
import {
  GatewayChatError,
  streamGatewayChatNative,
  type GatewayChatStreamEvent
} from '../chat/gatewayClient.js';
import { fixtureConfigSnapshot, fixtureSessionList } from '../daemonFixture.js';
import { markStart } from '../perfMarks.js';
import type {
  ChatMessageAppendRequest,
  ChatThreadSummary,
  ConfigSnapshot,
  PersistedChatMessage
} from '../tauriBridge.js';
import type { ChatBackendId, ChatWarningBanner, MemoryCitation } from '../surfaces/chat/chatTypes.js';
import { useShellStore } from './shellStore.js';

export const CHAT_THREAD_PAGE_SIZE = 40;

export type ChatMessageRole = 'user' | 'assistant' | 'system' | 'tool' | 'thinking';

export type ChatMessage = {
  id: string;
  role: ChatMessageRole;
  text: string;
  threadID?: string;
  timestamp?: string;
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
  threads: ChatThreadSummary[];
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
  sendToThread(input: { threadID?: string; backend: ChatBackendId; text: string }): Promise<void>;
  sendMessage(text: string): Promise<void>;
  stopStreaming(): void;
};

function fixtureThreads(): ChatThreadSummary[] {
  return fixtureSessionList().sessions.map((session) => ({
    id: session.id,
    title: session.title,
    preview: `Fixture ${session.provider} / ${session.model} transcript`,
    messageCount: Math.max(2, Math.round(session.tokens / 1200)),
    createdAt: session.startedAt,
    updatedAt: session.startedAt,
    lastMessageAt: session.startedAt,
    backendID: session.provider
  }));
}

function filterFixtureThreads(threads: ChatThreadSummary[], query: string): ChatThreadSummary[] {
  const q = query.trim().toLowerCase();
  if (!q) return threads;
  return threads.filter(
    (thread) =>
      thread.title.toLowerCase().includes(q) ||
      thread.preview.toLowerCase().includes(q) ||
      thread.backendID?.toLowerCase().includes(q) ||
      thread.id.toLowerCase().includes(q)
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

function messagesForFixture(thread: ChatThreadSummary): ChatMessage[] {
  const user: ChatMessage = {
    id: `${thread.id}-user`,
    role: 'user',
    text: thread.title || 'Untitled conversation',
    threadID: thread.id,
    timestamp: thread.createdAt
  };
  const thinking: ChatMessage = {
    id: `${thread.id}-thinking`,
    role: 'thinking',
    text: 'Reviewing provider logs and prior context before drafting a reply.'
  };
  const assistant: ChatMessage = {
    id: `${thread.id}-assistant`,
    role: 'assistant',
    text: 'Pulled indexed excerpts for this thread and drafted a concise answer from your recent provider spend and session metadata.',
    threadID: thread.id,
    timestamp: thread.updatedAt,
    viaHermes: true,
    provider: thread.backendID,
    memoryCitations: [
      { id: 'mem-1', label: 'BurnBar memory · quota pacing', messageId: `${thread.id}-assistant` },
      { id: 'mem-2', label: 'Indexed session · provider mix', messageId: `${thread.id}-assistant` }
    ]
  };
  const tool: ChatMessage = {
    id: `${thread.id}-tool`,
    role: 'tool',
    text: 'Tool invocation summary',
    toolName: 'hermes.tool',
    toolState: 'done'
  };
  return [user, thinking, assistant, tool];
}

async function fetchThreads(
  query: string
): Promise<{ threads: ChatThreadSummary[]; config: ConfigSnapshot | null }> {
  const { fixtureMode, bridge } = useShellStore.getState();
  if (fixtureMode) {
    const all = fixtureThreads();
    const threads = query ? filterFixtureThreads(all, query) : all;
    return {
      threads,
      config: fixtureConfigSnapshot()
    };
  }
  if (!bridge) {
    return { threads: [], config: null };
  }
  const result = await bridge.chatThreadList(query.trim() || undefined, 100);
  let config: ConfigSnapshot | null = null;
  try {
    config = await bridge.configSnapshot();
  } catch {
    config = null;
  }
  return { threads: result.threads, config };
}

function backendFromThread(thread: ChatThreadSummary | null, fallback: ChatBackendId): ChatBackendId {
  switch (thread?.backendID?.trim().toLowerCase()) {
    case 'hermes':
    case 'openclaw':
      return 'hermes';
    case 'codex':
    case 'openai':
      return 'codex';
    case 'claude':
    case 'claude-code':
    case 'anthropic':
      return 'claude';
    case 'pi':
    case 'pi-agent':
      return 'pi-agent';
    case 'cli':
      return 'cli';
    default:
      return fallback;
  }
}

function modelLabelForThread(_thread: ChatThreadSummary | null, backend: ChatBackendId): string {
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

function messageFromPersisted(message: PersistedChatMessage): ChatMessage {
  return {
    id: message.id,
    role: message.role,
    text: message.content,
    threadID: message.threadID,
    timestamp: message.timestamp,
    viaHermes: message.role === 'assistant' && (message.backendID === 'hermes' || message.backendID === 'openclaw'),
    provider: message.backendID
  };
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
): Promise<{ status: ChatGatewayStatus; baseURL: string | null }> {
  if (fixtureMode) return { status: 'reachable', baseURL: 'fixture://gateway' };
  const baseURL = gatewayBaseURLFromHealth();
  if (!baseURL) return { status: 'disabled', baseURL: null };
  const bridge = useShellStore.getState().bridge;
  const reachable = (await bridge?.gatewayProbe().catch(() => false)) ?? false;
  return { status: reachable ? 'reachable' : 'unreachable', baseURL };
}

let transientIDSequence = 0;

function newId(prefix: string): string {
  transientIDSequence = (transientIDSequence + 1) % Number.MAX_SAFE_INTEGER;
  return `${prefix}-${Date.now().toString(36)}-${transientIDSequence.toString(36)}`;
}

function newUUID(): string {
  if (typeof globalThis.crypto?.randomUUID === 'function') return globalThis.crypto.randomUUID();
  if (typeof globalThis.crypto?.getRandomValues !== 'function') {
    throw new Error('Secure UUID generation is unavailable.');
  }
  const bytes = new Uint8Array(16);
  globalThis.crypto.getRandomValues(bytes);
  bytes[6] = (bytes[6]! & 0x0f) | 0x40;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

async function refreshThreadSummaries(query: string): Promise<void> {
  const { fixtureMode } = useShellStore.getState();
  if (fixtureMode) return;
  try {
    const { threads, config } = await fetchThreads(query);
    useChatStore.setState({ threads, nextCursor: null, config });
  } catch {
    // Summary refresh is ancillary; a persisted turn must still reach the gateway.
    console.error('linux_chat_thread_refresh_failed');
  }
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
      const { threads, config } = await fetchThreads(query);
      const gateway = await resolveGatewayStatus(fixtureMode);
      const prevSelected = get().selectedThreadId;
      const stillThere = prevSelected && threads.some((t) => t.id === prevSelected);
      const selectedThreadId = stillThere ? prevSelected : threads[0]?.id ?? null;
      const selected = threads.find((t) => t.id === selectedThreadId) ?? null;
      const selectedBackend = backendFromThread(selected, get().backend);
      set({
        threads,
        nextCursor: null,
        config,
        loading: false,
        error: null,
        visibleThreadCount: CHAT_THREAD_PAGE_SIZE,
        selectedThreadId,
        backend: selectedBackend,
        warnings: fixtureMode ? fixtureWarnings() : [],
        sharedFeaturesAvailable: fixtureMode ? false : true,
        modelLabel: modelLabelForThread(selected, selectedBackend),
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
    if (get().streaming || get().streamPhase === 'composing') return;
    const { fixtureMode, bridge } = useShellStore.getState();
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
    const thread = get().threads.find((t) => t.id === id) ?? null;
    const selectedBackend = backendFromThread(thread, get().backend);
    set({
      selectedThreadId: id,
      messagesLoading: true,
      backend: selectedBackend,
      modelLabel: modelLabelForThread(thread, selectedBackend),
      streaming: false,
      streamPhase: 'idle',
      streamError: null
    });
    try {
      const result = fixtureMode || !bridge ? null : await bridge.chatThreadGet(id, 500);
      const resolvedThread = result?.thread ?? thread;
      const resolvedBackend = backendFromThread(resolvedThread, selectedBackend);
      const messages = fixtureMode
        ? thread
          ? messagesForFixture(thread)
          : []
        : result?.messages.map(messageFromPersisted) ?? [];
      if (get().selectedThreadId === id) {
        set({
          messages,
          messagesLoading: false,
          backend: resolvedBackend,
          modelLabel: modelLabelForThread(resolvedThread, resolvedBackend)
        });
      }
    } catch (error) {
      if (get().selectedThreadId === id) {
        set({
          messages: [],
          messagesLoading: false,
          streamPhase: 'error',
          streamError: error instanceof Error ? error.message : 'Unable to load this thread.'
        });
      }
    }
  },

  loadMoreThreads() {
    set((s) => ({ visibleThreadCount: s.visibleThreadCount + CHAT_THREAD_PAGE_SIZE }));
  },

  setBackend(id: ChatBackendId) {
    if (get().streaming || get().streamPhase === 'composing') return;
    const thread = get().threads.find((t) => t.id === get().selectedThreadId) ?? null;
    set({ backend: id, modelLabel: modelLabelForThread(thread, id) });
  },

  startNewChat() {
    if (get().streaming || get().streamPhase === 'composing') return;
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

  async sendToThread(input) {
    const prompt = input.text.trim();
    const current = get();
    if (!prompt || current.streaming || current.streamPhase === 'composing') return;

    const { fixtureMode, bridge } = useShellStore.getState();
    let threadID: string;
    try {
      threadID = input.threadID ?? current.selectedThreadId ?? newUUID();
    } catch {
      set({
        streamPhase: 'error',
        streamError: 'Secure message identity generation is unavailable.'
      });
      return;
    }
    const backend = input.backend;
    let history = current.selectedThreadId === threadID ? current.messages : [];

    if (!fixtureMode) {
      if (!bridge) {
        set({ streamPhase: 'error', streamError: 'Linux native chat bridge is unavailable.' });
        return;
      }
      if (current.selectedThreadId !== threadID) {
        try {
          history = (await bridge.chatThreadGet(threadID, 500)).messages.map(messageFromPersisted);
        } catch (error) {
          set({
            streamPhase: 'error',
            streamError: error instanceof Error ? error.message : 'Unable to load the target thread.'
          });
          return;
        }
      }
    }

    let userID: string;
    let assistantID: string;
    try {
      userID = newUUID();
      assistantID = newUUID();
    } catch {
      set({
        streamPhase: 'error',
        streamError: 'Secure message identity generation is unavailable.'
      });
      return;
    }
    const userTimestamp = new Date().toISOString();
    const user: ChatMessage = {
      id: userID,
      role: 'user',
      text: prompt,
      threadID,
      timestamp: userTimestamp,
      provider: backend === 'cli' ? undefined : backend
    };
    const assistant: ChatMessage = {
      id: assistantID,
      role: 'assistant',
      text: '',
      threadID,
      viaHermes: backend === 'hermes',
      provider: backend === 'cli' ? undefined : backend
    };
    const controller = new AbortController();
    const outboundHistory = [
      ...history
        .filter((message) => message.role === 'user' || (message.role === 'assistant' && message.text.trim()))
        .map((message) => ({
          role: message.role as 'user' | 'assistant',
          content: message.text
        })),
      { role: 'user' as const, content: prompt }
    ];

    set({
      selectedThreadId: threadID,
      messages: [...history, user],
      messagesLoading: false,
      backend,
      streaming: false,
      streamPhase: 'composing',
      streamError: null,
      activeAbortController: controller,
      modelLabel: modelLabelForThread(get().threads.find((thread) => thread.id === threadID) ?? null, backend)
    });

    try {
      if (!fixtureMode) {
        const appendRequest: ChatMessageAppendRequest = {
          threadID,
          messageID: userID,
          role: 'user',
          content: prompt,
          timestamp: userTimestamp,
          backendID: backend
        };
        await bridge!.chatMessageAppend(appendRequest);
        await refreshThreadSummaries(get().query);
      }

      const gateway = await resolveGatewayStatus(fixtureMode);
      set({ gatewayStatus: gateway.status, gatewayBaseURL: gateway.baseURL });
      if (!fixtureMode && gateway.status !== 'reachable') {
        throw new GatewayChatError(
          'unreachable',
          gateway.status === 'disabled'
            ? 'Gateway chat is disabled in daemon health.'
            : 'Gateway health check failed.'
        );
      }
      const model = get().modelLabel.trim() || 'hermes';
      const stream = fixtureMode
        ? fixtureChatStream()
        : streamGatewayChatNative(
            {
              start: (request, onChunk) => bridge!.gatewayChatStream(request, onChunk),
              cancel: (requestId) => bridge!.gatewayChatCancel(requestId)
            },
            {
              requestId: newUUID(),
              model,
              messages: [{ role: 'system', content: 'You are Hermes inside OpenBurnBar.' }, ...outboundHistory],
              signal: controller.signal
            }
          );
      let firstText = false;
      const endFirstToken = markStart(
        'chat.firstToken.progress',
        fixtureMode ? 'fixture-chat-first-delta' : 'packaged-gateway-first-delta'
      );
      set((state) => ({
        messages: [...state.messages, assistant],
        streaming: true,
        streamPhase: 'streaming'
      }));
      for await (const event of stream) {
        if (controller.signal.aborted) {
          throw new GatewayChatError('aborted', 'Chat stream aborted.');
        }
        if (event.type === 'delta' && !firstText) {
          firstText = true;
          endFirstToken();
        }
        set((state) => ({ messages: applyChatStreamEvent(state.messages, assistantID, event) }));
      }

      const finalAssistant = get().messages.find((message) => message.id === assistantID);
      if (!fixtureMode && finalAssistant?.text.trim()) {
        const timestamp = new Date().toISOString();
        await bridge!.chatMessageAppend({
          threadID,
          messageID: assistantID,
          role: 'assistant',
          content: finalAssistant.text,
          timestamp,
          backendID: backend
        });
        set((state) => ({
          messages: state.messages.map((message) =>
            message.id === assistantID ? { ...message, timestamp } : message
          )
        }));
        await refreshThreadSummaries(get().query);
      }
      set({ streaming: false, streamPhase: 'done', activeAbortController: null });
    } catch (error) {
      const aborted = error instanceof GatewayChatError && error.kind === 'aborted';
      const unimplemented = error instanceof GatewayChatError && error.kind === 'unimplemented';
      set((state) => ({
        messages: state.messages.filter(
          (message) => message.id !== assistantID || Boolean(message.text.trim())
        ),
        streaming: false,
        streamPhase: aborted ? 'aborted' : 'error',
        streamError: unimplemented
          ? 'Gateway chat is not available in this Linux daemon build yet.'
          : error instanceof Error
            ? error.message
            : 'Chat stream failed.',
        activeAbortController: null
      }));
    }
  },

  async sendMessage(text: string) {
    await get().sendToThread({
      threadID: get().selectedThreadId ?? undefined,
      backend: get().backend,
      text
    });
  },

  stopStreaming() {
    const controller = get().activeAbortController;
    if (!controller) return;
    controller.abort();
    set({ streamPhase: 'aborted' });
  }
}));
