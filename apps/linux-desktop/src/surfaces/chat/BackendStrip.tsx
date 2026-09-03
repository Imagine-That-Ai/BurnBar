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
  fx: '/provider-logos/fx.png',
  muse: '/provider-logos/meta.png',
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
  onThinkingLevelChange
}: BackendStripProps) {
  const options = chatModelOptions(config, backend, modelLabel);
  const thinkingLevels = chatThinkingLevels(options, modelOptionID, modelLabel);
  return (
    <div className="chat-backend-strip" role="group" aria-label="Chat engine and model">
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
      {backend !== 'cli' && chatBackendAvailability(config, backend, catalog).state !== 'available' ? (
        <p className="chat-backend-availability" aria-live="polite">
          {chatBackendAvailability(config, backend, catalog).reason}
        </p>
      ) : null}
      <div className="chat-toolbar-model" aria-label="Model selection">
        <label className="chat-toolbar-model-label" htmlFor="chat-model-select">Model</label>
        <select
          id="chat-model-select"
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
        <label className="chat-toolbar-model-label" htmlFor="chat-thinking-select">Thinking</label>
        <select
          id="chat-thinking-select"
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
