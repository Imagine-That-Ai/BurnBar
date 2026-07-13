import { BackendStrip } from './BackendStrip.js';
import type { ChatThreadSummary, ConfigSnapshot } from '../../tauriBridge.js';
import type { ChatBackendId } from './chatTypes.js';
import type { ChatExportFormat } from './chatExport.js';
import type { ChatThinkingSelection } from './chatOptions.js';

type ChatToolbarProps = {
  thread: ChatThreadSummary | null;
  gatewayHint: string | null;
  backend: ChatBackendId;
  modelLabel: string;
  modelOptionID: string;
  thinkingLevel: ChatThinkingSelection;
  config: ConfigSnapshot | null;
  onBackendChange: (id: ChatBackendId) => void;
  onModelOptionChange: (id: string) => void;
  onThinkingLevelChange: (level: ChatThinkingSelection) => void;
  onReconnect: () => void;
  onPopOut?: () => void;
  onClosePopOut?: () => void;
  popoutWindow: boolean;
  popoutStatus?: string | null;
  onNewChat: () => void;
  exportFormat: ChatExportFormat;
  onExportFormatChange: (format: ChatExportFormat) => void;
  onExport: () => void;
  exportDisabled: boolean;
  exportStatus: string | null;
  compact?: boolean;
};

export function ChatToolbar({
  thread,
  gatewayHint,
  backend,
  modelLabel,
  modelOptionID,
  thinkingLevel,
  config,
  onBackendChange,
  onModelOptionChange,
  onThinkingLevelChange,
  onReconnect,
  onPopOut,
  onClosePopOut,
  popoutWindow,
  popoutStatus,
  onNewChat,
  exportFormat,
  onExportFormatChange,
  onExport,
  exportDisabled,
  exportStatus,
  compact: _compact = false
}: ChatToolbarProps) {
  return (
    <div className="chat-toolbar" role="toolbar" aria-label="Chat controls">
      <div className="chat-toolbar-primary">
        <BackendStrip
          backend={backend}
          modelLabel={modelLabel}
          modelOptionID={modelOptionID}
          thinkingLevel={thinkingLevel}
          config={config}
          thread={thread}
          gatewayHint={gatewayHint}
          onBackendChange={onBackendChange}
          onModelOptionChange={onModelOptionChange}
          onThinkingLevelChange={onThinkingLevelChange}
        />
      </div>
      <div className="chat-toolbar-actions">
        <div className="chat-export-control" role="group" aria-label="Chat export">
          <span className="sr-only">Chat export format</span>
          <select
            value={exportFormat}
            onChange={(event) => onExportFormatChange(event.target.value as ChatExportFormat)}
            aria-label="Chat export format"
            disabled={exportDisabled}
          >
            <option value="json">JSON</option>
            <option value="markdown">Markdown</option>
          </select>
          <button
            type="button"
            className="ghost chat-toolbar-icon"
            onClick={onExport}
            disabled={exportDisabled}
            title={exportDisabled ? 'Select a loaded thread to export' : `Export chat as ${exportFormat === 'json' ? 'JSON' : 'Markdown'}`}
            aria-label={`Export chat as ${exportFormat === 'json' ? 'JSON' : 'Markdown'}`}
          >
            <span aria-hidden="true">⇩</span>
          </button>
          {exportStatus ? (
            <span className="chat-export-status" role="status" aria-live="polite">
              {exportStatus}
            </span>
          ) : null}
        </div>
        <button
          type="button"
          className="ghost chat-toolbar-text-button"
          onClick={onNewChat}
          aria-label="New chat"
          title="New chat"
        >
          ✎ New
        </button>
        <details className="chat-options-control">
          <summary className="ghost chat-toolbar-icon" title="Chat options" aria-label="Chat options">
            <span aria-hidden="true">⋯</span>
          </summary>
          <div className="chat-options-menu" role="menu" aria-label="Chat options">
            <button type="button" role="menuitem" onClick={onReconnect}>
              Reconnect gateway
            </button>
            {onPopOut ? (
              <button type="button" role="menuitem" onClick={onPopOut}>
                Pop out chat
              </button>
            ) : null}
            {popoutWindow && onClosePopOut ? (
              <button type="button" role="menuitem" onClick={onClosePopOut}>
                Close chat window
              </button>
            ) : null}
            {popoutStatus ? <span className="chat-options-status" role="status">{popoutStatus}</span> : null}
          </div>
        </details>
      </div>
    </div>
  );
}
