import { afterEach, describe, expect, it, vi } from 'vitest';
import type {
  ChatMessageAppendRequest,
  ChatThreadSummary,
  GatewayProxyRequest,
  LinuxShellBridge,
  PersistedChatMessage
} from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';
import {
  applyChatStreamEvent,
  CHAT_ACTIVE_THREAD_STORAGE_KEY,
  createChatController,
  useChatStore
} from './chatStore.js';
import { resetChatRuntimeForTests } from './chatRuntime.js';

const NOW = '2026-07-10T12:00:00.000Z';

const thread = (id: string): ChatThreadSummary => ({
  id,
  title: `Thread ${id}`,
  preview: `Preview ${id}`,
  messageCount: 1,
  createdAt: NOW,
  updatedAt: NOW,
  lastMessageAt: NOW,
  backendID: 'codex'
});

const persisted = (
  id: string,
  threadID: string,
  role: PersistedChatMessage['role'],
  content: string
): PersistedChatMessage => ({ id, threadID, role, content, timestamp: NOW, backendID: 'codex' });

function bridgeWith(overrides: Partial<LinuxShellBridge>): LinuxShellBridge {
  const base = {
    chatThreadList: async () => ({ threads: [thread('A'), thread('B')] }),
    chatThreadGet: async (threadID: string) => ({
      thread: thread(threadID),
      messages: [persisted(`${threadID}-existing`, threadID, 'assistant', `Existing ${threadID}`)],
      hasMoreBefore: false
    }),
    chatMessageAppend: async (request: ChatMessageAppendRequest) => ({
      message: persisted(request.messageID, request.threadID, request.role, request.content),
      inserted: true
    }),
    configSnapshot: async () => null,
    gatewayProbe: async () => true,
    gatewayChatStream: async (_request: GatewayProxyRequest, onChunk: (chunk: string) => void) => {
      onChunk('data: {"choices":[{"delta":{"content":"Done"}}]}\n\n');
      onChunk('data: [DONE]\n\n');
    },
    gatewayChatCancel: async () => {}
  };
  return { ...base, ...overrides } as unknown as LinuxShellBridge;
}

function reset() {
  resetChatRuntimeForTests();
  useChatStore.setState({
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
    visibleThreadCount: 40,
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
    sharedFeaturesAvailable: true
  });
  useShellStore.setState({
    bridge: null,
    fixtureMode: false,
    bridgeReady: true,
    health: null
  });
}

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  window.localStorage.removeItem(CHAT_ACTIVE_THREAD_STORAGE_KEY);
  reset();
});

describe('exact-thread chat store', () => {
  it('resumes the last daemon-backed thread after a shell restart', async () => {
    window.localStorage.setItem(CHAT_ACTIVE_THREAD_STORAGE_KEY, 'B');
    const get = vi.fn(async (threadID: string) => ({
      thread: thread(threadID),
      messages: [persisted(`${threadID}-resumed`, threadID, 'assistant', 'Durable after restart')],
      hasMoreBefore: false
    }));
    useShellStore.setState({ bridge: bridgeWith({ chatThreadGet: get }), fixtureMode: false });

    await useChatStore.getState().load();

    expect(useChatStore.getState().selectedThreadId).toBe('B');
    expect(get).toHaveBeenCalledWith('B', 500);
    expect(useChatStore.getState().messages[0]).toMatchObject({
      id: 'B-resumed',
      threadID: 'B',
      text: 'Durable after restart'
    });
  });

  it('does not accept unsafe stored thread identifiers as a resume target', async () => {
    window.localStorage.setItem(CHAT_ACTIVE_THREAD_STORAGE_KEY, `${'x'.repeat(257)}`);
    const get = vi.fn(async (threadID: string) => ({
      thread: thread(threadID),
      messages: [],
      hasMoreBefore: false
    }));
    useShellStore.setState({ bridge: bridgeWith({ chatThreadGet: get }), fixtureMode: false });

    await useChatStore.getState().load();

    expect(useChatStore.getState().selectedThreadId).toBe('A');
    expect(get).toHaveBeenCalledWith('A', 500);
    // The unsafe hint is ignored; successful daemon selection replaces it
    // with the verified thread ID.
    expect(window.localStorage.getItem(CHAT_ACTIVE_THREAD_STORAGE_KEY)).toBe('A');
  });

  it('marks gateway tool calls as approval-unavailable without inventing a run identity', () => {
    const messages = applyChatStreamEvent([], 'assistant-1', {
      type: 'tool_call',
      toolCall: {
        id: 'gateway-call-1',
        name: 'workspace.read',
        arguments: '{"path":"README.md"}'
      }
    });

    expect(messages).toEqual([
      expect.objectContaining({
        id: 'gateway-call-1',
        role: 'tool',
        toolState: 'proposed',
        toolApproval: {
          state: 'unavailable',
          source: 'gateway',
          reason: 'gateway-tool-call-missing-run-approval-identity',
          fallbackRoute: 'missions'
        }
      })
    ]);
    expect(JSON.stringify(messages)).not.toContain('approvalID');
  });

  it('exposes only a daemon-issued approval identity as actionable', () => {
    const messages = applyChatStreamEvent([], 'assistant-1', {
      type: 'tool_call',
      toolCall: {
        id: 'daemon-tool-1',
        name: 'workspace.write',
        arguments: '{}',
        approvalID: 'approval-1'
      }
    });

    expect(messages[0]?.toolApproval).toEqual({
      state: 'pending',
      source: 'daemon-run',
      approvalID: 'approval-1'
    });
  });

  it('attaches live provider citation identities to the streamed assistant', () => {
    const messages = applyChatStreamEvent([{ id: 'assistant-1', role: 'assistant', text: '' }], 'assistant-1', {
      type: 'citations',
      citations: [{ id: 'citation-1', label: 'Earlier answer', messageId: 'message-1', threadID: 'thread-1', state: 'live' }]
    });
    expect(messages[0]?.memoryCitations).toEqual([
      { id: 'citation-1', label: 'Earlier answer', messageId: 'message-1', threadID: 'thread-1', state: 'live' }
    ]);
  });

  it('routes daemon-backed approval once when approve/reject clicks race', async () => {
    let release!: () => void;
    const response = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          release = resolve;
        })
    );
    useShellStore.setState({ bridge: bridgeWith({ toolApprovalRespond: response }), fixtureMode: false });
    useChatStore.setState({
      messages: [
        {
          id: 'tool-approval-race',
          role: 'tool',
          text: 'Write workspace file',
          toolName: 'workspace.write',
          toolState: 'proposed',
          toolApproval: { state: 'pending', source: 'daemon-run', approvalID: 'approval-race-1' }
        }
      ]
    });

    const approve = useChatStore.getState().respondToToolApproval('tool-approval-race', 'approve');
    const reject = useChatStore.getState().respondToToolApproval('tool-approval-race', 'reject');
    await Promise.resolve();
    expect(response).toHaveBeenCalledTimes(1);
    expect(response).toHaveBeenCalledWith('approval-race-1', 'approve');
    expect(useChatStore.getState().messages[0]?.toolApproval).toMatchObject({ state: 'submitting' });

    release();
    await Promise.all([approve, reject]);
    expect(useChatStore.getState().messages[0]?.toolApproval).toMatchObject({ state: 'approved' });
    expect(useChatStore.getState().messages[0]?.toolState).toBe('approved');
  });

  it('surfaces daemon errors and retries the same decision after a restart', async () => {
    const response = vi
      .fn()
      .mockRejectedValueOnce(new Error('daemon connection lost'))
      .mockResolvedValueOnce(undefined);
    useShellStore.setState({ bridge: bridgeWith({ toolApprovalRespond: response }), fixtureMode: false });
    useChatStore.setState({
      messages: [
        {
          id: 'tool-approval-retry',
          role: 'tool',
          text: 'Run command',
          toolName: 'workspace.exec',
          toolState: 'proposed',
          toolApproval: { state: 'pending', source: 'daemon-run', approvalID: 'approval-retry-1' }
        }
      ]
    });

    await useChatStore.getState().respondToToolApproval('tool-approval-retry', 'approve');
    expect(useChatStore.getState().messages[0]?.toolApproval).toMatchObject({
      state: 'error',
      lastDecision: 'approve',
      error: 'daemon connection lost'
    });

    // The bridge may be recreated after a daemon restart; retry uses the current bridge.
    const restartedResponse = vi.fn(async () => undefined);
    useShellStore.setState({ bridge: bridgeWith({ toolApprovalRespond: restartedResponse }), fixtureMode: false });
    await useChatStore.getState().retryToolApproval('tool-approval-retry');
    expect(restartedResponse).toHaveBeenCalledWith('approval-retry-1', 'approve');
    expect(useChatStore.getState().messages[0]?.toolApproval).toMatchObject({ state: 'approved' });
  });

  it('fails closed while offline instead of treating an approval as resolved', async () => {
    useShellStore.setState({ bridge: null, fixtureMode: false });
    useChatStore.setState({
      messages: [
        {
          id: 'tool-approval-offline',
          role: 'tool',
          text: 'Delete file',
          toolName: 'workspace.delete',
          toolState: 'proposed',
          toolApproval: { state: 'pending', source: 'daemon-run', approvalID: 'approval-offline-1' }
        }
      ]
    });

    await useChatStore.getState().respondToToolApproval('tool-approval-offline', 'cancel');
    expect(useChatStore.getState().messages[0]?.toolApproval).toMatchObject({
      state: 'error',
      lastDecision: 'cancel'
    });
    expect(useChatStore.getState().messages[0]?.toolState).toBe('error');
  });

  it('loads the exact selected thread instead of fabricating usage transcript rows', async () => {
    const get = vi.fn(async (threadID: string) => ({
      thread: thread(threadID),
      messages: [persisted('B-system', threadID, 'system', 'Pinned system context')],
      hasMoreBefore: false
    }));
    useShellStore.setState({ bridge: bridgeWith({ chatThreadGet: get }), fixtureMode: false });
    useChatStore.setState({ threads: [thread('A'), thread('B')] });

    await useChatStore.getState().selectThread('B');

    expect(get).toHaveBeenCalledWith('B', 500);
    expect(useChatStore.getState().selectedThreadId).toBe('B');
    expect(useChatStore.getState().messages).toEqual([
      expect.objectContaining({ id: 'B-system', role: 'system', text: 'Pinned system context', threadID: 'B' })
    ]);
  });

  it('merges an exact thread fetched outside the current list into the visible rail', async () => {
    const outside = { ...thread('outside'), title: 'Outside current filter' };
    const get = vi.fn(async () => ({
      thread: outside,
      messages: [persisted('outside-message', outside.id, 'assistant', 'Exact body')],
      hasMoreBefore: false
    }));
    useShellStore.setState({ bridge: bridgeWith({ chatThreadGet: get }), fixtureMode: false });
    useChatStore.setState({ threads: [thread('listed')], query: 'listed' });

    await useChatStore.getState().selectThread(outside.id);

    expect(useChatStore.getState().threads.map((candidate) => candidate.id)).toEqual([
      outside.id,
      'listed'
    ]);
    expect(useChatStore.getState().selectedThreadId).toBe(outside.id);
    expect(useChatStore.getState().historyError).toBeNull();
  });

  it('keeps the last good transcript visible when a live resume fails, then replaces it on retry', async () => {
    const get = vi
      .fn()
      .mockRejectedValueOnce(new Error('daemon connection lost'))
      .mockResolvedValueOnce({
        thread: thread('A'),
        messages: [persisted('A-resumed', 'A', 'assistant', 'Durable after reconnect')],
        hasMoreBefore: false
      });
    useShellStore.setState({ bridge: bridgeWith({ chatThreadGet: get }), fixtureMode: false });
    useChatStore.setState({
      threads: [thread('A')],
      selectedThreadId: 'A',
      messages: [{ id: 'A-visible', role: 'assistant', text: 'Still useful while offline', threadID: 'A' }],
      streamPhase: 'done'
    });

    await expect(useChatStore.getState().resumeThread()).resolves.toBe(false);
    expect(useChatStore.getState().messages).toEqual([
      expect.objectContaining({ id: 'A-visible', text: 'Still useful while offline' })
    ]);
    expect(useChatStore.getState().messagesLoading).toBe(false);
    expect(useChatStore.getState().historyError).toBe('daemon connection lost');
    expect(useChatStore.getState().selectedThreadId).toBe('A');

    await expect(useChatStore.getState().resumeThread()).resolves.toBe(true);
    expect(useChatStore.getState().messages).toEqual([
      expect.objectContaining({ id: 'A-resumed', text: 'Durable after reconnect', threadID: 'A' })
    ]);
    expect(useChatStore.getState().historyError).toBeNull();
    expect(get).toHaveBeenCalledTimes(2);
  });

  it('normalizes known thread provenance before selecting a gateway model', async () => {
    const anthropic = { ...thread('B'), backendID: 'anthropic' };
    const unknown = { ...thread('C'), backendID: 'untrusted-raw-model-id' };
    useShellStore.setState({
      bridge: bridgeWith({
        chatThreadGet: async (threadID) => ({
          thread: threadID === 'B' ? anthropic : unknown,
          messages: [],
          hasMoreBefore: false
        })
      }),
      fixtureMode: false
    });
    useChatStore.setState({ threads: [anthropic, unknown], backend: 'hermes', modelLabel: 'hermes' });

    await useChatStore.getState().selectThread('B');

    expect(useChatStore.getState().backend).toBe('claude');
    expect(useChatStore.getState().modelLabel).toBe('claude-sonnet-4');
    expect(useChatStore.getState().modelLabel).not.toBe('anthropic');

    useChatStore.setState({ backend: 'hermes', modelLabel: 'hermes' });
    await useChatStore.getState().selectThread('C');
    expect(useChatStore.getState().backend).toBe('hermes');
    expect(useChatStore.getState().modelLabel).toBe('hermes');
    expect(useChatStore.getState().modelLabel).not.toBe(unknown.backendID);
  });

  it('maps the macOS piAgent backend id onto the Pi Agent lane', async () => {
    // macOS threads persist ChatBackendID.piAgent.rawValue ("piAgent").
    const pi = { ...thread('B'), backendID: 'piAgent' };
    useShellStore.setState({
      bridge: bridgeWith({
        chatThreadGet: async () => ({ thread: pi, messages: [], hasMoreBefore: false })
      }),
      fixtureMode: false
    });
    useChatStore.setState({ threads: [pi], backend: 'hermes', modelLabel: 'hermes' });

    await useChatStore.getState().selectThread('B');

    expect(useChatStore.getState().backend).toBe('pi-agent');
    expect(useChatStore.getState().modelLabel).toBe('pi-agent');
  });

  it('passes the selected configured model variant through the native gateway request', async () => {
    const gatewayRequests: GatewayProxyRequest[] = [];
    const bridge = bridgeWith({
      configSnapshot: async () => ({
        paths: { supportDir: '/tmp', socketPath: '/tmp/sock', configDir: '/tmp/cfg', providerLogPaths: [] },
        secretServiceStatus: 'ready',
        telemetryEnabled: false,
        privacyOptIn: false,
        providers: [
          {
            providerID: 'openai',
            isEnabled: true,
            baseURL: 'https://api.openai.com/v1',
            preferredModelIDs: ['gpt-5'],
            disabledAdvertisedModelIDs: [],
            credentialSlots: [{ slotID: 'team', label: 'Team', isEnabled: true, status: 'ready' }],
            modelVariants: [
              { variantID: 'gpt-5-high', label: 'High', baseModelID: 'gpt-5', thinkingLevel: 'high' }
            ],
            modelAliases: [],
            modelDisplayOverrides: [],
            customModels: []
          }
        ]
      }),
      gatewayChatStream: async (request, onChunk) => {
        gatewayRequests.push(request);
        onChunk('data: {"choices":[{"delta":{"content":"Done"}}]}\n\n');
        onChunk('data: [DONE]\n\n');
      }
    });
    useShellStore.setState({
      bridge,
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    useChatStore.setState({
      threads: [thread('A')],
      selectedThreadId: 'A',
      messages: [],
      config: await bridge.configSnapshot(),
      catalog: [{
        id: 'openai',
        label: 'OpenAI',
        accountLabel: 'Team',
        quotaBuckets: [],
        capabilities: ['routing'],
        catalogAvailable: true
      }],
      backend: 'codex',
      modelLabel: 'gpt-5-high',
      modelOptionID: 'gpt-5',
      thinkingLevel: 'high'
    });

    await useChatStore.getState().sendMessage('Use high reasoning');

    expect(gatewayRequests[0]?.model).toBe('gpt-5-high');
  });

  it('fails closed when a stale backend selection is disabled by daemon config', async () => {
    const append = vi.fn();
    const gateway = vi.fn();
    useShellStore.setState({
      bridge: bridgeWith({ chatMessageAppend: append, gatewayChatStream: gateway }),
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    useChatStore.setState({
      config: {
        paths: { supportDir: '/tmp', socketPath: '/tmp/sock', configDir: '/tmp/cfg', providerLogPaths: [] },
        secretServiceStatus: 'ready',
        telemetryEnabled: false,
        privacyOptIn: false,
        providers: [{
          providerID: 'openai',
          isEnabled: false,
          baseURL: '',
          preferredModelIDs: ['gpt-5'],
          disabledAdvertisedModelIDs: [],
          credentialSlots: [{ slotID: 'team', label: 'Team', isEnabled: true, status: 'ready' }],
          modelVariants: [],
          modelAliases: [],
          modelDisplayOverrides: [],
          customModels: []
        }]
      },
      backend: 'codex',
      modelLabel: 'gpt-5',
      modelOptionID: 'gpt-5',
      selectedThreadId: 'A',
      messages: []
    });

    await useChatStore.getState().sendMessage('Do not send this');

    expect(append).not.toHaveBeenCalled();
    expect(gateway).not.toHaveBeenCalled();
    expect(useChatStore.getState().streamPhase).toBe('error');
    expect(useChatStore.getState().streamError).toBe(
      'Chat backend unavailable: The daemon provider is disabled in routing settings.'
    );
  });

  it('fails closed when daemon provider capability evidence is unavailable', async () => {
    const append = vi.fn();
    const gateway = vi.fn();
    useShellStore.setState({
      bridge: bridgeWith({ chatMessageAppend: append, gatewayChatStream: gateway }),
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    useChatStore.setState({
      config: {
        paths: { supportDir: '/tmp', socketPath: '/tmp/sock', configDir: '/tmp/cfg', providerLogPaths: [] },
        secretServiceStatus: 'ready',
        telemetryEnabled: false,
        privacyOptIn: false,
        providers: [{
          providerID: 'openai',
          isEnabled: true,
          baseURL: '',
          preferredModelIDs: ['gpt-5'],
          disabledAdvertisedModelIDs: [],
          credentialSlots: [{ slotID: 'team', label: 'Team', isEnabled: true, status: 'ready' }],
          modelVariants: [],
          modelAliases: [],
          modelDisplayOverrides: [],
          customModels: []
        }]
      },
      catalog: null,
      backend: 'codex',
      modelLabel: 'gpt-5',
      modelOptionID: 'gpt-5',
      selectedThreadId: 'A',
      messages: []
    });

    await useChatStore.getState().sendMessage('Do not send without catalog proof');

    expect(append).not.toHaveBeenCalled();
    expect(gateway).not.toHaveBeenCalled();
    expect(useChatStore.getState().streamPhase).toBe('error');
    expect(useChatStore.getState().streamError).toBe(
      'Chat backend unavailable: Daemon provider capability catalog has not been loaded.'
    );
  });

  it('keeps opaque attachment references on the current user turn and gateway request', async () => {
    const gatewayRequests: GatewayProxyRequest[] = [];
    const attachment = {
      attachmentId: 'attachment-1',
      fileName: 'notes.md',
      mimeType: 'text/markdown',
      byteSize: 5,
      sha256: 'a'.repeat(64)
    };
    const bridge = bridgeWith({
      gatewayChatStream: async (request, onChunk) => {
        gatewayRequests.push(request);
        onChunk('data: {"choices":[{"delta":{"content":"Done"}}]}\n\n');
        onChunk('data: [DONE]\n\n');
      }
    });
    useShellStore.setState({
      bridge,
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    useChatStore.setState({ threads: [thread('A')], selectedThreadId: 'A', messages: [] });

    await useChatStore.getState().sendMessage('Review this', [attachment]);

    expect(gatewayRequests[0]?.messages.at(-1)).toEqual({
      role: 'user',
      content: 'Review this',
      attachments: [{ attachmentId: 'attachment-1' }]
    });
    expect(useChatStore.getState().messages[0]?.attachments).toEqual([attachment]);

    await useChatStore.getState().sendMessage('Follow up');
    expect(gatewayRequests[1]?.messages).toEqual([
      { role: 'system', content: 'You are Hermes inside OpenBurnBar.' },
      { role: 'user', content: 'Review this' },
      { role: 'assistant', content: 'Done' },
      { role: 'user', content: 'Follow up' }
    ]);
  });

  it('loads older durable pages before the current oldest message', async () => {
    const oldest = persisted('newest-page-oldest', 'A', 'user', 'Current page');
    const older = persisted('older-message', 'A', 'assistant', 'Earlier durable reply');
    const chatThreadGet = vi.fn()
      .mockResolvedValueOnce({ thread: thread('A'), messages: [oldest], hasMoreBefore: true })
      .mockResolvedValueOnce({ thread: thread('A'), messages: [older], hasMoreBefore: false });
    useShellStore.setState({ bridge: bridgeWith({ chatThreadGet }), fixtureMode: false });
    useChatStore.setState({ threads: [thread('A')], hasMoreMessages: false });

    await useChatStore.getState().selectThread('A');
    expect(useChatStore.getState().hasMoreMessages).toBe(true);

    await useChatStore.getState().loadOlderMessages();

    expect(chatThreadGet).toHaveBeenNthCalledWith(2, 'A', 500, {
      timestamp: NOW,
      messageID: 'newest-page-oldest'
    });
    expect(useChatStore.getState().messages.map((message) => message.id)).toEqual([
      'older-message',
      'newest-page-oldest'
    ]);
    expect(useChatStore.getState().hasMoreMessages).toBe(false);
  });

  it('fails closed when a daemon page changes thread identity', async () => {
    const chatThreadGet = vi.fn(async () => ({
      thread: thread('other-thread'),
      messages: [],
      hasMoreBefore: false
    }));
    useShellStore.setState({ bridge: bridgeWith({ chatThreadGet }), fixtureMode: false });
    useChatStore.setState({ threads: [thread('A')] });

    await useChatStore.getState().selectThread('A');

    expect(chatThreadGet).toHaveBeenCalledWith('A', 500);
    expect(useChatStore.getState().messages).toEqual([]);
    expect(useChatStore.getState().historyError).toMatch(/does not match thread A/i);
    expect(useChatStore.getState().streamPhase).toBe('error');
  });

  it('walks all bounded unloaded pages without exposing a partial success', async () => {
    const current = persisted('page-current', 'A', 'assistant', 'Current page');
    const middle = persisted('page-middle', 'A', 'user', 'Middle page');
    const oldest = persisted('page-oldest', 'A', 'assistant', 'Oldest page');
    const chatThreadGet = vi.fn()
      .mockResolvedValueOnce({ thread: thread('A'), messages: [current], hasMoreBefore: true })
      .mockResolvedValueOnce({ thread: thread('A'), messages: [middle], hasMoreBefore: true })
      .mockResolvedValueOnce({ thread: thread('A'), messages: [oldest], hasMoreBefore: false });
    useShellStore.setState({ bridge: bridgeWith({ chatThreadGet }), fixtureMode: false });
    useChatStore.setState({ threads: [thread('A')] });

    await useChatStore.getState().selectThread('A');
    await expect(useChatStore.getState().loadAllMessages()).resolves.toBe(true);

    expect(chatThreadGet).toHaveBeenCalledTimes(3);
    expect(useChatStore.getState().messages.map((message) => message.id)).toEqual([
      'page-oldest',
      'page-middle',
      'page-current'
    ]);
    expect(useChatStore.getState().hasMoreMessages).toBe(false);
    expect(useChatStore.getState().loadingAllMessages).toBe(false);
    expect(useChatStore.getState().historyError).toBeNull();
  });

  it('loads an unloaded cited message through the same bounded cursor path', async () => {
    const current = persisted('citation-current', 'A', 'assistant', 'Current page');
    const cited = persisted('citation-source', 'A', 'user', 'Cited source');
    const chatThreadGet = vi.fn()
      .mockResolvedValueOnce({ thread: thread('A'), messages: [current], hasMoreBefore: true })
      .mockResolvedValueOnce({ thread: thread('A'), messages: [cited], hasMoreBefore: false });
    useShellStore.setState({ bridge: bridgeWith({ chatThreadGet }), fixtureMode: false });
    useChatStore.setState({ threads: [thread('A')] });

    await useChatStore.getState().selectThread('A');
    await expect(useChatStore.getState().loadUntilMessage('citation-source')).resolves.toBe(true);

    expect(chatThreadGet).toHaveBeenNthCalledWith(2, 'A', 500, {
      timestamp: NOW,
      messageID: 'citation-current'
    });
    expect(useChatStore.getState().messages.some((message) => message.id === 'citation-source')).toBe(true);
    expect(useChatStore.getState().loadingAllMessages).toBe(false);
  });

  it('rolls back the user turn when its durable append rejects', async () => {
    const bridge = bridgeWith({
      chatMessageAppend: async () => {
        throw new Error('disk full');
      }
    });
    useShellStore.setState({
      bridge,
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    useChatStore.setState({ threads: [thread('A')], selectedThreadId: 'A', messages: [] });

    await useChatStore.getState().sendMessage('Never durable');

    expect(useChatStore.getState().streamPhase).toBe('error');
    expect(useChatStore.getState().messages).toEqual([]);
  });

  it('rolls back streamed assistant text when its terminal append rejects', async () => {
    const bridge = bridgeWith({
      chatMessageAppend: async (request) => {
        if (request.role === 'assistant') throw new Error('append rejected');
        return {
          message: persisted(request.messageID, request.threadID, request.role, request.content),
          inserted: true
        };
      }
    });
    useShellStore.setState({
      bridge,
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    useChatStore.setState({ threads: [thread('A')], selectedThreadId: 'A', messages: [] });

    await useChatStore.getState().sendMessage('Ask something');

    const state = useChatStore.getState();
    expect(state.streamPhase).toBe('error');
    // The durable user turn survives; the non-durable assistant text must not
    // linger where the next send would replay it as prior context.
    expect(state.messages.map((message) => [message.role, message.text])).toEqual([
      ['user', 'Ask something']
    ]);
  });

  it('fails closed before persistence when secure UUID generation is unavailable', async () => {
    const append = vi.fn();
    const gateway = vi.fn();
    vi.stubGlobal('crypto', undefined);
    useShellStore.setState({
      bridge: bridgeWith({ chatMessageAppend: append, gatewayChatStream: gateway }),
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    useChatStore.setState({ threads: [thread('A')], selectedThreadId: 'A', messages: [] });

    await useChatStore.getState().sendMessage('Needs a durable identity');

    expect(append).not.toHaveBeenCalled();
    expect(gateway).not.toHaveBeenCalled();
    expect(useChatStore.getState().streamPhase).toBe('error');
    expect(useChatStore.getState().streamError).toBe('Secure message identity generation is unavailable.');
  });

  it('persists user before streaming and terminal assistant after success on the target thread', async () => {
    const order: string[] = [];
    const appended: ChatMessageAppendRequest[] = [];
    const gatewayRequests: GatewayProxyRequest[] = [];
    const bridge = bridgeWith({
      chatThreadGet: async (threadID) => {
        order.push(`get:${threadID}`);
        return {
          thread: thread(threadID),
          messages: [persisted('B-existing', threadID, 'assistant', 'Existing B')],
          hasMoreBefore: false
        };
      },
      chatMessageAppend: async (request) => {
        order.push(`append:${request.role}`);
        appended.push(request);
        return {
          message: persisted(request.messageID, request.threadID, request.role, request.content),
          inserted: true
        };
      },
      chatThreadList: async () => {
        order.push('list');
        return { threads: [thread('A'), thread('B')] };
      },
      gatewayChatStream: async (request, onChunk) => {
        order.push('gateway');
        gatewayRequests.push(request);
        onChunk('data: {"choices":[{"delta":{"content":"Finished B"}}]}\n\n');
        onChunk('data: [DONE]\n\n');
      }
    });
    useShellStore.setState({
      bridge,
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    useChatStore.setState({
      threads: [thread('A'), thread('B')],
      selectedThreadId: 'A',
      messages: [{ id: 'A-existing', role: 'assistant', text: 'Existing A', threadID: 'A' }]
    });

    await useChatStore.getState().sendToThread({ threadID: 'B', backend: 'codex', text: 'Continue B' });

    expect(order.indexOf('append:user')).toBeLessThan(order.indexOf('gateway'));
    expect(order.indexOf('gateway')).toBeLessThan(order.indexOf('append:assistant'));
    expect(appended.map((request) => [request.threadID, request.role, request.content])).toEqual([
      ['B', 'user', 'Continue B'],
      ['B', 'assistant', 'Finished B']
    ]);
    expect(gatewayRequests[0]!.messages).toEqual(expect.arrayContaining([
      { role: 'assistant', content: 'Existing B' },
      { role: 'user', content: 'Continue B' }
    ]));
    expect(JSON.stringify(gatewayRequests[0]!.messages)).not.toContain('Existing A');
    expect(useChatStore.getState().selectedThreadId).toBe('B');
    expect(useChatStore.getState().streamPhase).toBe('done');
  });

  it('persists no assistant when the gateway errors', async () => {
    const appended: ChatMessageAppendRequest[] = [];
    const bridge = bridgeWith({
      chatMessageAppend: async (request) => {
        appended.push(request);
        return {
          message: persisted(request.messageID, request.threadID, request.role, request.content),
          inserted: true
        };
      },
      gatewayChatStream: async () => {
        throw new Error('gateway_http:500:failed');
      }
    });
    useShellStore.setState({
      bridge,
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    useChatStore.setState({ threads: [thread('A')], selectedThreadId: 'A', messages: [] });

    await useChatStore.getState().sendMessage('Will fail');

    expect(appended.map((request) => request.role)).toEqual(['user']);
    expect(useChatStore.getState().streamPhase).toBe('error');
  });

  it('persists no assistant when the stream is aborted', async () => {
    const appended: ChatMessageAppendRequest[] = [];
    let releaseGateway: (() => void) | undefined;
    const bridge = bridgeWith({
      chatMessageAppend: async (request) => {
        appended.push(request);
        return {
          message: persisted(request.messageID, request.threadID, request.role, request.content),
          inserted: true
        };
      },
      gatewayChatStream: async () => new Promise<void>((resolve) => {
        releaseGateway = resolve;
      })
    });
    useShellStore.setState({
      bridge,
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    useChatStore.setState({ threads: [thread('A')], selectedThreadId: 'A', messages: [] });

    const sending = useChatStore.getState().sendMessage('Stop this');
    await vi.waitFor(() => expect(useChatStore.getState().streamPhase).toBe('streaming'));
    useChatStore.getState().stopStreaming();
    releaseGateway?.();
    await sending;

    expect(appended.map((request) => request.role)).toEqual(['user']);
    expect(useChatStore.getState().streamPhase).toBe('aborted');
  });

  it('logs only a fixed event name when ancillary summary refresh fails', async () => {
    const appended: ChatMessageAppendRequest[] = [];
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
    const bridge = bridgeWith({
      chatThreadList: async () => {
        throw new Error('credential=do-not-log');
      },
      chatMessageAppend: async (request) => {
        appended.push(request);
        return {
          message: persisted(request.messageID, request.threadID, request.role, request.content),
          inserted: true
        };
      }
    });
    useShellStore.setState({
      bridge,
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    useChatStore.setState({ threads: [thread('A')], selectedThreadId: 'A', messages: [] });

    await useChatStore.getState().sendMessage('Continue despite refresh failure');

    expect(appended.map((request) => request.role)).toEqual(['user', 'assistant']);
    expect(consoleError).toHaveBeenCalledTimes(2);
    for (const call of consoleError.mock.calls) {
      expect(call).toEqual(['linux_chat_thread_refresh_failed']);
      expect(JSON.stringify(call)).not.toContain('do-not-log');
    }
  });

  it('keeps synthetic transcript generation fixture-only', async () => {
    useShellStore.setState({ bridge: null, fixtureMode: true });
    await useChatStore.getState().load();
    const selected = useChatStore.getState().selectedThreadId;

    expect(selected).toMatch(/^fx-session-/);
    expect(useChatStore.getState().messages.some((message) => message.role === 'thinking')).toBe(true);
    await useChatStore.getState().sendMessage('Fixture only');
    expect(useChatStore.getState().selectedThreadId).toBe(selected);
    expect(useChatStore.getState().streamPhase).toBe('done');
  });

  it('keeps simultaneous streams for different threads isolated by controller', async () => {
    const streams = new Map<string, {
      onChunk: (chunk: string) => void;
      resolve: () => void;
    }>();
    const bridge = bridgeWith({
      gatewayChatStream: async (request, onChunk) => new Promise<void>((resolve) => {
        const prompt = request.messages.at(-1)?.content ?? '';
        streams.set(prompt, { onChunk, resolve });
      })
    });
    useShellStore.setState({
      bridge,
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    const paneA = createChatController({ activeThreadStorageKey: null, controllerID: 'pane-A' });
    const paneB = createChatController({ activeThreadStorageKey: null, controllerID: 'pane-B' });
    paneA.setState({ threads: [thread('A'), thread('B')], selectedThreadId: 'A', backend: 'codex' });
    paneB.setState({ threads: [thread('A'), thread('B')], selectedThreadId: 'B', backend: 'codex' });

    const sendingA = paneA.getState().sendMessage('Prompt A');
    const sendingB = paneB.getState().sendMessage('Prompt B');
    await vi.waitFor(() => expect(streams.size).toBe(2));

    streams.get('Prompt A')!.onChunk('data: {"choices":[{"delta":{"content":"Answer A"}}]}\n\n');
    streams.get('Prompt B')!.onChunk('data: {"choices":[{"delta":{"content":"Answer B"}}]}\n\n');
    await vi.waitFor(() => {
      expect(paneA.getState().messages.some((message) => message.text === 'Answer A')).toBe(true);
      expect(paneB.getState().messages.some((message) => message.text === 'Answer B')).toBe(true);
    });
    expect(JSON.stringify(paneA.getState().messages)).not.toContain('Answer B');
    expect(JSON.stringify(paneB.getState().messages)).not.toContain('Answer A');

    for (const stream of streams.values()) {
      stream.onChunk('data: [DONE]\n\n');
      stream.resolve();
    }
    await Promise.all([sendingA, sendingB]);

    expect(paneA.getState().streamPhase).toBe('done');
    expect(paneB.getState().streamPhase).toBe('done');
    paneA.getState().dispose();
    paneB.getState().dispose();
  });

  it('stops only the requested pane while another pane finishes', async () => {
    const streams = new Map<string, {
      onChunk: (chunk: string) => void;
      resolve: () => void;
    }>();
    const cancel = vi.fn(async () => undefined);
    useShellStore.setState({
      bridge: bridgeWith({
        gatewayChatCancel: cancel,
        gatewayChatStream: async (request, onChunk) => new Promise<void>((resolve) => {
          streams.set(request.messages.at(-1)?.content ?? '', { onChunk, resolve });
        })
      }),
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    const paneA = createChatController({ activeThreadStorageKey: null, controllerID: 'stop-pane-A' });
    const paneB = createChatController({ activeThreadStorageKey: null, controllerID: 'stop-pane-B' });
    paneA.setState({ threads: [thread('A'), thread('B')], selectedThreadId: 'A', backend: 'codex' });
    paneB.setState({ threads: [thread('A'), thread('B')], selectedThreadId: 'B', backend: 'codex' });

    const sendingA = paneA.getState().sendMessage('Stop A');
    const sendingB = paneB.getState().sendMessage('Finish B');
    await vi.waitFor(() => expect(streams.size).toBe(2));

    paneA.getState().stopStreaming();
    streams.get('Stop A')!.resolve();
    streams.get('Finish B')!.onChunk('data: {"choices":[{"delta":{"content":"B completed"}}]}\n\n');
    streams.get('Finish B')!.onChunk('data: [DONE]\n\n');
    streams.get('Finish B')!.resolve();
    await Promise.all([sendingA, sendingB]);

    expect(paneA.getState().streamPhase).toBe('aborted');
    expect(paneB.getState().streamPhase).toBe('done');
    expect(paneB.getState().messages.some((message) => message.text === 'B completed')).toBe(true);
    expect(cancel).toHaveBeenCalledTimes(1);
    paneA.getState().dispose();
    paneB.getState().dispose();
  });

  it('blocks a second pane from sending to the same thread before any durable append or gateway call', async () => {
    let resolveGateway!: () => void;
    const append = vi.fn(async (request: ChatMessageAppendRequest) => ({
      message: persisted(request.messageID, request.threadID, request.role, request.content),
      inserted: true
    }));
    const gateway = vi.fn(async () => new Promise<void>((resolve) => {
      resolveGateway = resolve;
    }));
    useShellStore.setState({
      bridge: bridgeWith({ chatMessageAppend: append, gatewayChatStream: gateway }),
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    const paneA = createChatController({ activeThreadStorageKey: null, controllerID: 'lease-pane-A' });
    const paneB = createChatController({ activeThreadStorageKey: null, controllerID: 'lease-pane-B' });
    paneA.setState({ threads: [thread('A')], selectedThreadId: 'A', backend: 'codex' });
    paneB.setState({ threads: [thread('A')], selectedThreadId: 'A', backend: 'codex' });

    const sendingA = paneA.getState().sendMessage('First writer');
    await vi.waitFor(() => expect(paneA.getState().streamPhase).toBe('streaming'));
    await paneB.getState().sendMessage('Blocked writer');

    expect(paneB.getState().streamPhase).toBe('error');
    expect(paneB.getState().streamError).toBe('This conversation is generating in another pane.');
    expect(append).toHaveBeenCalledTimes(1);
    expect(gateway).toHaveBeenCalledTimes(1);

    paneA.getState().stopStreaming();
    resolveGateway();
    await sendingA;
    paneA.getState().dispose();
    paneB.getState().dispose();
  });

  it('does not let an isolated pane mutate the legacy active-thread storage key', async () => {
    window.localStorage.setItem(CHAT_ACTIVE_THREAD_STORAGE_KEY, 'legacy-thread');
    useShellStore.setState({ bridge: bridgeWith({}), fixtureMode: false });
    const pane = createChatController({ activeThreadStorageKey: null, controllerID: 'storage-isolated-pane' });
    pane.setState({ threads: [thread('A'), thread('B')] });

    await pane.getState().selectThread('B');
    expect(pane.getState().selectedThreadId).toBe('B');
    expect(window.localStorage.getItem(CHAT_ACTIVE_THREAD_STORAGE_KEY)).toBe('legacy-thread');

    pane.getState().startNewChat();
    expect(window.localStorage.getItem(CHAT_ACTIVE_THREAD_STORAGE_KEY)).toBe('legacy-thread');
    pane.getState().dispose();
  });

  it('ignores an older search result that resolves after a newer query', async () => {
    const pending = new Map<string, (value: { threads: ChatThreadSummary[] }) => void>();
    useShellStore.setState({
      bridge: bridgeWith({
        chatThreadList: async (query) => new Promise((resolve) => {
          pending.set(query ?? '', resolve);
        })
      }),
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    const pane = createChatController({ activeThreadStorageKey: null, controllerID: 'search-pane' });

    const older = pane.getState().search('older');
    const newer = pane.getState().search('newer');
    await vi.waitFor(() => expect(pending.size).toBe(2));
    pending.get('newer')!({ threads: [thread('new-result')] });
    await newer;
    pending.get('older')!({ threads: [thread('old-result')] });
    await older;

    expect(pane.getState().query).toBe('newer');
    expect(pane.getState().threads.map((candidate) => candidate.id)).toEqual(['new-result']);
    expect(pane.getState().selectedThreadId).toBe('new-result');
    pane.getState().dispose();
  });

  it('ignores a stale response when the same thread is selected twice', async () => {
    const pending: Array<(value: {
      thread: ChatThreadSummary;
      messages: PersistedChatMessage[];
      hasMoreBefore: boolean;
    }) => void> = [];
    useShellStore.setState({
      bridge: bridgeWith({
        chatThreadGet: async () => new Promise((resolve) => {
          pending.push(resolve);
        })
      }),
      fixtureMode: false
    });
    const pane = createChatController({ activeThreadStorageKey: null, controllerID: 'selection-pane' });
    pane.setState({ threads: [thread('A')] });

    const older = pane.getState().selectThread('A');
    const newer = pane.getState().selectThread('A');
    await vi.waitFor(() => expect(pending).toHaveLength(2));
    pending[1]!({
      thread: thread('A'),
      messages: [persisted('new-message', 'A', 'assistant', 'Newest response')],
      hasMoreBefore: false
    });
    await newer;
    pending[0]!({
      thread: thread('A'),
      messages: [persisted('old-message', 'A', 'assistant', 'Stale response')],
      hasMoreBefore: false
    });
    await older;

    expect(pane.getState().messages).toEqual([
      expect.objectContaining({ id: 'new-message', text: 'Newest response' })
    ]);
    pane.getState().dispose();
  });

  it('aborts on dispose and ignores chunks delivered after the pane is closed', async () => {
    let onChunk!: (chunk: string) => void;
    let resolveGateway!: () => void;
    const cancel = vi.fn(async () => undefined);
    useShellStore.setState({
      bridge: bridgeWith({
        gatewayChatCancel: cancel,
        gatewayChatStream: async (_request, callback) => new Promise<void>((resolve) => {
          onChunk = callback;
          resolveGateway = resolve;
        })
      }),
      fixtureMode: false,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    const pane = createChatController({ activeThreadStorageKey: null, controllerID: 'disposed-pane' });
    pane.setState({ threads: [thread('A')], selectedThreadId: 'A', backend: 'codex' });

    const sending = pane.getState().sendMessage('Close this pane');
    await vi.waitFor(() => expect(pane.getState().streamPhase).toBe('streaming'));
    pane.getState().dispose();
    onChunk('data: {"choices":[{"delta":{"content":"Late chunk"}}]}\n\n');
    onChunk('data: [DONE]\n\n');
    resolveGateway();
    await sending;

    expect(pane.getState().disposed).toBe(true);
    expect(pane.getState().streamPhase).toBe('aborted');
    expect(JSON.stringify(pane.getState().messages)).not.toContain('Late chunk');
    expect(cancel).toHaveBeenCalledTimes(1);
  });
});
