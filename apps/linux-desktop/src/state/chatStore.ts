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
  ProviderCatalog,
  ChatAttachmentUploadResult,
  PersistedChatMessage
} from '../tauriBridge.js';
import type { GatewayChatAttachmentReference } from '../chat/gatewayClient.js';
import type {
  ChatBackendId,
  ChatApprovalDecision,
  ChatToolApprovalCapability,
  ChatWarningBanner,
  MemoryCitation
} from '../surfaces/chat/chatTypes.js';
import { canSelectChatBackend, chatBackendAvailability } from '../surfaces/chat/chatTypes.js';
import {
  chatModelOptions,
  defaultChatModelSelection,
  selectionForModelOption,
  selectionForThinkingLevel,
  type ChatThinkingSelection
} from '../surfaces/chat/chatOptions.js';
import { useShellStore } from './shellStore.js';

export const CHAT_THREAD_PAGE_SIZE = 40;
/** Bound renderer-side history traversal even if a daemon reports an unbounded transcript. */
export const CHAT_HISTORY_LOAD_MAX_PAGES = 20;
export const CHAT_HISTORY_LOAD_MAX_MESSAGES = 10_000;
/** Only an opaque thread identifier is retained across shell restarts. */
export const CHAT_ACTIVE_THREAD_STORAGE_KEY = 'openburnbar.chat.active-thread.v1';
const CHAT_THREAD_ID_MAX_BYTES = 256;

export type ChatMessageRole = 'user' | 'assistant' | 'system' | 'tool' | 'thinking';

export type ChatMessage = {
  id: string;
  role: ChatMessageRole;
  text: string;
  threadID?: string;
  timestamp?: string;
  toolName?: string;
  toolArgsSummary?: string;
  toolState?: 'proposed' | 'approved' | 'denied' | 'cancelled' | 'error' | 'done' | 'running';
  toolApproval?: ChatToolApprovalCapability;
  viaHermes?: boolean;
  /** Indexed/live session provider id when known (codex, claude-code, hermes, …). */
  provider?: string;
  memoryCitations?: MemoryCitation[];
  /** Metadata for attachments staged on this local turn. Raw bytes never enter the renderer transcript. */
  attachments?: ChatAttachmentUploadResult[];
};

export type ChatStreamPhase = 'idle' | 'composing' | 'streaming' | 'done' | 'error' | 'aborted';
export type ChatGatewayStatus = 'unknown' | 'reachable' | 'unreachable' | 'disabled';

export type ChatState = {
  threads: ChatThreadSummary[];
  nextCursor: string | null;
  selectedThreadId: string | null;
  messages: ChatMessage[];
  messagesLoading: boolean;
  loadingOlderMessages: boolean;
  loadingAllMessages: boolean;
  hasMoreMessages: boolean;
  historyError: string | null;
  config: ConfigSnapshot | null;
  /** Last daemon provider catalog; null means routing capability is unproven. */
  catalog: ProviderCatalog | null;
  loading: boolean;
  error: string | null;
  query: string;
  visibleThreadCount: number;
  backend: ChatBackendId;
  modelLabel: string;
  modelOptionID: string;
  thinkingLevel: ChatThinkingSelection;
  streaming: boolean;
  streamPhase: ChatStreamPhase;
  streamError: string | null;
  gatewayStatus: ChatGatewayStatus;
  gatewayBaseURL: string | null;
  activeAbortController: AbortController | null;
  warnings: ChatWarningBanner[];
  sharedFeaturesAvailable: boolean;
  load(): Promise<void>;
  reconnectGateway(): Promise<void>;
  search(query: string): Promise<void>;
  selectThread(id: string | null): Promise<void>;
  /** Re-reads the selected durable thread after a daemon/shell restart. */
  resumeThread(): Promise<boolean>;
  loadOlderMessages(): Promise<void>;
  /** Boundedly walks every unloaded durable page for the selected thread. */
  loadAllMessages(): Promise<boolean>;
  /** Loads older pages until a durable message is present or the daemon is exhausted. */
  loadUntilMessage(messageID: string, threadID?: string): Promise<boolean>;
  loadMoreThreads(): void;
  setBackend(id: ChatBackendId): void;
  setModelOption(id: string): void;
  setThinkingLevel(level: ChatThinkingSelection): void;
  startNewChat(): void;
  sendToThread(input: {
    threadID?: string;
    backend: ChatBackendId;
    text: string;
    attachments?: ChatAttachmentUploadResult[];
  }): Promise<void>;
  sendMessage(text: string, attachments?: ChatAttachmentUploadResult[]): Promise<void>;
  respondToToolApproval(messageID: string, decision: ChatApprovalDecision): Promise<void>;
  retryToolApproval(messageID: string): Promise<void>;
  stopStreaming(): void;
};

function validStoredThreadID(raw: string | null): string | null {
  if (raw === null || raw.trim() !== raw || raw.length === 0) return null;
  if ([...raw].some((character) => character.charCodeAt(0) < 0x20 || character.charCodeAt(0) === 0x7f)) return null;
  if (new TextEncoder().encode(raw).length > CHAT_THREAD_ID_MAX_BYTES) return null;
  return raw;
}

function readActiveThreadID(): string | null {
  try {
    return validStoredThreadID(globalThis.localStorage?.getItem(CHAT_ACTIVE_THREAD_STORAGE_KEY) ?? null);
  } catch {
    return null;
  }
}

function persistActiveThreadID(threadID: string | null): void {
  try {
    if (threadID) globalThis.localStorage?.setItem(CHAT_ACTIVE_THREAD_STORAGE_KEY, threadID);
    else globalThis.localStorage?.removeItem(CHAT_ACTIVE_THREAD_STORAGE_KEY);
  } catch {
    // Browser storage is only a resume hint; the daemon remains authoritative.
  }
}

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
): Promise<{ threads: ChatThreadSummary[]; config: ConfigSnapshot | null; catalog: ProviderCatalog | null }> {
  const { fixtureMode, bridge } = useShellStore.getState();
  if (fixtureMode) {
    const all = fixtureThreads();
    const threads = query ? filterFixtureThreads(all, query) : all;
    return {
      threads,
      config: fixtureConfigSnapshot(),
      // Fixture transcripts intentionally do not claim live provider routing.
      catalog: null
    };
  }
  if (!bridge) {
    return { threads: [], config: null, catalog: null };
  }
  const result = await bridge.chatThreadList(query.trim() || undefined, 100);
  let config: ConfigSnapshot | null = null;
  try {
    config = await bridge.configSnapshot();
  } catch {
    config = null;
  }
  let catalog: ProviderCatalog | null = null;
  try {
    catalog = typeof bridge.providerCatalog === 'function' ? await bridge.providerCatalog() : null;
  } catch {
    catalog = null;
  }
  return { threads: result.threads, config, catalog };
}

function backendFromThread(thread: ChatThreadSummary | null, fallback: ChatBackendId): ChatBackendId {
  switch (thread?.backendID?.trim().toLowerCase()) {
    case 'hermes':
      return 'hermes';
    case 'openclaw':
      return 'openclaw';
    case 'codex':
    case 'openai':
      return 'codex';
    case 'claude':
    case 'claude-code':
    case 'anthropic':
      return 'claude';
    // macOS persists ChatBackendID.piAgent.rawValue ("piAgent"), which arrives here lowercased.
    case 'pi':
    case 'pi-agent':
    case 'piagent':
      return 'pi-agent';
    case 'openclaude':
      return 'openclaude';
    case 'omp':
      return 'omp';
    case 'droid':
    case 'factory':
      return 'droid';
    case 'forge':
    case 'forgedev':
      return 'forge';
    case 'antigravity':
      return 'antigravity';
    case 'cursor-agent':
    case 'cursoragent':
      return 'cursor-agent';
    case 'junie':
      return 'junie';
    case 'fx':
    case 'vercel-fx':
    case 'vercelfx':
      return 'fx';
    case 'muse':
    case 'muse-code':
    case 'musecode':
    case 'muse_code':
    case 'meta-muse':
    case 'metamuse':
      return 'muse';
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
    case 'openclaw':
      return 'openclaw';
    case 'openclaude':
      return 'openclaude';
    case 'omp':
      return 'omp';
    case 'droid':
      return 'droid';
    case 'forge':
      return 'forge';
    case 'antigravity':
      return 'antigravity';
    case 'cursor-agent':
      return 'cursor-agent';
    case 'junie':
      return 'junie';
    case 'fx':
      return 'fx';
    case 'muse':
      return 'muse';
    case 'cli':
      return 'CLI assistant';
    default:
      return 'hermes';
  }
}

function defaultSelectionForBackend(
  config: ConfigSnapshot | null,
  backend: ChatBackendId
) {
  const selection = defaultChatModelSelection(config, backend, modelLabelForThread(null, backend));
  return {
    modelLabel: selection.modelID,
    modelOptionID: selection.modelOptionID,
    thinkingLevel: selection.thinkingLevel
  };
}

function messageFromPersisted(message: PersistedChatMessage): ChatMessage {
  return {
    id: message.id,
    role: message.role,
    text: message.content,
    threadID: message.threadID,
    timestamp: message.timestamp,
    viaHermes: message.role === 'assistant' && (message.backendID === 'hermes' || message.backendID === 'openclaw'),
    provider: message.backendID,
    attachments: message.attachments
  };
}

function chatPageIdentityError(threadID: string): Error {
  return new Error(`Chat history response does not match thread ${threadID}.`);
}

/** Validate the daemon boundary again at the store so test doubles or older
 * packaged bridges cannot merge another thread into the active transcript. */
function validateChatPage(
  threadID: string,
  result: {
    thread?: ChatThreadSummary;
    messages: PersistedChatMessage[];
  },
  requireThread = true
): void {
  if (requireThread && (!result.thread || result.thread.id !== threadID)) {
    throw chatPageIdentityError(threadID);
  }
  if (result.thread && result.thread.id !== threadID) {
    throw chatPageIdentityError(threadID);
  }
  const seen = new Set<string>();
  for (const message of result.messages) {
    if (message.threadID !== threadID || seen.has(message.id)) {
      throw chatPageIdentityError(threadID);
    }
    seen.add(message.id);
  }
}

function messageCursor(message: PersistedChatMessage | ChatMessage): { timestamp: string; messageID: string } | null {
  if (!message.timestamp || !message.id) return null;
  return { timestamp: message.timestamp, messageID: message.id };
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
    const { threads, config, catalog } = await fetchThreads(query);
    useChatStore.setState({ threads, nextCursor: null, config, catalog });
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

const approvalRequestsInFlight = new Map<string, Promise<void>>();

function approvalErrorMessage(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error);
  const trimmed = raw.trim();
  if (!trimmed) return 'The daemon did not resolve this approval.';
  return trimmed.slice(0, 320);
}

function approvalStateFor(
  approvalID: string | undefined,
  message: ChatMessage
): ChatToolApprovalCapability | undefined {
  if (!approvalID) return message.toolApproval;
  if (
    message.toolApproval &&
    message.toolApproval.state !== 'unavailable' &&
    message.toolApproval.approvalID === approvalID
  ) {
    return message.toolApproval;
  }
  return {
    state: 'pending',
    source: 'daemon-run',
    approvalID
  };
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
    case 'citations':
      return messages.map((message) =>
        message.id === assistantId ? { ...message, memoryCitations: event.citations } : message
      );
    case 'tool_call': {
      const approvalID = event.toolCall.approvalID?.trim() || undefined;
      if (messages.some((message) => message.id === event.toolCall.id && message.role === 'tool')) {
        return messages.map((message) =>
          message.id === event.toolCall.id
            ? {
                ...message,
                text: summarizeToolArgs(event.toolCall.arguments),
                toolName: event.toolCall.name,
                toolArgsSummary: summarizeToolArgs(event.toolCall.arguments),
                toolApproval:
                  approvalStateFor(approvalID, message) ?? {
                    state: 'unavailable',
                    source: 'gateway',
                    reason: 'gateway-tool-call-missing-run-approval-identity',
                    fallbackRoute: 'missions'
                  }
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
          toolState: 'proposed',
          toolApproval: approvalID
            ? { state: 'pending', source: 'daemon-run', approvalID }
            : {
                state: 'unavailable',
                source: 'gateway',
                reason: 'gateway-tool-call-missing-run-approval-identity',
                fallbackRoute: 'missions'
              }
        }
      ];
    }
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
  loadingOlderMessages: false,
  loadingAllMessages: false,
  hasMoreMessages: false,
  historyError: null,
  config: null,
  catalog: null,
  loading: false,
  error: null,
  query: '',
  visibleThreadCount: CHAT_THREAD_PAGE_SIZE,
  backend: 'hermes',
  modelLabel: 'hermes',
  modelOptionID: 'hermes',
  thinkingLevel: 'default',
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
        catalog: null,
        loading: false,
        error: null,
        visibleThreadCount: CHAT_THREAD_PAGE_SIZE,
        messages: [],
        selectedThreadId: null,
        loadingOlderMessages: false,
        loadingAllMessages: false,
        hasMoreMessages: false,
        historyError: null,
        warnings: [],
        sharedFeaturesAvailable: true,
        streaming: false
      });
      return;
    }
    set({ loading: true, error: null });
    try {
      const { threads, config, catalog } = await fetchThreads(query);
      const gateway = await resolveGatewayStatus(fixtureMode);
      const prevSelected = get().selectedThreadId;
      const stillThere = prevSelected && threads.some((t) => t.id === prevSelected);
      const remembered = readActiveThreadID();
      const rememberedStillThere = remembered && threads.some((t) => t.id === remembered);
      const selectedThreadId = stillThere
        ? prevSelected
        : rememberedStillThere
          ? remembered
          : threads[0]?.id ?? null;
      if (!query.trim() && remembered && !rememberedStillThere && !stillThere) {
        persistActiveThreadID(null);
      }
      const selected = threads.find((t) => t.id === selectedThreadId) ?? null;
      const selectedBackend = backendFromThread(selected, get().backend);
      set({
        threads,
        nextCursor: null,
        config,
        catalog,
        loading: false,
        error: null,
        visibleThreadCount: CHAT_THREAD_PAGE_SIZE,
        selectedThreadId,
        backend: selectedBackend,
        warnings: fixtureMode ? fixtureWarnings() : [],
        sharedFeaturesAvailable: fixtureMode ? false : true,
        ...defaultSelectionForBackend(config, selectedBackend),
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
        catalog: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Request failed',
        messages: [],
        selectedThreadId: null,
        loadingOlderMessages: false,
        loadingAllMessages: false,
        hasMoreMessages: false,
        historyError: null,
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

  async reconnectGateway() {
    const { fixtureMode } = useShellStore.getState();
    const gateway = await resolveGatewayStatus(fixtureMode);
    set({
      gatewayStatus: gateway.status,
      gatewayBaseURL: gateway.baseURL,
      streamError: gateway.status === 'reachable' ? null : 'Gateway is still unavailable.'
    });
  },

  async selectThread(id: string | null) {
    if (get().streaming || get().streamPhase === 'composing') return;
    const { fixtureMode, bridge } = useShellStore.getState();
    if (!id) {
      persistActiveThreadID(null);
      set({
        selectedThreadId: null,
        messages: [],
        messagesLoading: false,
        loadingOlderMessages: false,
        loadingAllMessages: false,
        hasMoreMessages: false,
        historyError: null,
        ...defaultSelectionForBackend(get().config, get().backend),
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
      messages: [],
      messagesLoading: true,
      loadingOlderMessages: false,
      loadingAllMessages: false,
      hasMoreMessages: false,
      historyError: null,
      backend: selectedBackend,
      ...defaultSelectionForBackend(get().config, selectedBackend),
      streaming: false,
      streamPhase: 'idle',
      streamError: null
    });
    try {
      const result = fixtureMode || !bridge ? null : await bridge.chatThreadGet(id, 500);
      if (!fixtureMode && result) validateChatPage(id, result);
      const resolvedThread = result?.thread ?? thread;
      if (!fixtureMode && !resolvedThread) {
        throw chatPageIdentityError(id);
      }
      const resolvedBackend = backendFromThread(resolvedThread, selectedBackend);
      const messages = fixtureMode
        ? thread
          ? messagesForFixture(thread)
          : []
        : result?.messages.map(messageFromPersisted) ?? [];
      if (get().selectedThreadId === id) {
        persistActiveThreadID(id);
        set({
          messages,
          messagesLoading: false,
          hasMoreMessages: result?.hasMoreBefore ?? false,
          historyError: null,
          backend: resolvedBackend,
          ...defaultSelectionForBackend(get().config, resolvedBackend)
        });
      }
    } catch (error) {
      if (get().selectedThreadId === id) {
        set({
          messages: [],
          messagesLoading: false,
          loadingOlderMessages: false,
          loadingAllMessages: false,
          hasMoreMessages: false,
          historyError: error instanceof Error ? error.message : 'Unable to load this thread.',
          streamPhase: 'error',
          streamError: null
        });
      }
    }
  },

  async resumeThread() {
    const target = get().selectedThreadId ?? readActiveThreadID();
    if (!target) return false;
    const { fixtureMode, bridge } = useShellStore.getState();

    // Fixture transcripts are renderer-owned. Keep the existing path so the
    // fixture continues to synthesize its deterministic conversation, while a
    // live resume below can be transactional around the daemon request.
    if (fixtureMode || !bridge) {
      await get().selectThread(target);
      const state = get();
      return state.selectedThreadId === target && state.messagesLoading === false && state.streamPhase !== 'error';
    }
    if (get().streaming || get().streamPhase === 'composing') return false;

    const current = get();
    const knownThread = current.threads.find((thread) => thread.id === target) ?? null;
    const selectedBackend = backendFromThread(knownThread, current.backend);

    // Keep the last good transcript visible while the daemon is restarting or
    // reconnecting. A validated page replaces it atomically; a failed resume
    // reports the error without turning a recoverable chat into a blank pane.
    set({
      selectedThreadId: target,
      messagesLoading: true,
      loadingOlderMessages: false,
      loadingAllMessages: false,
      historyError: null,
      backend: selectedBackend,
      ...defaultSelectionForBackend(current.config, selectedBackend),
      streamPhase: 'idle',
      streamError: null
    });

    try {
      const result = await bridge.chatThreadGet(target, 500);
      validateChatPage(target, result);
      const resolvedBackend = backendFromThread(result.thread ?? null, selectedBackend);
      if (get().selectedThreadId !== target) return false;
      persistActiveThreadID(target);
      set({
        messages: result.messages.map(messageFromPersisted),
        messagesLoading: false,
        hasMoreMessages: result.hasMoreBefore,
        historyError: null,
        backend: resolvedBackend,
        ...defaultSelectionForBackend(get().config, resolvedBackend)
      });
      return true;
    } catch (error) {
      if (get().selectedThreadId === target) {
        set({
          messagesLoading: false,
          loadingOlderMessages: false,
          loadingAllMessages: false,
          historyError: error instanceof Error ? error.message : 'Unable to resume this thread.',
          streamPhase: 'error',
          streamError: null
        });
      }
      return false;
    }
  },

  async loadOlderMessages() {
    const state = get();
    const threadID = state.selectedThreadId;
    const { fixtureMode, bridge } = useShellStore.getState();
    if (
      fixtureMode ||
      !bridge ||
      !threadID ||
      !state.hasMoreMessages ||
      state.loadingOlderMessages ||
      state.streaming ||
      state.streamPhase === 'composing'
    ) {
      return;
    }

    // Thinking/tool rows are ephemeral; the first timestamped row is the
    // stable cursor for the oldest durable message currently loaded.
    const oldest = state.messages.find((message) => message.timestamp && message.threadID === threadID);
    if (!oldest?.timestamp) {
      set({ hasMoreMessages: false });
      return;
    }

    set({ loadingOlderMessages: true, historyError: null, streamError: null });
    try {
      const before = messageCursor(oldest);
      if (!before) throw new Error('Unable to establish a durable chat history cursor.');
      const result = await bridge.chatThreadGet(threadID, 500, {
        ...before
      });
      validateChatPage(threadID, result);
      if (get().selectedThreadId !== threadID) return;
      set((current) => {
        const existingIDs = new Set(current.messages.map((message) => message.id));
        if (result.messages.length === 0) {
          if (result.hasMoreBefore) throw new Error('Chat history pagination made no progress.');
          return {
            hasMoreMessages: false,
            loadingOlderMessages: false,
            historyError: null
          };
        }
        if (result.messages.some((message) => existingIDs.has(message.id))) {
          throw new Error('Chat history pagination returned a duplicate message.');
        }
        const next = messageCursor(result.messages[0]!);
        if (!next || (next.timestamp === before.timestamp && next.messageID === before.messageID)) {
          throw new Error('Chat history pagination cursor did not advance.');
        }
        const older = result.messages.map(messageFromPersisted);
        return {
          messages: [...older, ...current.messages],
          hasMoreMessages: result.hasMoreBefore,
          loadingOlderMessages: false,
          historyError: null
        };
      });
    } catch (error) {
      if (get().selectedThreadId === threadID) {
        set({
          loadingOlderMessages: false,
          historyError: error instanceof Error ? error.message : 'Unable to load older messages.',
          streamError: null
        });
      }
    }
  },

  async loadAllMessages() {
    const initial = get();
    const threadID = initial.selectedThreadId;
    const { fixtureMode, bridge } = useShellStore.getState();
    if (
      fixtureMode ||
      !bridge ||
      !threadID ||
      initial.streaming ||
      initial.streamPhase === 'composing' ||
      initial.loadingOlderMessages ||
      initial.loadingAllMessages
    ) {
      return false;
    }
    set({ loadingAllMessages: true, historyError: null });
    try {
      for (let page = 0; page < CHAT_HISTORY_LOAD_MAX_PAGES; page += 1) {
        const state = get();
        if (state.selectedThreadId !== threadID) return false;
        if (!state.hasMoreMessages) {
          set({ loadingAllMessages: false, historyError: null });
          return true;
        }
        if (state.messages.length >= CHAT_HISTORY_LOAD_MAX_MESSAGES) {
          throw new Error('Chat history exceeds the safe load limit.');
        }
        await get().loadOlderMessages();
        const after = get();
        if (after.selectedThreadId !== threadID) return false;
        if (after.historyError) throw new Error(after.historyError);
      }
      if (get().hasMoreMessages) throw new Error('Chat history exceeds the safe page limit.');
      set({ loadingAllMessages: false, historyError: null });
      return true;
    } catch (error) {
      if (get().selectedThreadId === threadID) {
        set({
          loadingAllMessages: false,
          historyError: error instanceof Error ? error.message : 'Unable to load complete chat history.'
        });
      }
      return false;
    }
  },

  async loadUntilMessage(messageID, threadID = get().selectedThreadId ?? undefined) {
    const target = messageID.trim();
    if (!target || !threadID) return false;
    if (get().selectedThreadId !== threadID) return false;
    if (get().messages.some((message) => message.id === target && message.threadID === threadID)) return true;
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode || !bridge || get().streaming || get().streamPhase === 'composing' || get().loadingAllMessages) {
      return false;
    }
    set({ loadingAllMessages: true, historyError: null });
    try {
      for (let page = 0; page < CHAT_HISTORY_LOAD_MAX_PAGES; page += 1) {
        const before = get();
        if (before.messages.some((message) => message.id === target && message.threadID === threadID)) {
          set({ loadingAllMessages: false, historyError: null });
          return true;
        }
        if (!before.hasMoreMessages || before.messages.length >= CHAT_HISTORY_LOAD_MAX_MESSAGES) break;
        await get().loadOlderMessages();
        const after = get();
        if (after.selectedThreadId !== threadID) return false;
        if (after.historyError) throw new Error(after.historyError);
      }
      const found = get().messages.some((message) => message.id === target && message.threadID === threadID);
      if (!found && get().hasMoreMessages) throw new Error('Chat citation is outside the safe history load limit.');
      set({ loadingAllMessages: false, historyError: found ? null : 'The cited message is no longer available.' });
      return found;
    } catch (error) {
      if (get().selectedThreadId === threadID) {
        set({
          loadingAllMessages: false,
          historyError: error instanceof Error ? error.message : 'Unable to load the cited message.'
        });
      }
      return false;
    }
  },

  loadMoreThreads() {
    set((s) => ({ visibleThreadCount: s.visibleThreadCount + CHAT_THREAD_PAGE_SIZE }));
  },

  setBackend(id: ChatBackendId) {
    if (get().streaming || get().streamPhase === 'composing') return;
    if (!canSelectChatBackend(get().config, id, get().catalog)) return;
    set({ backend: id, ...defaultSelectionForBackend(get().config, id) });
  },

  setModelOption(id: string) {
    if (get().streaming || get().streamPhase === 'composing') return;
    const fallback = modelLabelForThread(null, get().backend);
    const options = chatModelOptions(get().config, get().backend, fallback);
    const selection = selectionForModelOption(options, id);
    if (!selection) return;
    set({
      modelLabel: selection.modelID,
      modelOptionID: selection.modelOptionID,
      thinkingLevel: selection.thinkingLevel
    });
  },

  setThinkingLevel(level: ChatThinkingSelection) {
    if (get().streaming || get().streamPhase === 'composing') return;
    const fallback = modelLabelForThread(null, get().backend);
    const options = chatModelOptions(get().config, get().backend, fallback);
    const selection = selectionForThinkingLevel(
      options,
      get().modelOptionID,
      get().modelLabel,
      level
    );
    if (!selection) return;
    set({
      modelLabel: selection.modelID,
      modelOptionID: selection.modelOptionID,
      thinkingLevel: selection.thinkingLevel
    });
  },

  startNewChat() {
    if (get().streaming || get().streamPhase === 'composing') return;
    set({
      selectedThreadId: null,
      messages: [],
      messagesLoading: false,
      loadingOlderMessages: false,
      loadingAllMessages: false,
      hasMoreMessages: false,
      historyError: null,
      streaming: false,
      streamPhase: 'idle',
      streamError: null,
      ...defaultSelectionForBackend(get().config, get().backend)
    });
    persistActiveThreadID(null);
  },

  async sendToThread(input) {
    const prompt = input.text.trim();
    const attachments = input.attachments ?? [];
    const current = get();
    if (!prompt || current.streaming || current.streamPhase === 'composing') return;

    const { fixtureMode, bridge } = useShellStore.getState();
    let threadID: string;
    const availability = chatBackendAvailability(current.config, input.backend, current.catalog);
    if (!fixtureMode && current.config !== null && availability.state !== 'available') {
      set({
        streamPhase: 'error',
        streamError: `Chat backend unavailable: ${availability.reason}`
      });
      return;
    }
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
          const result = await bridge.chatThreadGet(threadID, 500);
          validateChatPage(threadID, result);
          history = result.messages.map(messageFromPersisted);
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
      provider: backend === 'cli' ? undefined : backend,
      attachments: attachments.length > 0 ? attachments : undefined
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
    const selectionState =
      current.selectedThreadId === threadID && current.backend === backend
        ? {
            modelLabel: current.modelLabel,
            modelOptionID: current.modelOptionID,
            thinkingLevel: current.thinkingLevel
          }
        : defaultSelectionForBackend(get().config, backend);
    const hasMoreForTarget = current.selectedThreadId === threadID ? current.hasMoreMessages : false;
    const outboundHistory: Array<{
      role: 'user' | 'assistant';
      content: string;
      attachments?: GatewayChatAttachmentReference[];
    }> = [
      ...history
        .filter((message) => message.role === 'user' || (message.role === 'assistant' && message.text.trim()))
        .map((message) => {
          const entry: {
            role: 'user' | 'assistant';
            content: string;
            attachments?: GatewayChatAttachmentReference[];
          } = { role: message.role as 'user' | 'assistant', content: message.text };
          // Persisted attachment metadata is display-only. Upload refs are
          // daemon-owned one-shot handles and must never be replayed from a
          // later turn or a reloaded transcript.
          return entry;
        }),
      {
        role: 'user' as const,
        content: prompt
      }
    ];
    if (attachments.length > 0) {
      outboundHistory[outboundHistory.length - 1]!.attachments = attachments.map((attachment) => ({
        attachmentId: attachment.attachmentId
      }));
    }

    set({
      selectedThreadId: threadID,
      messages: [...history, user],
      messagesLoading: false,
      hasMoreMessages: hasMoreForTarget,
      backend,
      streaming: false,
      streamPhase: 'composing',
      streamError: null,
      activeAbortController: controller,
      ...selectionState
    });

    // Message IDs the daemon has durably acknowledged. On failure, anything
    // outside this set is rolled back from the in-memory transcript so a
    // non-durable turn can never be replayed as prior context on the next
    // send. Fixture mode has no persistence, so its turns count as committed.
    const committedMessageIds = new Set<string>();

    try {
      if (!fixtureMode) {
        const appendRequest: ChatMessageAppendRequest = {
          threadID,
          messageID: userID,
          role: 'user',
          content: prompt,
          timestamp: userTimestamp,
          backendID: backend,
          attachments: attachments.length > 0 ? attachments : undefined
        };
        await bridge!.chatMessageAppend(appendRequest);
        await refreshThreadSummaries(get().query);
      }
      committedMessageIds.add(userID);

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
      if (fixtureMode) {
        committedMessageIds.add(assistantID);
      } else if (finalAssistant?.text.trim()) {
        const timestamp = new Date().toISOString();
        await bridge!.chatMessageAppend({
          threadID,
          messageID: assistantID,
          role: 'assistant',
          content: finalAssistant.text,
          timestamp,
          backendID: backend
        });
        committedMessageIds.add(assistantID);
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
      // Roll back every message from this turn that the daemon did not
      // durably acknowledge: a user append that rejected, or streamed
      // assistant text whose terminal append rejected. Leaving them in
      // `messages` would feed non-durable turns into the next send's history.
      set((state) => ({
        messages: state.messages.filter((message) => {
          if (message.id === userID) return committedMessageIds.has(userID);
          if (message.id === assistantID) {
            return committedMessageIds.has(assistantID) && Boolean(message.text.trim());
          }
          return true;
        }),
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

  async sendMessage(text: string, attachments: ChatAttachmentUploadResult[] = []) {
    await get().sendToThread({
      threadID: get().selectedThreadId ?? undefined,
      backend: get().backend,
      text,
      attachments
    });
  },

  async respondToToolApproval(messageID, decision) {
    const existing = approvalRequestsInFlight.get(messageID);
    if (existing) return existing;

    const current = get().messages.find((message) => message.id === messageID);
    const approval = current?.toolApproval;
    if (!current || current.role !== 'tool' || !approval || approval.state === 'unavailable') return;
    if (approval.state === 'approved' || approval.state === 'rejected' || approval.state === 'cancelled') return;
    if (!('approvalID' in approval) || !approval.approvalID.trim()) return;

    const bridge = useShellStore.getState().bridge;
    if (!bridge?.toolApprovalRespond) {
      set((state) => ({
        messages: state.messages.map((message) =>
          message.id === messageID && message.toolApproval && 'approvalID' in message.toolApproval
            ? {
                ...message,
                toolState: 'error',
                toolApproval: {
                  ...message.toolApproval,
                  state: 'error',
                  lastDecision: decision,
                  error: 'Linux daemon approval service is unavailable. Reconnect and retry.'
                }
              }
            : message
        )
      }));
      return;
    }

    const approvalID = approval.approvalID;
    set((state) => ({
      messages: state.messages.map((message) =>
        message.id === messageID && message.toolApproval && 'approvalID' in message.toolApproval
          ? {
              ...message,
              toolApproval: {
                ...message.toolApproval,
                state: 'submitting',
                lastDecision: decision,
                error: undefined
              }
            }
          : message
      )
    }));

    const request = (async () => {
      try {
        await bridge.toolApprovalRespond!(approvalID, decision);
        const terminalState = decision === 'approve' ? 'approved' : decision === 'reject' ? 'rejected' : 'cancelled';
        set((state) => ({
          messages: state.messages.map((message) =>
            message.id === messageID &&
            message.toolApproval &&
            'approvalID' in message.toolApproval &&
            message.toolApproval.approvalID === approvalID
              ? {
                  ...message,
                  toolState: terminalState === 'approved' ? 'approved' : terminalState === 'rejected' ? 'denied' : 'cancelled',
                  toolApproval: {
                    ...message.toolApproval,
                    state: terminalState,
                    lastDecision: decision,
                    error: undefined
                  }
                }
              : message
          )
        }));
      } catch (error) {
        set((state) => ({
          messages: state.messages.map((message) =>
            message.id === messageID &&
            message.toolApproval &&
            'approvalID' in message.toolApproval &&
            message.toolApproval.approvalID === approvalID
              ? {
                  ...message,
                  toolState: 'error',
                  toolApproval: {
                    ...message.toolApproval,
                    state: 'error',
                    lastDecision: decision,
                    error: approvalErrorMessage(error)
                  }
                }
              : message
          )
        }));
      } finally {
        approvalRequestsInFlight.delete(messageID);
      }
    })();
    approvalRequestsInFlight.set(messageID, request);
    return request;
  },

  async retryToolApproval(messageID) {
    const message = get().messages.find((candidate) => candidate.id === messageID);
    const approval = message?.toolApproval;
    if (!approval || approval.state !== 'error' || !('lastDecision' in approval) || !approval.lastDecision) return;
    await get().respondToToolApproval(messageID, approval.lastDecision);
  },

  stopStreaming() {
    const controller = get().activeAbortController;
    if (!controller) return;
    controller.abort();
    set({ streamPhase: 'aborted' });
  }
}));
