import type { ChatThreadSummary, ConfigSnapshot, ProviderCatalog } from '../../tauriBridge.js';
import {
  CHAT_BACKENDS,
  chatBackendAvailability,
  type ChatBackendId
} from './chatTypes.js';
import {
  chatModelOptions,
  chatThinkingLevels,
  thinkingLabel,
  type ChatThinkingSelection
} from './chatOptions.js';

const BACKEND_LOGOS: Record<ChatBackendId, string | null> = {
  hermes: '/provider-logos/hermes.png',
  codex: '/provider-logos/codex.png',
  claude: '/provider-logos/claude-code.png',
  'pi-agent': '/provider-logos/openburnbar.png',
  openclaw: '/provider-logos/openclaw.png',
  openclaude: '/provider-logos/claude-code.png',
  omp: null,
  droid: '/provider-logos/factory.png',
  forge: null,
  antigravity: '/provider-logos/antigravity.png',
  'cursor-agent': '/provider-logos/cursor.png',
  junie: null,
  cli: null
};

type BackendStripProps = {
  backend: ChatBackendId;
  modelLabel: string;
  modelOptionID: string;
  thinkingLevel: ChatThinkingSelection;
  config: ConfigSnapshot | null;
  catalog: ProviderCatalog | null;
  thread: ChatThreadSummary | null;
  gatewayHint: string | null;
  onBackendChange: (id: ChatBackendId) => void;
  onModelOptionChange: (id: string) => void;
  onThinkingLevelChange: (level: ChatThinkingSelection) => void;
  compact?: boolean;
  idPrefix?: string;
};

export function BackendStrip({
  backend,
  modelLabel,
  modelOptionID,
  thinkingLevel,
  config,
  catalog,
  thread: _thread,
  gatewayHint: _gatewayHint,
  onBackendChange,
  onModelOptionChange,
  onThinkingLevelChange,
  compact = false,
  idPrefix = 'chat'
}: BackendStripProps) {
  const options = chatModelOptions(config, backend, modelLabel);
  const thinkingLevels = chatThinkingLevels(options, modelOptionID, modelLabel);
  const backendAvailability = chatBackendAvailability(config, backend, catalog);
  const modelSelectID = `${idPrefix}-model-select`;
  const thinkingSelectID = `${idPrefix}-thinking-select`;
  const backendSelectID = `${idPrefix}-backend-select`;
  return (
    <div className={compact ? 'chat-backend-strip is-compact' : 'chat-backend-strip'} role="group" aria-label="Chat engine and model">
      {compact ? (
        <div className="chat-toolbar-model" aria-label="Backend selection">
          <label className="chat-toolbar-model-label" htmlFor={backendSelectID}>Agent</label>
          <select
            id={backendSelectID}
            className="chat-toolbar-model-button"
            value={backend}
            onChange={(event) => onBackendChange(event.target.value as ChatBackendId)}
            aria-label="Chat backend"
          >
            {CHAT_BACKENDS.map((entry) => {
              const availability = chatBackendAvailability(config, entry.id, catalog);
              const unavailable = availability.state !== 'available' && availability.state !== 'unknown';
              return (
                <option key={entry.id} value={entry.id} disabled={unavailable}>
                  {entry.label}
                </option>
              );
            })}
          </select>
        </div>
      ) : (
        <div className="chat-backend-pills" role="toolbar" aria-label="Chat backends">
          {CHAT_BACKENDS.map((entry) => {
            const logo = BACKEND_LOGOS[entry.id];
            const active = entry.id === backend;
            const availability = chatBackendAvailability(config, entry.id, catalog);
            const unavailable = availability.state !== 'available' && availability.state !== 'unknown';
            return (
              <button
                key={entry.id}
                type="button"
                data-backend={entry.id}
                className={active ? 'chat-backend-pill is-active' : 'chat-backend-pill'}
                aria-pressed={active}
                aria-label={entry.label}
                title={unavailable ? `${entry.label}: ${availability.reason}` : entry.label}
                disabled={unavailable}
                onClick={() => onBackendChange(entry.id)}
              >
                {logo ? <img src={logo} alt="" width={16} height={16} /> : null}
                <span className="chat-backend-pill-label">{entry.label}</span>
              </button>
            );
          })}
        </div>
      )}
      {backend !== 'cli' && backendAvailability.state !== 'available' ? (
        <p className="chat-backend-availability" aria-live="polite">
          {backendAvailability.reason}
        </p>
      ) : null}
      <div className="chat-toolbar-model" aria-label="Model selection">
        <label className="chat-toolbar-model-label" htmlFor={modelSelectID}>Model</label>
        <select
          id={modelSelectID}
          className="chat-toolbar-model-button"
          value={options.some((option) => option.id === modelOptionID) ? modelOptionID : options[0]?.id ?? ''}
          onChange={(event) => onModelOptionChange(event.target.value)}
          disabled={options.length === 0}
          aria-label="Chat model"
        >
          {options.map((option) => (
            <option key={option.id} value={option.id}>
              {option.label}
            </option>
          ))}
        </select>
        <label className="chat-toolbar-model-label" htmlFor={thinkingSelectID}>Thinking</label>
        <select
          id={thinkingSelectID}
          className="chat-toolbar-model-button"
          value={thinkingLevel}
          onChange={(event) => onThinkingLevelChange(event.target.value as ChatThinkingSelection)}
          disabled={thinkingLevels.length === 0}
          aria-label="Thinking level"
        >
          <option value="default">Default</option>
          {thinkingLevels.map((level) => (
            <option key={level} value={level}>
              {thinkingLabel(level)}
            </option>
          ))}
        </select>
      </div>
      {!compact ? (
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
      ) : null}
    </div>
  );
}
