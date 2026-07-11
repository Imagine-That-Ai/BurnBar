import type { ReactNode } from 'react';
import type { SessionEntry } from '../../tauriBridge.js';
import type { ChatBackendId } from './chatTypes.js';
import { ChatToolbar } from './ChatToolbar.js';
import { Composer } from './Composer.js';
import { MessageStream } from './MessageStream.js';
import { ThreadRail } from './ThreadRail.js';
import type { ChatWarningBanner } from './chatTypes.js';
import type { ChatMessage } from '../../state/chatStore.js';

export type ChatWorkspacePanelProps = {
  threads: SessionEntry[];
  selectedId: string | null;
  railLoading: boolean;
  query: string;
  hasMore: boolean;
  onSelect: (id: string) => void;
  onSearch: (query: string) => void;
  onLoadMore: () => void;
  onNewChat: () => void;
  selectedThread: SessionEntry | null;
  gatewayHint: string | null;
  backend: ChatBackendId;
  modelLabel: string;
  onBackendChange: (id: ChatBackendId) => void;
  messages: ChatMessage[];
  messagesLoading: boolean;
  warnings: ChatWarningBanner[];
  sharedFeaturesAvailable: boolean;
  streaming: boolean;
  streamError: string | null;
  composerDisabled: boolean;
  composerDisabledReason: string;
  onSendMessage: (text: string) => void;
  onStopStreaming: () => void;
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
  messages,
  messagesLoading,
  warnings,
  sharedFeaturesAvailable,
  streaming,
  streamError,
  composerDisabled,
  composerDisabledReason,
  onSendMessage,
  onStopStreaming,
  mainFallback
}: ChatWorkspacePanelProps) {
  const hasActiveTranscript = Boolean(selectedThread) || messages.length > 0 || streaming;

  return (
    <>
      <ChatToolbar
        thread={selectedThread}
        gatewayHint={gatewayHint}
        backend={backend}
        modelLabel={modelLabel}
        onBackendChange={onBackendChange}
        onNewChat={onNewChat}
      />
      <div className="chat-workspace">
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
              warnings={warnings}
              sharedFeaturesAvailable={sharedFeaturesAvailable}
              streamError={streamError}
              streaming={streaming}
            />
          ) : (
            (mainFallback ?? <p className="chat-empty">Select a thread from the rail.</p>)
          )}
          <Composer
            backend={backend}
            disabled={composerDisabled}
            disabledReason={composerDisabledReason}
            streaming={streaming}
            onSend={onSendMessage}
            onStop={onStopStreaming}
          />
        </div>
      </div>
    </>
  );
}
