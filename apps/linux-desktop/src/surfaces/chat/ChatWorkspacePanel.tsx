import type { ReactNode } from 'react';
import type { ChatThreadSummary, ProviderCatalog } from '../../tauriBridge.js';
import type { ChatApprovalDecision, ChatBackendId, MemoryCitation } from './chatTypes.js';
import { ChatToolbar } from './ChatToolbar.js';
import { Composer } from './Composer.js';
import type { PendingChatAttachment } from './Composer.js';
import { MessageStream } from './MessageStream.js';
import { ThreadRail } from './ThreadRail.js';
import type { ChatWarningBanner } from './chatTypes.js';
import type { ChatMessage } from '../../state/chatStore.js';
import type { ChatExportFormat } from './chatExport.js';
import type { ConfigSnapshot } from '../../tauriBridge.js';
import type { ChatThinkingSelection } from './chatOptions.js';

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
  modelOptionID: string;
  thinkingLevel: ChatThinkingSelection;
  config: ConfigSnapshot | null;
  catalog: ProviderCatalog | null;
  onBackendChange: (id: ChatBackendId) => void;
  onModelOptionChange: (id: string) => void;
  onThinkingLevelChange: (level: ChatThinkingSelection) => void;
  onReconnect: () => void;
  onResume: () => void;
  resumeDisabled: boolean;
  resumeStatus?: string | null;
  onPopOut?: () => void;
  onClosePopOut?: () => void;
  popoutWindow: boolean;
  popoutStatus?: string | null;
  exportFormat: ChatExportFormat;
  onExportFormatChange: (format: ChatExportFormat) => void;
  onExport: () => void;
  exportDisabled: boolean;
  exportBusy: boolean;
  exportStatus: string | null;
  messages: ChatMessage[];
  messagesLoading: boolean;
  hasMoreMessages: boolean;
  loadingOlderMessages: boolean;
  loadingAllMessages: boolean;
  historyError: string | null;
  totalMessageCount?: number;
  onLoadOlderMessages: () => void;
  onLoadAllMessages: () => void;
  warnings: ChatWarningBanner[];
  sharedFeaturesAvailable: boolean;
  streaming: boolean;
  streamError: string | null;
  composerDisabled: boolean;
  composerDisabledReason: string;
  /** True while a send is composing (persisting + probing) before streaming. */
  composerBusy: boolean;
  onSendMessage: (text: string, attachment?: PendingChatAttachment) => void | Promise<boolean | void>;
  onStopStreaming: () => void;
  onOpenMissionControl: () => void;
  onOpenCitation?: (citation: MemoryCitation) => void;
  onToolApproval?: (messageID: string, decision: ChatApprovalDecision) => void;
  onRetryToolApproval?: (messageID: string) => void;
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
  modelOptionID,
  thinkingLevel,
  config,
  catalog,
  onBackendChange,
  onModelOptionChange,
  onThinkingLevelChange,
  onReconnect,
  onResume,
  resumeDisabled,
  resumeStatus,
  onPopOut,
  onClosePopOut,
  popoutWindow,
  popoutStatus,
  exportFormat,
  onExportFormatChange,
  onExport,
  exportDisabled,
  exportBusy,
  exportStatus,
  messages,
  messagesLoading,
  hasMoreMessages,
  loadingOlderMessages,
  loadingAllMessages,
  historyError,
  totalMessageCount,
  onLoadOlderMessages,
  onLoadAllMessages,
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
  onOpenCitation,
  onToolApproval,
  onRetryToolApproval,
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
        modelOptionID={modelOptionID}
        thinkingLevel={thinkingLevel}
        config={config}
        catalog={catalog}
        onBackendChange={onBackendChange}
        onModelOptionChange={onModelOptionChange}
        onThinkingLevelChange={onThinkingLevelChange}
        onReconnect={onReconnect}
        onResume={onResume}
        resumeDisabled={resumeDisabled}
        resumeStatus={resumeStatus}
        onPopOut={onPopOut}
        onClosePopOut={onClosePopOut}
        popoutWindow={popoutWindow}
        popoutStatus={popoutStatus}
        onNewChat={onNewChat}
        exportFormat={exportFormat}
        onExportFormatChange={onExportFormatChange}
        onExport={onExport}
        exportDisabled={exportDisabled}
        exportBusy={exportBusy}
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
              loadingAllMessages={loadingAllMessages}
              totalMessageCount={totalMessageCount}
              onLoadOlder={onLoadOlderMessages}
              onLoadAll={onLoadAllMessages}
              warnings={warnings}
              sharedFeaturesAvailable={sharedFeaturesAvailable}
              streamError={streamError}
              historyError={historyError}
              streaming={streaming}
              onOpenMissionControl={onOpenMissionControl}
              onOpenCitation={onOpenCitation}
              onToolApproval={onToolApproval}
              onRetryToolApproval={onRetryToolApproval}
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
