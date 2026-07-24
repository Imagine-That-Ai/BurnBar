// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { fixtureSessionList } from '../../daemonFixture.js';
import { bridgeStubDefaults } from '../../testing/bridgeStubs.js';
import type {
  ChatThreadGetResult,
  ChatThreadListResult,
  ChatMessageCursor,
  GatewayProxyRequest,
  LinuxShellBridge,
  SessionListResult
} from '../../tauriBridge.js';
import { useChatStore } from '../../state/chatStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { availableRuntimeCapabilities } from '../../testing/bridgeStubs.js';
import { ChatSurface } from './ChatSurface.js';

function mockBridge(handlers: {
  chatThreadList?: (query?: string, limit?: number) => Promise<ChatThreadListResult>;
  chatThreadGet?: (threadID: string, maxMessages?: number, before?: ChatMessageCursor) => Promise<ChatThreadGetResult>;
  chatAttachmentUpload?: LinuxShellBridge['chatAttachmentUpload'];
  gatewayAttachmentCapability?: LinuxShellBridge['gatewayAttachmentCapability'];
  gatewayProbe?: () => Promise<boolean>;
  gatewayChatStream?: (request: GatewayProxyRequest, onChunk: (chunk: string) => void) => Promise<void>;
}): LinuxShellBridge {
  const emptyList = async (): Promise<SessionListResult> => ({ sessions: [], nextCursor: null });
  const bridge: LinuxShellBridge = {
    ...bridgeStubDefaults,
    daemonHealth: async () => ({ ok: true }),
    runtimeCapabilities: availableRuntimeCapabilities,
    openDashboard: async () => {},
    quitApp: async () => {},
    trayDegraded: async () => false,
    measurePerfOperation: async (name) => ({ name, ok: true, ms: 1, source: 'test' }),
    usageSummary: async () => ({
      todayTokens: 0,
      todayCostUsd: 0,
      sevenDay: [0, 0, 0, 0, 0, 0, 0],
      recentEvents: []
    }),
    providerCatalog: async () => [{
      id: 'hermes',
      label: 'Hermes',
      accountLabel: 'Test',
      quotaBuckets: [],
      capabilities: ['routing'],
      catalogAvailable: true
    }],
    sessionList: emptyList,
    sessionSearch: emptyList,
    chatThreadList: handlers.chatThreadList ?? (async () => ({ threads: [] })),
    chatThreadGet: handlers.chatThreadGet ?? (async (threadID) => ({
      thread: {
        id: threadID,
        title: `Thread ${threadID}`,
        preview: 'Persisted transcript',
        messageCount: 1,
        createdAt: '2026-07-10T12:00:00Z',
        updatedAt: '2026-07-10T12:00:00Z'
      },
      messages: [{
        id: `${threadID}-message`,
        threadID,
        role: 'assistant',
        content: `Persisted message for ${threadID}`,
        timestamp: '2026-07-10T12:00:00Z'
      }],
      hasMoreBefore: false
    })),
    chatMessageAppend: bridgeStubDefaults.chatMessageAppend,
    chatAttachmentUpload: handlers.chatAttachmentUpload ?? bridgeStubDefaults.chatAttachmentUpload,
    gatewayAttachmentCapability: handlers.gatewayAttachmentCapability,
    usageInsights: async () => ({ weekly: [], providerMix: [], modelMix: [], cacheHitRatePct: 0 }),
    missionList: async () => ({ missions: [], pendingApprovals: [] }),
    missionApprovalDecision: async () => {},
    missionCreate: async () => null,
    configSnapshot: async () => ({
      paths: {
        supportDir: '/tmp',
        socketPath: '/tmp/sock',
        configDir: '/tmp/cfg',
        providerLogPaths: []
      },
      secretServiceStatus: 'unavailable',
      telemetryEnabled: false,
      privacyOptIn: false,
      providers: [{
        providerID: 'hermes',
        isEnabled: true,
        baseURL: '',
        preferredModelIDs: ['hermes'],
        disabledAdvertisedModelIDs: [],
        credentialSlots: [{ slotID: 'test', label: 'Test', isEnabled: true, status: 'ready' }],
        modelVariants: [],
        modelAliases: [],
        modelDisplayOverrides: [],
        customModels: []
      }]
    }),
    dbStatus: async () => ({ sqlcipherOk: true, migrationVersion: 0, sizeBytes: 0, walMode: true }),
    projectList: async () => [],
    memoryBoundaries: async () => [],
    memoryReviewInbox: async () => ({ items: [], auditEvents: [] }),
    memoryReviewDecision: async () => {},
    databaseWorkspaceStatus: async () => ({
      sourceLabel: 'test',
      projectID: 'test',
      artifactCount: 0,
      chunkCount: 0,
      symbolCount: 0,
      referenceCount: 0,
      callEdgeCount: 0,
      rejectedCount: 0,
      storageByteCount: 0,
      storageBudgetBytes: 0,
      storageWithinBudget: true,
      productionReady: false,
      productionReadinessReasons: [],
      parserAvailable: false,
      databaseEncrypted: false,
      hostedCodeToolsEnabled: false,
      semanticAvailable: false,
      files: [],
      languages: [],
      diagnostics: [],
      degradedReasons: []
    }),
    databaseIndexProject: async () => ({ projectID: 'test', projectRoot: '/tmp', indexedFiles: 0 }),
    databaseWatchProject: async () => ({ projectID: 'test', projectRoot: '/tmp', indexedFiles: 0 }),
    accountStatus: async () => ({ signedIn: false, trustClass: 'linux-lower-trust', syncState: 'local-only' }),
    appVersionInfo: async () => ({
      shellVersion: '0',
      daemonVersion: '0',
      packageChannel: 'unknown',
      updateCheck: 'skipped'
    }),
    exportDiagnostics: async () => ({ path: '/tmp/diag.zip' }),
    sessionEnv: async () => ({}),
    gatewayProbe: handlers.gatewayProbe ?? (async () => false),
    gatewayChatStream: handlers.gatewayChatStream ?? (async () => undefined),
    gatewayChatCancel: async () => undefined,
    mediaStatus: async () => ({ capabilityAvailable: false, pairedDevices: [] }),
    integrationsStatus: async () => ({ integrations: [] })
  };
  return bridge;
}

function chatThreadsFromSessions(result: SessionListResult): ChatThreadListResult {
  return {
    threads: result.sessions.map((session) => ({
      id: session.id,
      title: session.title,
      preview: `${session.provider} / ${session.model}`,
      messageCount: 1,
      createdAt: session.startedAt,
      updatedAt: session.startedAt,
      lastMessageAt: session.startedAt,
      backendID: session.provider
    }))
  };
}

const resetChatStore = () => {
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
};

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  resetChatStore();
  useShellStore.setState({ bridge: null, bridgeReady: true, fixtureMode: false, health: null });
});

describe('ChatSurface', () => {
  it('shows offline notice without bridge', async () => {
    useShellStore.setState({ bridge: null, fixtureMode: false, bridgeReady: true });
    render(<ChatSurface />);
    expect(screen.getByText(/packaged shell/i)).toBeTruthy();
  });

  it('shows empty state when no threads', async () => {
    useShellStore.setState({
      bridge: mockBridge({ chatThreadList: async () => ({ threads: [] }) }),
      fixtureMode: false,
      bridgeReady: true
    });
    render(<ChatSurface />);
    await waitFor(() => {
      expect(screen.getByText(/No conversations yet/i)).toBeTruthy();
    });
  });

  it('renders persisted thread summaries and messages', async () => {
    const list = fixtureSessionList();
    useShellStore.setState({
      bridge: mockBridge({ chatThreadList: async () => chatThreadsFromSessions(list) }),
      fixtureMode: false,
      bridgeReady: true
    });
    render(<ChatSurface />);
    await waitFor(() => {
      expect(screen.getByRole('log')).toBeTruthy();
    });
    expect(screen.getAllByText(list.sessions[0].title).length).toBeGreaterThan(0);
  });

  it('exports the loaded transcript as Markdown through the toolbar', async () => {
    const summary = {
      id: 'thread-export-ui',
      title: 'Exportable thread',
      preview: 'A durable transcript',
      messageCount: 2,
      createdAt: '2026-07-10T12:00:00Z',
      updatedAt: '2026-07-10T12:04:00Z'
    };
    useShellStore.setState({
      bridge: mockBridge({
        chatThreadList: async () => ({ threads: [summary] }),
        chatThreadGet: async () => ({
          thread: summary,
          messages: [
            {
              id: 'export-user',
              threadID: summary.id,
              role: 'user',
              content: 'Please export this.',
              timestamp: '2026-07-10T12:00:00Z'
            },
            {
              id: 'export-assistant',
              threadID: summary.id,
              role: 'assistant',
              content: 'Here is the durable answer.',
              timestamp: '2026-07-10T12:04:00Z'
            }
          ],
          hasMoreBefore: false
        })
      }),
      fixtureMode: false,
      bridgeReady: true
    });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('log')).toBeTruthy());

    expect((screen.getByRole('button', { name: 'Export chat as JSON' }) as HTMLButtonElement).disabled).toBe(false);
    fireEvent.change(screen.getByRole('combobox', { name: 'Chat export format' }), {
      target: { value: 'markdown' }
    });
    const exportButton = screen.getByRole('button', { name: 'Export chat as Markdown' });
    expect((exportButton as HTMLButtonElement).disabled).toBe(false);

    const url = globalThis.URL;
    const originalCreateObjectURL = url.createObjectURL;
    const originalRevokeObjectURL = url.revokeObjectURL;
    const createObjectURL = vi.fn(() => 'blob:chat-export');
    const revokeObjectURL = vi.fn();
    Object.defineProperty(url, 'createObjectURL', {
      configurable: true,
      writable: true,
      value: createObjectURL
    });
    Object.defineProperty(url, 'revokeObjectURL', {
      configurable: true,
      writable: true,
      value: revokeObjectURL
    });
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => undefined);
    try {
      fireEvent.click(exportButton);
      await waitFor(() => {
        expect(screen.getByRole('status').textContent).toContain(
          'Exported openburnbar-chat-Exportable-thread.md'
        );
      });
      expect(createObjectURL).toHaveBeenCalledOnce();
      expect(click).toHaveBeenCalled();
    } finally {
      if (originalCreateObjectURL) {
        Object.defineProperty(url, 'createObjectURL', {
          configurable: true,
          writable: true,
          value: originalCreateObjectURL
        });
      } else {
        delete (url as { createObjectURL?: unknown }).createObjectURL;
      }
      if (originalRevokeObjectURL) {
        Object.defineProperty(url, 'revokeObjectURL', {
          configurable: true,
          writable: true,
          value: originalRevokeObjectURL
        });
      } else {
        delete (url as { revokeObjectURL?: unknown }).revokeObjectURL;
      }
    }
  });

  it('exports unloaded older transcript pages from the daemon', async () => {
    const summary = {
      id: 'thread-export-paged-ui',
      title: 'Paged export thread',
      preview: 'A long durable transcript',
      messageCount: 3,
      createdAt: '2026-07-10T12:00:00Z',
      updatedAt: '2026-07-10T12:04:00Z'
    };
    const calls: Array<ChatMessageCursor | undefined> = [];
    const chatThreadGet = vi.fn(async (_threadID: string, _maxMessages = 500, before?: ChatMessageCursor) => {
      calls.push(before);
      if (!before) {
        return {
          thread: summary,
          messages: [
            {
              id: 'page-new',
              threadID: summary.id,
              role: 'assistant' as const,
              content: 'Newest page',
              timestamp: '2026-07-10T12:04:00Z'
            }
          ],
          hasMoreBefore: true
        };
      }
      return {
        thread: summary,
        messages: [
          {
            id: 'page-old',
            threadID: summary.id,
            role: 'user' as const,
            content: 'Older page',
            timestamp: '2026-07-10T12:00:00Z'
          }
        ],
        hasMoreBefore: false
      };
    });
    useShellStore.setState({
      bridge: mockBridge({ chatThreadList: async () => ({ threads: [summary] }), chatThreadGet }),
      fixtureMode: false,
      bridgeReady: true
    });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('log')).toBeTruthy());

    const url = globalThis.URL;
    const originalCreateObjectURL = url.createObjectURL;
    const originalRevokeObjectURL = url.revokeObjectURL;
    const createObjectURL = vi.fn(() => 'blob:chat-export-paged');
    const revokeObjectURL = vi.fn();
    Object.defineProperty(url, 'createObjectURL', { configurable: true, writable: true, value: createObjectURL });
    Object.defineProperty(url, 'revokeObjectURL', { configurable: true, writable: true, value: revokeObjectURL });
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => undefined);
    try {
      fireEvent.click(screen.getByRole('button', { name: 'Export chat as JSON' }));
      await waitFor(() => expect(screen.getByRole('status').textContent).toMatch(/Exported openburnbar-chat-Paged-export-thread\.json/));
      expect(chatThreadGet).toHaveBeenCalledTimes(3); // initial selection plus complete export pages
      expect(calls).toEqual([undefined, undefined, {
        timestamp: '2026-07-10T12:04:00Z',
        messageID: 'page-new'
      }]);
      expect(createObjectURL).toHaveBeenCalledOnce();
      expect(click).toHaveBeenCalled();
    } finally {
      if (originalCreateObjectURL) {
        Object.defineProperty(url, 'createObjectURL', { configurable: true, writable: true, value: originalCreateObjectURL });
      } else {
        delete (url as { createObjectURL?: unknown }).createObjectURL;
      }
      if (originalRevokeObjectURL) {
        Object.defineProperty(url, 'revokeObjectURL', { configurable: true, writable: true, value: originalRevokeObjectURL });
      } else {
        delete (url as { revokeObjectURL?: unknown }).revokeObjectURL;
      }
    }
  });

  it('offers bounded loading of unloaded transcript pages in the message stream', async () => {
    const summary = {
      id: 'thread-load-all-ui',
      title: 'Long transcript',
      preview: 'A transcript with unloaded pages',
      messageCount: 2,
      createdAt: '2026-07-10T12:00:00Z',
      updatedAt: '2026-07-10T12:04:00Z'
    };
    const chatThreadGet = vi.fn(async (_threadID: string, _maxMessages = 500, before?: ChatMessageCursor) => {
      if (!before) {
        return {
          thread: summary,
          messages: [{
            id: 'load-all-new',
            threadID: summary.id,
            role: 'assistant' as const,
            content: 'Newest page',
            timestamp: '2026-07-10T12:04:00Z'
          }],
          hasMoreBefore: true
        };
      }
      return {
        thread: summary,
        messages: [{
          id: 'load-all-old',
          threadID: summary.id,
          role: 'user' as const,
          content: 'Older page',
          timestamp: '2026-07-10T12:00:00Z'
        }],
        hasMoreBefore: false
      };
    });
    useShellStore.setState({
      bridge: mockBridge({ chatThreadList: async () => ({ threads: [summary] }), chatThreadGet }),
      fixtureMode: false,
      bridgeReady: true
    });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('button', { name: 'Load all earlier messages' })).toBeTruthy());

    fireEvent.click(screen.getByRole('button', { name: 'Load all earlier messages' }));
    await waitFor(() => expect(screen.getByText('Older page')).toBeTruthy());
    expect(chatThreadGet).toHaveBeenCalledTimes(2);
    expect(screen.queryByRole('button', { name: 'Load all earlier messages' })).toBeNull();
  });

  it('uploads an attachment before sending an opaque reference to the gateway', async () => {
    const summary = {
      id: 'thread-attachment-ui',
      title: 'Attachment thread',
      preview: 'A durable transcript',
      messageCount: 1,
      createdAt: '2026-07-10T12:00:00Z',
      updatedAt: '2026-07-10T12:00:00Z'
    };
    const upload = vi.fn(async () => ({
      attachmentId: 'attachment-ui-1',
      fileName: 'notes.md',
      mimeType: 'text/markdown',
      byteSize: 5,
      sha256: 'a'.repeat(64)
    }));
    const gatewayRequests: GatewayProxyRequest[] = [];
    useShellStore.setState({
      bridge: mockBridge({
        chatAttachmentUpload: upload,
        chatThreadList: async () => ({ threads: [summary] }),
        chatThreadGet: async () => ({
          thread: summary,
          messages: [{
            id: 'attachment-existing',
            threadID: summary.id,
            role: 'assistant',
            content: 'Ready.',
            timestamp: '2026-07-10T12:00:00Z'
          }],
          hasMoreBefore: false
        }),
        gatewayProbe: async () => true,
        gatewayChatStream: async (request, onChunk) => {
          gatewayRequests.push(request);
          onChunk('data: {"choices":[{"delta":{"content":"Done"}}]}\n\n');
          onChunk('data: [DONE]\n\n');
        }
      }),
      fixtureMode: false,
      bridgeReady: true,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('log')).toBeTruthy());
    fireEvent.change(screen.getByLabelText('Message composer'), { target: { value: 'Review this' } });
    fireEvent.change(screen.getByLabelText('Attachment file'), {
      target: { files: [new File(['hello'], 'notes.md', { type: 'text/markdown' })] }
    });
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }));
    await waitFor(() => expect(upload).toHaveBeenCalledOnce());
    await waitFor(() => expect(gatewayRequests).toHaveLength(1));
    expect(gatewayRequests[0]?.messages.at(-1)?.attachments).toEqual([
      { attachmentId: 'attachment-ui-1' }
    ]);
  });

  it('fails before upload and preserves a PDF draft when the gateway cannot read it', async () => {
    const summary = {
      id: 'thread-pdf-ui',
      title: 'PDF thread',
      preview: 'A durable transcript',
      messageCount: 1,
      createdAt: '2026-07-10T12:00:00Z',
      updatedAt: '2026-07-10T12:00:00Z'
    };
    const upload = vi.fn(async () => ({
      attachmentId: 'attachment-pdf-ui',
      fileName: 'brief.pdf',
      mimeType: 'application/pdf',
      byteSize: 5,
      sha256: 'b'.repeat(64)
    }));
    const append = vi.fn(bridgeStubDefaults.chatMessageAppend);
    const gateway = vi.fn(async (_request: GatewayProxyRequest, onChunk: (chunk: string) => void) => {
      onChunk('data: [DONE]\n\n');
    });
    useShellStore.setState({
      bridge: mockBridge({
        chatAttachmentUpload: upload,
        chatThreadList: async () => ({ threads: [summary] }),
        chatThreadGet: async () => ({
          thread: summary,
          messages: [{
            id: 'pdf-existing',
            threadID: summary.id,
            role: 'assistant',
            content: 'Ready.',
            timestamp: '2026-07-10T12:00:00Z'
          }],
          hasMoreBefore: false
        }),
        gatewayProbe: async () => true,
        gatewayChatStream: gateway
      }),
      fixtureMode: false,
      bridgeReady: true,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    // Override after mockBridge construction so the test can prove no durable
    // append is attempted when the attachment capability preflight fails.
    useShellStore.setState({ bridge: { ...useShellStore.getState().bridge!, chatMessageAppend: append } });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('log')).toBeTruthy());
    fireEvent.change(screen.getByLabelText('Message composer'), { target: { value: 'Read this PDF' } });
    fireEvent.change(screen.getByLabelText('Attachment file'), {
      target: { files: [new File(['%PDF-'], 'brief.pdf', { type: 'application/pdf' })] }
    });
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }));

    await waitFor(() => expect(screen.getByRole('alert').textContent).toMatch(/cannot read PDF content yet/i));
    expect(upload).not.toHaveBeenCalled();
    expect(append).not.toHaveBeenCalled();
    expect(gateway).not.toHaveBeenCalled();
    expect(screen.getByLabelText('Message composer')).toHaveProperty('value', 'Read this PDF');
    expect(screen.getByTestId('pending-attachment').textContent).toContain('brief.pdf');
  });

  it('preflights a native image capability before uploading the attachment', async () => {
    const summary = {
      id: 'thread-image-ui',
      title: 'Image thread',
      preview: 'A durable transcript',
      messageCount: 1,
      createdAt: '2026-07-10T12:00:00Z',
      updatedAt: '2026-07-10T12:00:00Z'
    };
    const capability = vi.fn(async () => ({
      mimeType: 'image/png',
      state: 'supported' as const,
      reason: 'catalog',
      maxBytes: 5 * 1024 * 1024
    }));
    const upload = vi.fn(async () => ({
      attachmentId: 'attachment-image-ui',
      fileName: 'photo.png',
      mimeType: 'image/png',
      byteSize: 5,
      sha256: 'c'.repeat(64)
    }));
    const gatewayRequests: GatewayProxyRequest[] = [];
    useShellStore.setState({
      bridge: mockBridge({
        gatewayAttachmentCapability: capability,
        chatAttachmentUpload: upload,
        chatThreadList: async () => ({ threads: [summary] }),
        chatThreadGet: async () => ({
          thread: summary,
          messages: [{
            id: 'image-existing',
            threadID: summary.id,
            role: 'assistant',
            content: 'Ready.',
            timestamp: '2026-07-10T12:00:00Z'
          }],
          hasMoreBefore: false
        }),
        gatewayProbe: async () => true,
        gatewayChatStream: async (request, onChunk) => {
          gatewayRequests.push(request);
          onChunk('data: {"choices":[{"delta":{"content":"Done"}}]}\n\n');
          onChunk('data: [DONE]\n\n');
        }
      }),
      fixtureMode: false,
      bridgeReady: true,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('log')).toBeTruthy());
    fireEvent.change(screen.getByLabelText('Message composer'), { target: { value: 'Inspect this image' } });
    fireEvent.change(screen.getByLabelText('Attachment file'), {
      target: { files: [new File(['hello'], 'photo.png', { type: 'image/png' })] }
    });
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }));
    await waitFor(() => expect(capability).toHaveBeenCalledWith('hermes', 'image/png'));
    await waitFor(() => expect(upload).toHaveBeenCalledOnce());
    await waitFor(() => expect(gatewayRequests).toHaveLength(1));
    expect(gatewayRequests[0]?.messages.at(-1)?.attachments).toEqual([
      { attachmentId: 'attachment-image-ui' }
    ]);
  });

  it('keeps options functional for reconnect and the Linux pop-out boundary', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: null, bridgeReady: true });
    const open = vi.spyOn(window, 'open').mockReturnValue({ focus: vi.fn() } as unknown as Window);
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('log')).toBeTruthy());
    fireEvent.click(screen.getAllByLabelText('Chat options')[0]!);
    expect(screen.getByRole('menu', { name: 'Chat options' })).toBeTruthy();
    fireEvent.click(screen.getByRole('menuitem', { name: 'Resume thread from daemon' }));
    await waitFor(() => expect(screen.getByText('Thread resumed from the daemon.')).toBeTruthy());
    fireEvent.click(screen.getByRole('menuitem', { name: 'Pop out chat' }));
    await waitFor(() => expect(open).toHaveBeenCalledOnce());
    // `window.open` is synchronous, but the status toast is set after the
    // async pop-out boundary resolves. Wait for the state update instead of
    // coupling this assertion to a particular microtask scheduling order.
    await waitFor(() => expect(screen.getByText('Chat opened in a separate window.')).toBeTruthy());
  });

  it('renders persisted system messages with an accessible system label', async () => {
    const summary = {
      id: 'thread-system',
      title: 'Policy thread',
      preview: 'Pinned policy',
      messageCount: 1,
      createdAt: '2026-07-10T12:00:00Z',
      updatedAt: '2026-07-10T12:00:00Z'
    };
    useShellStore.setState({
      bridge: mockBridge({
        chatThreadList: async () => ({ threads: [summary] }),
        chatThreadGet: async () => ({
          thread: summary,
          messages: [{
            id: 'system-1',
            threadID: summary.id,
            role: 'system',
            content: 'Pinned policy context',
            timestamp: '2026-07-10T12:00:00Z'
          }],
          hasMoreBefore: false
        })
      }),
      fixtureMode: false,
      bridgeReady: true
    });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('note', { name: /System message/i })).toBeTruthy());
    expect(screen.getByText(/live daemon chat history/i)).toBeTruthy();
  });

  it('shows error banner on fetch failure', async () => {
    useShellStore.setState({
      bridge: mockBridge({
        chatThreadList: async () => {
          throw new Error('daemon down');
        }
      }),
      fixtureMode: false,
      bridgeReady: true
    });
    render(<ChatSurface />);
    await waitFor(() => {
      expect(screen.getByRole('alert')).toBeTruthy();
    });
    expect(screen.getByText(/daemon down/i)).toBeTruthy();
  });

  it('shows fixture warning banners and via Hermes badge', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: null, bridgeReady: true });
    render(<ChatSurface />);
    await waitFor(() => {
      expect(screen.getByText(/Index stale/i)).toBeTruthy();
    });
    expect(screen.getByText(/Cloud \/ shared unavailable/i)).toBeTruthy();
    expect(screen.getByText(/via Hermes/i)).toBeTruthy();
  });

  it('shows streaming stop control when streaming flag is set', async () => {
    const list = fixtureSessionList();
    useShellStore.setState({
      bridge: mockBridge({ chatThreadList: async () => chatThreadsFromSessions(list) }),
      fixtureMode: true,
      bridgeReady: true
    });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('log')).toBeTruthy());
    act(() => {
      useChatStore.setState({ streaming: true });
    });
    expect(screen.getByRole('button', { name: /Stop generating/i })).toBeTruthy();
  });

  it('announces stream completion and abort transitions politely', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: null, bridgeReady: true });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('log')).toBeTruthy());

    act(() => {
      useChatStore.setState({ streamPhase: 'streaming' });
    });
    act(() => {
      useChatStore.setState({ streamPhase: 'done' });
    });
    await waitFor(() => expect(screen.getByText('Response complete. 1')).toBeTruthy());

    act(() => {
      useChatStore.setState({ streamPhase: 'streaming' });
    });
    act(() => {
      useChatStore.setState({ streamPhase: 'done' });
    });
    await waitFor(() => expect(screen.getByText('Response complete. 2')).toBeTruthy());

    act(() => {
      useChatStore.setState({ streamPhase: 'streaming' });
    });
    act(() => {
      useChatStore.setState({ streamPhase: 'aborted' });
    });
    await waitFor(() => expect(screen.getByText('Stream stopped. 3')).toBeTruthy());
  });

  it('keeps the draft and blocks sends while a turn is still composing', async () => {
    const list = fixtureSessionList();
    useShellStore.setState({
      bridge: mockBridge({ chatThreadList: async () => chatThreadsFromSessions(list) }),
      fixtureMode: true,
      bridgeReady: true
    });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('log')).toBeTruthy());
    act(() => {
      useChatStore.setState({ streamPhase: 'composing' });
    });
    const composer = screen.getByLabelText(/Message composer/i) as HTMLTextAreaElement;
    fireEvent.change(composer, { target: { value: 'second message' } });
    expect(screen.getByRole('button', { name: /Send message/i })).toHaveProperty('disabled', true);
    fireEvent.keyDown(composer, { key: 'Enter' });
    // The store's composing guard drops sends, so the Composer must not have
    // cleared the draft — otherwise the user's text is silently lost.
    expect(composer.value).toBe('second message');
    expect(
      useChatStore.getState().messages.some((message) => message.text === 'second message')
    ).toBe(false);
  });

  it('uses backend-specific composer placeholder for Codex', async () => {
    const list = fixtureSessionList();
    useShellStore.setState({
      bridge: mockBridge({ chatThreadList: async () => chatThreadsFromSessions(list) }),
      fixtureMode: true,
      bridgeReady: true
    });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('log')).toBeTruthy());
    act(() => {
      useChatStore.setState({ backend: 'codex' });
    });
    await waitFor(() => {
      expect(screen.getByPlaceholderText(/Ask Codex/i)).toBeTruthy();
    });
  });


  it('streams a scripted fixture response from the composer', async () => {
    useShellStore.setState({ fixtureMode: true, bridge: null, bridgeReady: true });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByRole('log')).toBeTruthy());
    fireEvent.change(screen.getByLabelText(/Message composer/i), { target: { value: 'hello fixture' } });
    fireEvent.keyDown(screen.getByLabelText(/Message composer/i), { key: 'Enter' });
    await waitFor(() => {
      expect(screen.getByText(/Fixture stream online/i)).toBeTruthy();
    });
    // The tool_call frame arrives one fixture-stream tick after the first
    // delta, so it must be awaited too or the assertion races the stream.
    await waitFor(() => {
      expect(screen.getByText(/workspace.read/i)).toBeTruthy();
      expect(screen.getByText(/does not expose the daemon run approval identity/i)).toBeTruthy();
      expect(screen.getByRole('button', { name: /Open Mission Control/i })).toBeTruthy();
      expect(screen.queryByRole('button', { name: /^Approve$/i })).toBeNull();
    });
    fireEvent.click(screen.getByRole('button', { name: /Open Mission Control/i }));
    expect(useShellStore.getState().route).toBe('missions');
  });

  it('disables composer when gateway health is unreachable', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => {
        throw new TypeError('connection refused');
      })
    );
    useShellStore.setState({
      bridge: mockBridge({ chatThreadList: async () => ({ threads: [] }) }),
      fixtureMode: false,
      bridgeReady: true,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByText(/Gateway health check failed/i)).toBeTruthy());
    expect(screen.getByRole('button', { name: /Send message/i })).toHaveProperty('disabled', true);
  });

  it('renders an unimplemented response from the native gateway proxy honestly', async () => {
    useShellStore.setState({
      bridge: mockBridge({
        chatThreadList: async () => ({ threads: [] }),
        gatewayProbe: async () => true,
        gatewayChatStream: async () => {
          throw new Error('gateway_http:503:chat completions unimplemented');
        }
      }),
      fixtureMode: false,
      bridgeReady: true,
      health: { ok: true, gatewayEnabled: true, gatewayHost: '127.0.0.1', gatewayPort: 8642 }
    });
    render(<ChatSurface />);
    await waitFor(() => expect(screen.getByLabelText(/Message composer/i)).toBeTruthy());
    const composer = screen.getByLabelText(/Message composer/i);
    fireEvent.change(composer, { target: { value: 'hello live gateway' } });
    await waitFor(() => {
      expect(screen.getByRole('button', { name: /Send message/i })).toHaveProperty('disabled', false);
    });
    fireEvent.click(screen.getByRole('button', { name: /Send message/i }));
    await waitFor(() => {
      expect(screen.getByText(/Gateway chat is not available in this Linux daemon build yet/i)).toBeTruthy();
    });
  });
});
