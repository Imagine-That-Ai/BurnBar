import { afterEach, describe, expect, it, vi } from 'vitest';
import type {
  GatewayProxyEvent,
  GatewayProxyRequest,
  LinuxShellBridge,
  SessionEntry
} from '../tauriBridge.js';
import { useChatStore } from './chatStore.js';
import { useShellStore } from './shellStore.js';

type PendingStream = {
  request: GatewayProxyRequest;
  emit(event: GatewayProxyEvent): void;
  resolve(): void;
};

function deferred<T>(): {
  promise: Promise<T>;
  resolve(value: T): void;
} {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((completion) => {
    resolve = completion;
  });
  return { promise, resolve };
}

function session(id: string, title: string): SessionEntry {
  return {
    id,
    provider: 'codex',
    model: 'gpt-test',
    startedAt: '2026-07-12T00:00:00.000Z',
    tokens: 10,
    costUsd: 0.01,
    title
  };
}

function installGatewayHarness(): {
  pending: PendingStream[];
  cancel: ReturnType<typeof vi.fn>;
} {
  const pending: PendingStream[] = [];
  const cancel = vi.fn(async () => undefined);
  const bridge = {
    gatewayProbe: vi.fn(async () => true),
    gatewayChatStream: vi.fn(
      (request: GatewayProxyRequest, emit: (event: GatewayProxyEvent) => void) =>
        new Promise<void>((resolve) => pending.push({ request, emit, resolve }))
    ),
    gatewayChatCancel: cancel
  } as unknown as LinuxShellBridge;
  useShellStore.setState({
    bridge,
    bridgeReady: true,
    fixtureMode: false,
    health: {
      ok: true,
      gatewayEnabled: true,
      gatewayHost: '127.0.0.1',
      gatewayPort: 8642
    }
  });
  return { pending, cancel };
}

function resetChatStore(): void {
  useChatStore.setState({
    threads: [],
    nextCursor: null,
    selectedThreadId: null,
    messages: [],
    messagesLoading: false,
    config: null,
    loading: false,
    error: null,
    query: '',
    visibleThreadCount: 40,
    backend: 'hermes',
    modelLabel: 'hermes',
    streaming: false,
    streamPhase: 'idle',
    streamError: null,
    gatewayStatus: 'unknown',
    gatewayBaseURL: null,
    activeAbortController: null,
    activeRequestId: null,
    navigationGeneration: 0,
    warnings: [],
    sharedFeaturesAvailable: true
  });
}

afterEach(() => {
  resetChatStore();
  useShellStore.setState({ bridge: null, bridgeReady: true, fixtureMode: false, health: null });
  vi.restoreAllMocks();
});

describe('chat request ownership', () => {
  it('does not let a deferred load clear a newer send owner', async () => {
    const sessionList = deferred<{ sessions: SessionEntry[]; nextCursor: string | null }>();
    const pending: PendingStream[] = [];
    const bridge = {
      sessionList: vi.fn(() => sessionList.promise),
      gatewayProbe: vi.fn(async () => true),
      gatewayChatStream: vi.fn(
        (request: GatewayProxyRequest, emit: (event: GatewayProxyEvent) => void) =>
          new Promise<void>((resolve) => pending.push({ request, emit, resolve }))
      ),
      gatewayChatCancel: vi.fn(async () => undefined)
    } as unknown as LinuxShellBridge;
    useShellStore.setState({
      bridge,
      bridgeReady: true,
      fixtureMode: false,
      health: {
        ok: true,
        gatewayEnabled: true,
        gatewayHost: '127.0.0.1',
        gatewayPort: 8642
      }
    });

    const load = useChatStore.getState().load();
    await vi.waitFor(() => expect(bridge.sessionList).toHaveBeenCalledOnce());
    const send = useChatStore.getState().sendMessage('new request owns the store');
    await vi.waitFor(() => expect(pending).toHaveLength(1));
    const activeRequestId = pending[0].request.requestId;

    sessionList.resolve({ sessions: [session('stale-thread', 'Stale load')], nextCursor: null });
    await load;
    expect(useChatStore.getState().activeRequestId).toBe(activeRequestId);
    expect(useChatStore.getState().activeAbortController).not.toBeNull();
    expect(useChatStore.getState().streamPhase).toBe('streaming');
    expect(useChatStore.getState().loading).toBe(false);
    expect(useChatStore.getState().threads).toEqual([]);

    pending[0].emit({ type: 'delta', text: 'new response' });
    pending[0].emit({ type: 'done', finishReason: 'stop' });
    pending[0].resolve();
    await send;
    expect(useChatStore.getState().streamPhase).toBe('done');
    expect(useChatStore.getState().messages.some((message) => message.text === 'new response')).toBe(true);
  });

  it('keeps concurrent search results owned by the newest search generation', async () => {
    const oldSearch = deferred<{ sessions: SessionEntry[]; nextCursor: string | null }>();
    const newSearch = deferred<{ sessions: SessionEntry[]; nextCursor: string | null }>();
    const sessionSearch = vi.fn((query: string) =>
      query === 'old' ? oldSearch.promise : newSearch.promise
    );
    const bridge = {
      sessionSearch,
      gatewayProbe: vi.fn(async () => true)
    } as unknown as LinuxShellBridge;
    useShellStore.setState({
      bridge,
      bridgeReady: true,
      fixtureMode: false,
      health: {
        ok: true,
        gatewayEnabled: true,
        gatewayHost: '127.0.0.1',
        gatewayPort: 8642
      }
    });

    const first = useChatStore.getState().search('old');
    await vi.waitFor(() => expect(sessionSearch).toHaveBeenCalledWith('old'));
    const second = useChatStore.getState().search('new');
    await vi.waitFor(() => expect(sessionSearch).toHaveBeenCalledWith('new'));

    newSearch.resolve({ sessions: [session('new-thread', 'New result')], nextCursor: null });
    await second;
    oldSearch.resolve({ sessions: [session('old-thread', 'Old stale result')], nextCursor: null });
    await first;

    const state = useChatStore.getState();
    expect(state.query).toBe('new');
    expect(state.threads.map((thread) => thread.id)).toEqual(['new-thread']);
    expect(state.selectedThreadId).toBe('new-thread');
    expect(state.messages.map((message) => message.text).join(' ')).toContain('New result');
    expect(state.messages.map((message) => message.text).join(' ')).not.toContain('Old stale result');
    expect(state.loading).toBe(false);
  });

  it('keeps a stop-immediate-resend owned by the newer request', async () => {
    const { pending, cancel } = installGatewayHarness();
    const firstSend = useChatStore.getState().sendMessage('first request');
    await vi.waitFor(() => expect(pending).toHaveLength(1));
    const firstRequestId = pending[0].request.requestId;

    useChatStore.getState().stopStreaming();
    const secondSend = useChatStore.getState().sendMessage('fresh request');
    await vi.waitFor(() => expect(pending).toHaveLength(2));
    pending[1].emit({ type: 'delta', text: 'fresh response' });
    pending[1].emit({ type: 'done', finishReason: 'stop' });
    pending[1].resolve();

    await Promise.all([firstSend, secondSend]);
    const state = useChatStore.getState();
    expect(cancel).toHaveBeenCalledWith(firstRequestId);
    expect(state.streamPhase).toBe('done');
    expect(state.streaming).toBe(false);
    expect(state.activeRequestId).toBeNull();
    expect(state.activeAbortController).toBeNull();
    expect(state.streamError).toBeNull();
    expect(state.messages.some((message) => message.text === 'fresh response')).toBe(true);
  });

  it('aborts a live request before selecting a thread and ignores late events', async () => {
    const { pending, cancel } = installGatewayHarness();
    const thread = session('thread-1', 'Loaded thread');
    useChatStore.setState({ threads: [thread] });
    const send = useChatStore.getState().sendMessage('streaming request');
    await vi.waitFor(() => expect(pending).toHaveLength(1));
    const requestId = pending[0].request.requestId;
    pending[0].emit({ type: 'delta', text: 'old partial' });

    await useChatStore.getState().selectThread(thread.id);
    pending[0].emit({ type: 'delta', text: 'late stale text' });
    pending[0].resolve();
    await send;

    const state = useChatStore.getState();
    expect(cancel).toHaveBeenCalledWith(requestId);
    expect(state.selectedThreadId).toBe(thread.id);
    expect(state.streamPhase).toBe('idle');
    expect(state.activeRequestId).toBeNull();
    expect(state.messages.map((message) => message.text).join(' ')).toContain('Loaded thread');
    expect(state.messages.map((message) => message.text).join(' ')).not.toContain('late stale text');
    expect(state.messages.map((message) => message.text).join(' ')).not.toContain('old partial');
  });

  it('aborts a live request before starting a new chat', async () => {
    const { pending, cancel } = installGatewayHarness();
    const send = useChatStore.getState().sendMessage('streaming request');
    await vi.waitFor(() => expect(pending).toHaveLength(1));
    const requestId = pending[0].request.requestId;

    useChatStore.getState().startNewChat();
    pending[0].emit({ type: 'delta', text: 'late stale text' });
    pending[0].resolve();
    await send;

    const state = useChatStore.getState();
    expect(cancel).toHaveBeenCalledWith(requestId);
    expect(state.selectedThreadId).toBeNull();
    expect(state.messages).toEqual([]);
    expect(state.streamPhase).toBe('idle');
    expect(state.activeRequestId).toBeNull();
    expect(state.activeAbortController).toBeNull();
  });
});
