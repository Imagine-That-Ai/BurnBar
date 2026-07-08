import type { SessionEntry } from '../../tauriBridge.js';
import { CHAT_BACKENDS, type ChatBackendId } from './chatTypes.js';

type BackendStripProps = {
  backend: ChatBackendId;
  modelLabel: string;
  thread: SessionEntry | null;
  gatewayHint: string | null;
  onBackendChange: (id: ChatBackendId) => void;
};

export function BackendStrip({ backend, modelLabel, thread, gatewayHint, onBackendChange }: BackendStripProps) {
  return (
    <div className="chat-backend-strip" role="group" aria-label="Chat engine and model">
      <div className="chat-backend-pills" role="toolbar" aria-label="Chat backends">
        {CHAT_BACKENDS.map((entry) => (
          <button
            key={entry.id}
            type="button"
            className={entry.id === backend ? 'chat-backend-pill is-active' : 'chat-backend-pill'}
            aria-pressed={entry.id === backend}
            onClick={() => onBackendChange(entry.id)}
          >
            {entry.label}
          </button>
        ))}
      </div>
      <div className="chat-toolbar-model" aria-label="Model selection">
        <span className="chat-toolbar-model-label">Model</span>
        <button type="button" className="chat-toolbar-model-button" disabled title="Model menu ships with live Hermes dispatch">
          {modelLabel}
        </button>
      </div>
      <div className="chat-toolbar-engine-extras" aria-label="Agent and CLI">
        <button type="button" className="chat-toolbar-chip" disabled title="Agent desktop control (macOS parity)">
          Agent
        </button>
        <button type="button" className="chat-toolbar-chip" disabled={backend !== 'cli'} title="CLI assistant consent flow">
          CLI
        </button>
        <button type="button" className="chat-toolbar-icon chat-toolbar-attach" disabled title="Attachments ship with live dispatch">
          <span aria-hidden="true">📎</span>
          <span className="sr-only">Attachments</span>
        </button>
      </div>
      {thread || gatewayHint ? (
        <p className="chat-backend-context muted">
          {thread ? `${thread.provider} / ${thread.model}` : 'No thread selected'}
          {gatewayHint ? ` · ${gatewayHint}` : ''}
        </p>
      ) : null}
    </div>
  );
}