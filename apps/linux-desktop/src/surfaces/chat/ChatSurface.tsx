import { useEffect, useState, type ReactNode } from 'react';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { useChatStore } from '../../state/chatStore.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { ChatWorkspacePanel } from './ChatWorkspacePanel.js';
import './chat.css';

export function ChatSurface() {
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const status = useDaemonStatusCopy();

  const threads = useChatStore((s) => s.threads);
  const loading = useChatStore((s) => s.loading);
  const error = useChatStore((s) => s.error);
  const query = useChatStore((s) => s.query);
  const visibleThreadCount = useChatStore((s) => s.visibleThreadCount);
  const selectedThreadId = useChatStore((s) => s.selectedThreadId);
  const messages = useChatStore((s) => s.messages);
  const messagesLoading = useChatStore((s) => s.messagesLoading);
  const config = useChatStore((s) => s.config);
  const backend = useChatStore((s) => s.backend);
  const modelLabel = useChatStore((s) => s.modelLabel);
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
  const loadMoreThreads = useChatStore((s) => s.loadMoreThreads);
  const setBackend = useChatStore((s) => s.setBackend);
  const startNewChat = useChatStore((s) => s.startNewChat);
  const sendMessage = useChatStore((s) => s.sendMessage);
  const stopStreaming = useChatStore((s) => s.stopStreaming);
  const [streamAnnouncement, setStreamAnnouncement] = useState({ text: '', count: 0 });

  useLaneLoad(load);

  useEffect(() => {
    if (streamPhase === 'done') {
      setStreamAnnouncement((previous) => ({ text: 'Response complete.', count: previous.count + 1 }));
    } else if (streamPhase === 'aborted') {
      setStreamAnnouncement((previous) => ({ text: 'Stream stopped.', count: previous.count + 1 }));
    }
  }, [streamPhase]);

  const offline = !fixtureMode && !bridge;
  const provenance = fixtureMode ? 'fixture transcript' : 'live daemon session index';
  const visibleThreads = threads.slice(0, visibleThreadCount);
  const hasMoreThreads = threads.length > visibleThreadCount;
  const selectedThread = threads.find((t) => t.id === selectedThreadId) ?? null;
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
    onBackendChange: setBackend,
    messages,
    messagesLoading,
    warnings,
    sharedFeaturesAvailable,
    streaming,
    streamError,
    onSendMessage: (text: string) => void sendMessage(text),
    onStopStreaming: stopStreaming
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
      <p className="muted chat-provenance">Source: {provenance}</p>
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
