import { useEffect, useState, type ReactNode } from 'react';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { useChatStore } from '../../state/chatStore.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { chatSelectionFromHash } from '../../routes.js';
import {
  canOpenChatCitation,
  normalizeMemoryCitations,
  type MemoryCitation
} from './chatTypes.js';
import { ChatWorkspacePanel } from './ChatWorkspacePanel.js';
import {
  uploadChatAttachmentForSend
} from './chatAttachment.js';
import { closeChatPopoutWindow, isChatPopoutWindow, openChatPopoutWindow } from './chatWindow.js';
import type { PendingChatAttachment } from './Composer.js';
import {
  buildChatExportDocument,
  chatMessagesForExport,
  downloadChatExport,
  loadCompleteChatHistory,
  sanitizeChatExportFilename,
  serializeChatExport,
  type ChatExportFormat
} from './chatExport.js';
import './chat.css';

export function ChatSurface() {
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const setRoute = useShellStore((s) => s.setRoute);
  const routeHash = useShellStore((s) => s.routeHash);
  const routeRevision = useShellStore((s) => s.routeRevision);
  const bridgeReady = useShellStore((s) => s.bridgeReady);
  const status = useDaemonStatusCopy();

  const threads = useChatStore((s) => s.threads);
  const loading = useChatStore((s) => s.loading);
  const error = useChatStore((s) => s.error);
  const query = useChatStore((s) => s.query);
  const visibleThreadCount = useChatStore((s) => s.visibleThreadCount);
  const selectedThreadId = useChatStore((s) => s.selectedThreadId);
  const messages = useChatStore((s) => s.messages);
  const messagesLoading = useChatStore((s) => s.messagesLoading);
  const hasMoreMessages = useChatStore((s) => s.hasMoreMessages);
  const loadingOlderMessages = useChatStore((s) => s.loadingOlderMessages);
  const loadingAllMessages = useChatStore((s) => s.loadingAllMessages);
  const historyError = useChatStore((s) => s.historyError);
  const config = useChatStore((s) => s.config);
  const catalog = useChatStore((s) => s.catalog);
  const backend = useChatStore((s) => s.backend);
  const modelLabel = useChatStore((s) => s.modelLabel);
  const modelOptionID = useChatStore((s) => s.modelOptionID);
  const thinkingLevel = useChatStore((s) => s.thinkingLevel);
  const streaming = useChatStore((s) => s.streaming);
  const streamPhase = useChatStore((s) => s.streamPhase);
  const streamError = useChatStore((s) => s.streamError);
  const gatewayStatus = useChatStore((s) => s.gatewayStatus);
  const gatewayBaseURL = useChatStore((s) => s.gatewayBaseURL);
  const warnings = useChatStore((s) => s.warnings);
  const sharedFeaturesAvailable = useChatStore((s) => s.sharedFeaturesAvailable);
  const load = useChatStore((s) => s.load);
  const reconnectGateway = useChatStore((s) => s.reconnectGateway);
  const search = useChatStore((s) => s.search);
  const selectThread = useChatStore((s) => s.selectThread);
  const resumeThread = useChatStore((s) => s.resumeThread);
  const loadOlderMessages = useChatStore((s) => s.loadOlderMessages);
  const loadAllMessages = useChatStore((s) => s.loadAllMessages);
  const loadUntilMessage = useChatStore((s) => s.loadUntilMessage);
  const loadMoreThreads = useChatStore((s) => s.loadMoreThreads);
  const setBackend = useChatStore((s) => s.setBackend);
  const setModelOption = useChatStore((s) => s.setModelOption);
  const setThinkingLevel = useChatStore((s) => s.setThinkingLevel);
  const startNewChat = useChatStore((s) => s.startNewChat);
  const sendMessage = useChatStore((s) => s.sendMessage);
  const respondToToolApproval = useChatStore((s) => s.respondToToolApproval);
  const retryToolApproval = useChatStore((s) => s.retryToolApproval);
  const stopStreaming = useChatStore((s) => s.stopStreaming);
  const [streamAnnouncement, setStreamAnnouncement] = useState({ text: '', count: 0 });
  const [exportFormat, setExportFormat] = useState<ChatExportFormat>('json');
  const [exportBusy, setExportBusy] = useState(false);
  const [exportStatus, setExportStatus] = useState<string | null>(null);
  const [resumeStatus, setResumeStatus] = useState<string | null>(null);
  const [citationStatus, setCitationStatus] = useState<string | null>(null);
  const [popoutStatus, setPopoutStatus] = useState<string | null>(null);
  const popoutWindow = isChatPopoutWindow();

  useLaneLoad(load);

  useEffect(() => {
    const selection = chatSelectionFromHash(routeHash);
    if (!selection) return;
    let cancelled = false;
    queueMicrotask(() => {
      if (cancelled || useChatStore.getState().loading) return;
      void selectThread(selection.threadID);
    });
    return () => {
      cancelled = true;
    };
  }, [bridgeReady, loading, routeHash, routeRevision, selectThread]);

  useEffect(() => {
    const selection = chatSelectionFromHash(routeHash);
    if (!selection || selectedThreadId !== selection.threadID || messagesLoading) return;
    const frame = window.requestAnimationFrame(() => {
      const row = Array.from(document.querySelectorAll<HTMLElement>('[data-chat-thread-id]')).find(
        (candidate) => candidate.dataset.chatThreadId === selection.threadID
      );
      row?.scrollIntoView?.({ block: 'nearest' });
      row?.focus?.({ preventScroll: true });
    });
    return () => window.cancelAnimationFrame(frame);
  }, [messagesLoading, routeHash, routeRevision, selectedThreadId, threads]);

  useEffect(() => {
    if (streamPhase === 'done') {
      setStreamAnnouncement((previous) => ({ text: 'Response complete.', count: previous.count + 1 }));
    } else if (streamPhase === 'aborted') {
      setStreamAnnouncement((previous) => ({ text: 'Stream stopped.', count: previous.count + 1 }));
    }
  }, [streamPhase]);

  useEffect(() => {
    setExportStatus(null);
    setResumeStatus(null);
  }, [selectedThreadId]);

  useEffect(() => {
    setCitationStatus(null);
  }, [selectedThreadId]);

  useEffect(() => {
    const reconnect = () => void reconnectGateway();
    window.addEventListener('online', reconnect);
    document.addEventListener('visibilitychange', reconnect);
    return () => {
      window.removeEventListener('online', reconnect);
      document.removeEventListener('visibilitychange', reconnect);
    };
  }, [reconnectGateway]);

  const sendComposerMessage = async (
    text: string,
    attachment?: PendingChatAttachment
  ): Promise<boolean> => {
    if (attachment) {
      const uploaded = await uploadChatAttachmentForSend(
        bridge,
        fixtureMode,
        useChatStore.getState().modelLabel.trim() || 'hermes',
        attachment
      );
      await sendMessage(text, [uploaded]);
    } else {
      await sendMessage(text);
    }
    return useChatStore.getState().streamPhase === 'done';
  };

  const openPopout = async () => {
    const opened = await openChatPopoutWindow();
    setPopoutStatus(opened ? 'Chat opened in a separate window.' : 'A separate chat window is unavailable.');
  };

  const resumeChat = async () => {
    if (!selectedThreadId) return;
    setResumeStatus('Reloading the durable thread from the daemon…');
    const resumed = await resumeThread();
    setResumeStatus(resumed ? 'Thread resumed from the daemon.' : 'Thread resume is unavailable.');
  };

  const offline = !fixtureMode && !bridge;
  const provenance = fixtureMode ? 'fixture transcript' : 'live daemon chat history';
  const visibleThreads = threads.slice(0, visibleThreadCount);
  const hasMoreThreads = threads.length > visibleThreadCount;
  const selectedThread = threads.find((t) => t.id === selectedThreadId) ?? null;
  const exportDisabled = !selectedThread || selectedThread.messageCount === 0;
  const gatewayHint = gatewayBaseURL ? `gateway ${gatewayBaseURL}` : null;
  const liveComposerDisabled = !fixtureMode && gatewayStatus !== 'reachable';
  const liveComposerDisabledReason =
    gatewayStatus === 'disabled'
      ? 'Gateway chat is disabled in daemon health.'
      : gatewayStatus === 'unreachable'
        ? 'Gateway health check failed.'
        : gatewayStatus === 'unknown'
          ? 'Checking gateway health…'
          : '';

  const exportChat = async () => {
    if (!selectedThread || exportDisabled || exportBusy) return;
    setExportBusy(true);
    setExportStatus('Loading complete transcript from the daemon…');
    try {
      // Export is daemon-authoritative. The visible WebView page may be only
      // the newest bounded slice, so walk older pages before creating a file.
      const exportMessages = fixtureMode || !bridge
        ? messages
        : chatMessagesForExport(
            await loadCompleteChatHistory(selectedThread, (threadID, maxMessages, before) =>
              bridge.chatThreadGet(threadID, maxMessages, before)
            )
          );
      const document = buildChatExportDocument(selectedThread, exportMessages);
      const filename = sanitizeChatExportFilename(selectedThread.title, selectedThread.id, exportFormat);
      const content = serializeChatExport(document, exportFormat);
      downloadChatExport({
        filename,
        content,
        mimeType: exportFormat === 'markdown' ? 'text/markdown' : 'application/json'
      });
      setExportStatus(`Exported ${filename}`);
    } catch (error) {
      setExportStatus(error instanceof Error ? error.message : 'Chat export failed.');
    } finally {
      setExportBusy(false);
    }
  };

  const openCitation = async (citation: MemoryCitation) => {
    const normalized = normalizeMemoryCitations([citation])[0];
    const availableThreadIDs = threads.map((thread) => thread.id);
    if (!normalized || !canOpenChatCitation(normalized, selectedThreadId, availableThreadIDs)) return;
    const targetThreadID = normalized.threadID ?? selectedThreadId;
    const targetMessageID = normalized.messageId;
    if (!targetMessageID || !targetThreadID || streaming) return;
    setCitationStatus('Opening cited source message…');
    if (targetThreadID !== selectedThreadId) {
      await selectThread(targetThreadID);
    }
    if (useChatStore.getState().selectedThreadId !== targetThreadID) {
      setCitationStatus('Cited source is no longer available.');
      return;
    }
    const messageExists = useChatStore
      .getState()
      .messages.some((message) => message.id === targetMessageID && message.threadID === targetThreadID);
    if (!messageExists) {
      setCitationStatus('Loading cited source message from the daemon…');
      const loaded = await loadUntilMessage(targetMessageID, targetThreadID);
      if (!loaded) {
        setCitationStatus('Cited source is no longer available.');
        return;
      }
    }
    setCitationStatus('Cited source message opened.');
    if (typeof document !== 'undefined') {
      const element = Array.from(document.querySelectorAll<HTMLElement>('[data-chat-message-id]')).find(
        (candidate) => candidate.dataset.chatMessageId === targetMessageID
      );
      element?.scrollIntoView?.({ block: 'center', behavior: 'smooth' });
      element?.focus?.({ preventScroll: true });
    }
  };

  const panelProps = {
    threads: visibleThreads,
    selectedId: selectedThreadId,
    railLoading: loading && threads.length === 0,
    query,
    hasMore: hasMoreThreads,
    onSelect: (id: string) => void selectThread(id),
    onSearch: (q: string) => void search(q),
    onLoadMore: loadMoreThreads,
    onNewChat: startNewChat,
    selectedThread,
    gatewayHint,
    backend,
    modelLabel,
    modelOptionID,
    thinkingLevel,
    config,
    catalog,
    onBackendChange: setBackend,
    onModelOptionChange: setModelOption,
    onThinkingLevelChange: setThinkingLevel,
    onReconnect: () => void reconnectGateway(),
    onResume: () => void resumeChat(),
    resumeDisabled: !selectedThreadId || messagesLoading || streaming,
    resumeStatus,
    onPopOut: popoutWindow ? undefined : () => void openPopout(),
    onClosePopOut: popoutWindow ? () => void closeChatPopoutWindow() : undefined,
    popoutWindow,
    popoutStatus,
    exportFormat,
    onExportFormatChange: setExportFormat,
    onExport: exportChat,
    exportDisabled,
    exportBusy,
    exportStatus,
    messages,
    messagesLoading,
    hasMoreMessages,
    loadingOlderMessages,
    loadingAllMessages,
    historyError,
    totalMessageCount: selectedThread?.messageCount,
    onLoadOlderMessages: () => void loadOlderMessages(),
    onLoadAllMessages: () => void loadAllMessages(),
    warnings,
    sharedFeaturesAvailable,
    onOpenCitation: (citation: MemoryCitation) => void openCitation(citation),
    onToolApproval: (messageID: string, decision: Parameters<typeof respondToToolApproval>[1]) =>
      void respondToToolApproval(messageID, decision),
    onRetryToolApproval: (messageID: string) => void retryToolApproval(messageID),
    streaming,
    streamError,
    // The store guards sends during 'composing' (persist + gateway probe) but
    // the Composer clears the draft before calling onSend — surface the phase
    // so an Enter in that window cannot silently drop the user's text.
    composerBusy: streamPhase === 'composing',
    onSendMessage: (text: string, attachment?: PendingChatAttachment) => sendComposerMessage(text, attachment),
    onStopStreaming: stopStreaming,
    onOpenMissionControl: () => setRoute('missions')
  };

  let body: ReactNode;

  if (offline) {
    body = (
      <OfflineNotice
        status={status}
        summary="Chat needs the packaged shell and local daemon before threads can load."
        fixtureMode={fixtureMode}
      />
    );
  } else if (error) {
    body = (
      <>
        <Banner tone="degraded">
          <p>{error}</p>
          <div className="actions">
            <button type="button" className="primary" onClick={() => void load()}>
              Retry
            </button>
          </div>
        </Banner>
        <ChatWorkspacePanel
          {...panelProps}
          threads={[]}
          selectedId={null}
          railLoading={false}
          hasMore={false}
          selectedThread={null}
          gatewayHint={null}
          messages={[]}
          composerDisabled
          composerDisabledReason="Fix the connection and retry."
          mainFallback={<div className="chat-empty">Thread list unavailable until retry succeeds.</div>}
        />
      </>
    );
  } else if (loading && threads.length === 0) {
    body = (
      <ChatWorkspacePanel
        {...panelProps}
        threads={[]}
        selectedId={null}
        railLoading
        hasMore={false}
        selectedThread={null}
        messages={[]}
        composerDisabled={false}
        composerDisabledReason=""
        mainFallback={<div className="chat-stream-loading">Loading threads…</div>}
      />
    );
  } else if (threads.length === 0 && query.trim()) {
    body = (
      <ChatWorkspacePanel
        {...panelProps}
        threads={[]}
        selectedId={null}
        hasMore={false}
        selectedThread={null}
        messages={messages}
        composerDisabled={liveComposerDisabled}
        composerDisabledReason={liveComposerDisabledReason}
        mainFallback={<p className="chat-empty">No conversations match &lsquo;{query.trim()}&rsquo;.</p>}
      />
    );
  } else if (threads.length === 0) {
    body = (
      <ChatWorkspacePanel
        {...panelProps}
        threads={[]}
        selectedId={null}
        hasMore={false}
        selectedThread={null}
        messages={messages}
        composerDisabled={liveComposerDisabled}
        composerDisabledReason={liveComposerDisabledReason}
        mainFallback={<p className="chat-empty">No conversations yet</p>}
      />
    );
  } else {
    body = (
      <ChatWorkspacePanel
        {...panelProps}
        composerDisabled={liveComposerDisabled}
        composerDisabledReason={liveComposerDisabledReason}
        mainFallback={<p className="chat-empty">Select a thread from the rail.</p>}
      />
    );
  }

  return (
    <div className="chat-surface">
      <p className="chat-provenance">Source: {provenance}</p>
      <p className="sr-only" aria-live="polite">
        {loading ? 'Loading threads' : `${threads.length} thread${threads.length === 1 ? '' : 's'}`}
      </p>
      <p className="sr-only" aria-live="polite" aria-atomic="true">
        {streamAnnouncement.text ? `${streamAnnouncement.text} ${streamAnnouncement.count}` : ''}
      </p>
      <p className="sr-only" aria-live="polite" aria-atomic="true">
        {citationStatus ?? ''}
      </p>
      {body}
    </div>
  );
}
