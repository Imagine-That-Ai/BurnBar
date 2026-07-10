import type { ChatThreadSummary } from '../../tauriBridge.js';
import { CHAT_BACKENDS, type ChatBackendId } from './chatTypes.js';

const BACKEND_LOGOS: Record<ChatBackendId, string | null> = {
  hermes: '/provider-logos/hermes.png',
  codex: '/provider-logos/codex.png',
  claude: '/provider-logos/claude-code.png',
  'pi-agent': '/provider-logos/openburnbar.png',
  cli: null
};

type BackendStripProps = {
  backend: ChatBackendId;
  modelLabel: string;
  thread: ChatThreadSummary | null;
  gatewayHint: string | null;
  onBackendChange: (id: ChatBackendId) => void;
};

export function BackendStrip({
  backend,
  modelLabel,
  thread: _thread,
  gatewayHint: _gatewayHint,
  onBackendChange
}: BackendStripProps) {
  return (
    <div className="chat-backend-strip" role="group" aria-label="Chat engine and model">
      <div className="chat-backend-pills" role="toolbar" aria-label="Chat backends">
        {CHAT_BACKENDS.map((entry) => {
          const logo = BACKEND_LOGOS[entry.id];
          const active = entry.id === backend;
          return (
            <button
              key={entry.id}
              type="button"
              data-backend={entry.id}
              className={active ? 'chat-backend-pill is-active' : 'chat-backend-pill'}
              aria-pressed={active}
              aria-label={entry.label}
              title={entry.label}
              onClick={() => onBackendChange(entry.id)}
            >
              {logo ? <img src={logo} alt="" width={16} height={16} /> : null}
              <span className="chat-backend-pill-label">{entry.label}</span>
            </button>
          );
        })}
      </div>
      <div className="chat-toolbar-model" aria-label="Model selection">
        <span className="chat-toolbar-model-label">Model</span>
        <button
          type="button"
          className="chat-toolbar-model-button"
          disabled
          title="Model menu ships with live Hermes dispatch"
        >
          {modelLabel}
        </button>
      </div>
      <div className="chat-toolbar-engine-extras" aria-label="Agent and CLI">
        <button
          type="button"
          className="chat-toolbar-chip"
          disabled
          title="Agent desktop control (macOS parity)"
        >
          Agent
        </button>
        <button
          type="button"
          className="chat-toolbar-chip"
          disabled={backend !== 'cli'}
          title="CLI assistant consent flow"
        >
          CLI
        </button>
      </div>
    </div>
  );
}
