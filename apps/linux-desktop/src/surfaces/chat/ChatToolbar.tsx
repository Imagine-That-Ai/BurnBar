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
  compact: _compact = false
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
        <button
          type="button"
          className="ghost chat-toolbar-text-button"
          onClick={onNewChat}
          aria-label="New chat"
          title="New chat"
        >
          ✎ New
        </button>
        <button
          type="button"
          className="ghost chat-toolbar-icon"
          disabled
          title="Chat options (v1)"
          aria-label="Chat options"
        >
          <span aria-hidden="true">⋯</span>
        </button>
        {/* Floating HUD controls (pop-out / restore / close) are macOS-only. */}
      </div>
    </header>
  );
}