import { afterEach, describe, expect, it, vi } from 'vitest';
import type {
  ChatMessageAppendRequest,
  ChatThreadSummary,
  GatewayProxyRequest,
  LinuxShellBridge,
  PersistedChatMessage
} from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';
import { applyChatStreamEvent, useChatStore } from './chatStore.js';

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
  useChatStore.setState({
    threads: [],
    nextCursor: null,
    selectedThreadId: null,
    messages: [],
    messagesLoading: false,
    loadingOlderMessages: false,
    hasMoreMessages: false,
    config: null,
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
  reset();
});

describe('exact-thread chat store', () => {
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
            credentialSlots: [],
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
      backend: 'codex',
      modelLabel: 'gpt-5-high',
      modelOptionID: 'gpt-5',
      thinkingLevel: 'high'
    });

    await useChatStore.getState().sendMessage('Use high reasoning');

    expect(gatewayRequests[0]?.model).toBe('gpt-5-high');
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
});
