import { BackendStrip } from './BackendStrip.js';
import type { ChatThreadSummary } from '../../tauriBridge.js';
import type { ChatBackendId } from './chatTypes.js';
import type { ChatExportFormat } from './chatExport.js';

type ChatToolbarProps = {
  thread: ChatThreadSummary | null;
  gatewayHint: string | null;
  backend: ChatBackendId;
  modelLabel: string;
  onBackendChange: (id: ChatBackendId) => void;
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
  onBackendChange,
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
          thread={thread}
          gatewayHint={gatewayHint}
          onBackendChange={onBackendChange}
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
    </div>
  );
}
