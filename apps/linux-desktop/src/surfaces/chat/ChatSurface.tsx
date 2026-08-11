import { useEffect, useState } from 'react';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { chatSelectionFromHash } from '../../routes.js';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { useChatStore } from '../../state/chatStore.js';
import {
  activeChatWorkspacePane,
  collectChatWorkspacePanes,
  selectedChatWorkspaceTab,
  useChatWorkspaceStore
} from '../../state/chatWorkspaceStore.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { ChatPaneWorkspace } from './ChatPaneWorkspace.js';
import { ChatToolbar } from './ChatToolbar.js';
import {
  buildChatExportDocument,
  chatMessagesForExport,
  downloadChatExport,
  loadCompleteChatHistory,
  sanitizeChatExportFilename,
  serializeChatExport,
  type ChatExportFormat
} from './chatExport.js';
import { closeChatPopoutWindow, isChatPopoutWindow, openChatPopoutWindow } from './chatWindow.js';
import './chat.css';

export function ChatSurface() {
  const fixtureMode = useShellStore((state) => state.fixtureMode);
  const bridge = useShellStore((state) => state.bridge);
  const routeHash = useShellStore((state) => state.routeHash);
  const routeRevision = useShellStore((state) => state.routeRevision);
  const bridgeReady = useShellStore((state) => state.bridgeReady);
  const status = useDaemonStatusCopy();
  const threads = useChatStore((state) => state.threads);
  const loading = useChatStore((state) => state.loading);
  const error = useChatStore((state) => state.error);
  const load = useChatStore((state) => state.load);
  const workspaceTabs = useChatWorkspaceStore((state) => state.tabs);
  const selectedTabID = useChatWorkspaceStore((state) => state.selectedTabID);
  const controllerRevision = useChatWorkspaceStore((state) => state.controllerRevision);
  const selectedTab = selectedChatWorkspaceTab({ tabs: workspaceTabs, selectedTabID });
  const activePane = activeChatWorkspacePane({ tabs: workspaceTabs, selectedTabID })
    ?? collectChatWorkspacePanes(selectedTab.root)[0]!;
  const controller = activePane.controller;
  const selectedThreadId = controller((state) => state.selectedThreadId);
  const messages = controller((state) => state.messages);
  const messagesLoading = controller((state) => state.messagesLoading);
  const backend = controller((state) => state.backend);
  const modelLabel = controller((state) => state.modelLabel);
  const modelOptionID = controller((state) => state.modelOptionID);
  const thinkingLevel = controller((state) => state.thinkingLevel);
  const config = controller((state) => state.config);
  const catalog = controller((state) => state.catalog);
  const streaming = controller((state) => state.streaming);
  const streamPhase = controller((state) => state.streamPhase);
  const gatewayBaseURL = controller((state) => state.gatewayBaseURL);
  const [streamAnnouncement, setStreamAnnouncement] = useState({ text: '', count: 0 });
  const [exportFormat, setExportFormat] = useState<ChatExportFormat>('json');
  const [exportBusy, setExportBusy] = useState(false);
  const [exportStatus, setExportStatus] = useState<string | null>(null);
  const [resumeStatus, setResumeStatus] = useState<string | null>(null);
  const [popoutStatus, setPopoutStatus] = useState<string | null>(null);
  const popoutWindow = isChatPopoutWindow();

  useLaneLoad(load);

  useEffect(() => {
    const selection = chatSelectionFromHash(routeHash);
    if (!selection) return;
    let cancelled = false;
    queueMicrotask(() => {
      if (cancelled || useChatStore.getState().loading) return;
      void useChatWorkspaceStore.getState().bindThread(selection.threadID, activePane.id);
    });
    return () => {
      cancelled = true;
    };
  }, [activePane.id, bridgeReady, loading, routeHash, routeRevision]);

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
  }, [activePane.id, selectedThreadId]);

  useEffect(() => {
    const reconnect = () => void controller.getState().reconnectGateway();
    window.addEventListener('online', reconnect);
    document.addEventListener('visibilitychange', reconnect);
    return () => {
      window.removeEventListener('online', reconnect);
      document.removeEventListener('visibilitychange', reconnect);
    };
  }, [controller]);

  const activeThreads = controller.getState().threads;
  const selectedThread =
    activeThreads.find((thread) => thread.id === selectedThreadId)
    ?? threads.find((thread) => thread.id === selectedThreadId)
    ?? null;
  const exportDisabled = !selectedThread || selectedThread.messageCount === 0;
  const gatewayHint = gatewayBaseURL ? `gateway ${gatewayBaseURL}` : null;
  const tiledOrTabbed = collectChatWorkspacePanes(selectedTab.root).length > 1 || workspaceTabs.length > 1;
  const provenance = fixtureMode ? 'fixture transcript' : 'live daemon chat history';
  const offline = !fixtureMode && !bridge;

  const exportChat = async () => {
    if (!selectedThread || exportDisabled || exportBusy) return;
    setExportBusy(true);
    setExportStatus('Loading complete transcript from the daemon…');
    try {
      const exportMessages = fixtureMode || !bridge
        ? messages
        : chatMessagesForExport(
            await loadCompleteChatHistory(selectedThread, (threadID, maxMessages, before) =>
              bridge.chatThreadGet(threadID, maxMessages, before)
            )
          );
      const document = buildChatExportDocument(selectedThread, exportMessages);
      const filename = sanitizeChatExportFilename(selectedThread.title, selectedThread.id, exportFormat);
      downloadChatExport({
        filename,
        content: serializeChatExport(document, exportFormat),
        mimeType: exportFormat === 'markdown' ? 'text/markdown' : 'application/json'
      });
      setExportStatus(`Exported ${filename}`);
    } catch (exportError) {
      setExportStatus(exportError instanceof Error ? exportError.message : 'Chat export failed.');
    } finally {
      setExportBusy(false);
    }
  };

  const resumeChat = async () => {
    if (!selectedThreadId) return;
    setResumeStatus('Reloading the durable thread from the daemon…');
    const resumed = await controller.getState().resumeThread();
    setResumeStatus(resumed ? 'Thread resumed from the daemon.' : 'Thread resume is unavailable.');
  };

  const openPopout = async () => {
    const opened = await openChatPopoutWindow();
    setPopoutStatus(opened ? 'Chat opened in a separate window.' : 'A separate chat window is unavailable.');
  };

  if (offline) {
    return (
      <div className="chat-surface">
        <OfflineNotice
          status={status}
          summary="Chat needs the packaged shell and local daemon before threads can load."
          fixtureMode={fixtureMode}
        />
      </div>
    );
  }

  return (
    <div className="chat-surface" data-controller-revision={controllerRevision}>
      <p className="chat-provenance">Source: {provenance}</p>
      <p className="sr-only" aria-live="polite">
        {loading ? 'Loading threads' : `${threads.length} thread${threads.length === 1 ? '' : 's'}`}
      </p>
      <p className="sr-only" aria-live="polite" aria-atomic="true">
        {streamAnnouncement.text ? `${streamAnnouncement.text} ${streamAnnouncement.count}` : ''}
      </p>
      {error ? (
        <Banner tone="degraded">
          <p>{error}</p>
          <div className="actions">
            <button type="button" className="primary" onClick={() => void load()}>
              Retry
            </button>
          </div>
        </Banner>
      ) : null}
      <ChatToolbar
        thread={selectedThread}
        gatewayHint={gatewayHint}
        backend={backend}
        modelLabel={modelLabel}
        modelOptionID={modelOptionID}
        thinkingLevel={thinkingLevel}
        config={config}
        catalog={catalog}
        onBackendChange={(value) => controller.getState().setBackend(value)}
        onModelOptionChange={(value) => controller.getState().setModelOption(value)}
        onThinkingLevelChange={(value) => controller.getState().setThinkingLevel(value)}
        onReconnect={() => void controller.getState().reconnectGateway()}
        onResume={() => void resumeChat()}
        resumeDisabled={!selectedThreadId || messagesLoading || streaming}
        resumeStatus={resumeStatus}
        onPopOut={popoutWindow ? undefined : () => void openPopout()}
        onClosePopOut={popoutWindow ? () => void closeChatPopoutWindow() : undefined}
        popoutWindow={popoutWindow}
        popoutStatus={popoutStatus}
        onNewChat={() => controller.getState().startNewChat()}
        exportFormat={exportFormat}
        onExportFormatChange={setExportFormat}
        onExport={() => void exportChat()}
        exportDisabled={exportDisabled}
        exportBusy={exportBusy}
        exportStatus={exportStatus}
        showEnginePickers={!tiledOrTabbed}
      />
      <ChatPaneWorkspace />
    </div>
  );
}
