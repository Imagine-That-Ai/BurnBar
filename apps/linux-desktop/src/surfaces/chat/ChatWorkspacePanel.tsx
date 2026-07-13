import type { ReactNode } from 'react';
import type { ChatThreadSummary } from '../../tauriBridge.js';
import type { ChatBackendId } from './chatTypes.js';
import { ChatToolbar } from './ChatToolbar.js';
import { Composer } from './Composer.js';
import { MessageStream } from './MessageStream.js';
import { ThreadRail } from './ThreadRail.js';
import type { ChatWarningBanner } from './chatTypes.js';
import type { ChatMessage } from '../../state/chatStore.js';
import type { ChatExportFormat } from './chatExport.js';

export type ChatWorkspacePanelProps = {
  threads: ChatThreadSummary[];
  selectedId: string | null;
  railLoading: boolean;
  query: string;
  hasMore: boolean;
  onSelect: (id: string) => void;
  onSearch: (query: string) => void;
  onLoadMore: () => void;
  onNewChat: () => void;
  selectedThread: ChatThreadSummary | null;
  gatewayHint: string | null;
  backend: ChatBackendId;
  modelLabel: string;
  onBackendChange: (id: ChatBackendId) => void;
  exportFormat: ChatExportFormat;
  onExportFormatChange: (format: ChatExportFormat) => void;
  onExport: () => void;
  exportDisabled: boolean;
  exportStatus: string | null;
  messages: ChatMessage[];
  messagesLoading: boolean;
  hasMoreMessages: boolean;
  loadingOlderMessages: boolean;
  onLoadOlderMessages: () => void;
  warnings: ChatWarningBanner[];
  sharedFeaturesAvailable: boolean;
  streaming: boolean;
  streamError: string | null;
  composerDisabled: boolean;
  composerDisabledReason: string;
  /** True while a send is composing (persisting + probing) before streaming. */
  composerBusy: boolean;
  onSendMessage: (text: string) => void;
  onStopStreaming: () => void;
  onOpenMissionControl: () => void;
  mainFallback?: ReactNode;
};

export function ChatWorkspacePanel({
  threads,
  selectedId,
  railLoading,
  query,
  hasMore,
  onSelect,
  onSearch,
  onLoadMore,
  onNewChat,
  selectedThread,
  gatewayHint,
  backend,
  modelLabel,
  onBackendChange,
  exportFormat,
  onExportFormatChange,
  onExport,
  exportDisabled,
  exportStatus,
  messages,
  messagesLoading,
  hasMoreMessages,
  loadingOlderMessages,
  onLoadOlderMessages,
  warnings,
  sharedFeaturesAvailable,
  streaming,
  streamError,
  composerDisabled,
  composerDisabledReason,
  composerBusy,
  onSendMessage,
  onStopStreaming,
  onOpenMissionControl,
  mainFallback
}: ChatWorkspacePanelProps) {
  const hasActiveTranscript = Boolean(selectedThread) || messages.length > 0 || streaming;

  return (
    <div className="chat-workspace" data-testid="chat-workspace">
      <ChatToolbar
        thread={selectedThread}
        gatewayHint={gatewayHint}
        backend={backend}
        modelLabel={modelLabel}
        onBackendChange={onBackendChange}
        onNewChat={onNewChat}
        exportFormat={exportFormat}
        onExportFormatChange={onExportFormatChange}
        onExport={onExport}
        exportDisabled={exportDisabled}
        exportStatus={exportStatus}
      />
      <div className="chat-workspace-body">
        <ThreadRail
          threads={threads}
          selectedId={selectedId}
          loading={railLoading}
          query={query}
          hasMore={hasMore}
          onSelect={onSelect}
          onSearch={onSearch}
          onLoadMore={onLoadMore}
          onNewChat={onNewChat}
        />
        <div className="chat-main">
          {hasActiveTranscript ? (
            <MessageStream
              messages={messages}
              loading={messagesLoading}
              hasMoreBefore={hasMoreMessages}
              loadingOlderMessages={loadingOlderMessages}
              onLoadOlder={onLoadOlderMessages}
              warnings={warnings}
              sharedFeaturesAvailable={sharedFeaturesAvailable}
              streamError={streamError}
              streaming={streaming}
              onOpenMissionControl={onOpenMissionControl}
            />
          ) : (
            (mainFallback ?? (
              <div className="chat-empty">
                <p className="chat-empty-title">No conversation selected</p>
                <p className="chat-empty-body">Start a new chat or pick a thread from the rail.</p>
              </div>
            ))
          )}
          <Composer
            backend={backend}
            disabled={composerDisabled}
            disabledReason={composerDisabledReason}
            streaming={streaming}
            busy={composerBusy}
            onSend={onSendMessage}
            onStop={onStopStreaming}
          />
        </div>
      </div>
    </div>
  );
}
