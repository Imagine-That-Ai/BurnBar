import { useEffect, useState, type ReactNode } from 'react';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { useChatStore } from '../../state/chatStore.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { ChatWorkspacePanel } from './ChatWorkspacePanel.js';
import {
  buildChatExportDocument,
  downloadChatExport,
  sanitizeChatExportFilename,
  serializeChatExport,
  type ChatExportFormat
} from './chatExport.js';
import './chat.css';

export function ChatSurface() {
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const setRoute = useShellStore((s) => s.setRoute);
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
  const config = useChatStore((s) => s.config);
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
  const search = useChatStore((s) => s.search);
  const selectThread = useChatStore((s) => s.selectThread);
  const loadOlderMessages = useChatStore((s) => s.loadOlderMessages);
  const loadMoreThreads = useChatStore((s) => s.loadMoreThreads);
  const setBackend = useChatStore((s) => s.setBackend);
  const setModelOption = useChatStore((s) => s.setModelOption);
  const setThinkingLevel = useChatStore((s) => s.setThinkingLevel);
  const startNewChat = useChatStore((s) => s.startNewChat);
  const sendMessage = useChatStore((s) => s.sendMessage);
  const stopStreaming = useChatStore((s) => s.stopStreaming);
  const [streamAnnouncement, setStreamAnnouncement] = useState({ text: '', count: 0 });
  const [exportFormat, setExportFormat] = useState<ChatExportFormat>('json');
  const [exportStatus, setExportStatus] = useState<string | null>(null);

  useLaneLoad(load);

  useEffect(() => {
    if (streamPhase === 'done') {
      setStreamAnnouncement((previous) => ({ text: 'Response complete.', count: previous.count + 1 }));
    } else if (streamPhase === 'aborted') {
      setStreamAnnouncement((previous) => ({ text: 'Stream stopped.', count: previous.count + 1 }));
    }
  }, [streamPhase]);

  useEffect(() => {
    setExportStatus(null);
  }, [selectedThreadId]);

  const offline = !fixtureMode && !bridge;
  const provenance = fixtureMode ? 'fixture transcript' : 'live daemon chat history';
  const visibleThreads = threads.slice(0, visibleThreadCount);
  const hasMoreThreads = threads.length > visibleThreadCount;
  const selectedThread = threads.find((t) => t.id === selectedThreadId) ?? null;
  const exportableMessageCount = selectedThread
    ? buildChatExportDocument(selectedThread, messages).messages.length
    : 0;
  const exportDisabled = !selectedThread || exportableMessageCount === 0;
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

  const exportChat = () => {
    if (!selectedThread || exportDisabled) return;
    try {
      const document = buildChatExportDocument(selectedThread, messages);
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
    onBackendChange: setBackend,
    onModelOptionChange: setModelOption,
    onThinkingLevelChange: setThinkingLevel,
    exportFormat,
    onExportFormatChange: setExportFormat,
    onExport: exportChat,
    exportDisabled,
    exportStatus,
    messages,
    messagesLoading,
    hasMoreMessages,
    loadingOlderMessages,
    onLoadOlderMessages: () => void loadOlderMessages(),
    warnings,
    sharedFeaturesAvailable,
    streaming,
    streamError,
    // The store guards sends during 'composing' (persist + gateway probe) but
    // the Composer clears the draft before calling onSend — surface the phase
    // so an Enter in that window cannot silently drop the user's text.
    composerBusy: streamPhase === 'composing',
    onSendMessage: (text: string) => void sendMessage(text),
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
      {body}
    </div>
  );
}
