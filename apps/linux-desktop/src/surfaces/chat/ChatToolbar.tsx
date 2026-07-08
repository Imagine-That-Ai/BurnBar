import { BackendStrip } from './BackendStrip.js';
import type { SessionEntry } from '../../tauriBridge.js';
import type { ChatBackendId } from './chatTypes.js';

type ChatToolbarProps = {
  thread: SessionEntry | null;
  gatewayHint: string | null;
  backend: ChatBackendId;
  modelLabel: string;
  onBackendChange: (id: ChatBackendId) => void;
  onNewChat: () => void;
  compact?: boolean;
};

export function ChatToolbar({
  thread,
  gatewayHint,
  backend,
  modelLabel,
  onBackendChange,
  onNewChat,
  compact = false
}: ChatToolbarProps) {
  return (
    <header className="chat-toolbar" role="toolbar" aria-label="Chat controls">
      <div className="chat-toolbar-primary">
        <BackendStrip
          backend={backend}
          modelLabel={modelLabel}
          thread={thread}
          gatewayHint={gatewayHint}
          onBackendChange={onBackendChange}
        />
      </div>
      <div className="chat-toolbar-actions">
        <button type="button" className="ghost chat-toolbar-text-button" onClick={onNewChat} aria-label="New chat">
          New chat
        </button>
        <button type="button" className="ghost chat-toolbar-icon" disabled title="Chat options (v1)" aria-label="Chat options">
          <span aria-hidden="true">⋯</span>
        </button>
        {!compact ? (
          <>
            <button
              type="button"
              className="ghost chat-toolbar-icon"
              disabled
              title="Pop out chat (not on Linux v1)"
              aria-label="Pop out chat"
            >
              <span aria-hidden="true">⧉</span>
            </button>
            <button
              type="button"
              className="ghost chat-toolbar-icon"
              disabled
              title="Restore floating window (macOS only)"
              aria-label="Restore floating window"
            >
              <span aria-hidden="true">▣</span>
            </button>
            <button
              type="button"
              className="ghost chat-toolbar-icon"
              disabled
              title="Close chat workspace (embedded only on macOS)"
              aria-label="Close chat"
            >
              <span aria-hidden="true">✕</span>
            </button>
          </>
        ) : null}
      </div>
    </header>
  );
}