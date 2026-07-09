import type { ChatMessage } from '../../state/chatStore.js';
import { GlassAlert, GlassAlertStack } from '../../components/GlassAlert.js';
import type { ChatWarningBanner } from './chatTypes.js';

function WarningBanners({
  warnings,
  sharedFeaturesAvailable
}: {
  warnings: ChatWarningBanner[];
  sharedFeaturesAvailable: boolean;
}) {
  const showSharedFallback =
    !sharedFeaturesAvailable && !warnings.some((w) => w.id === 'cloud-shared');
  if (warnings.length === 0 && !showSharedFallback) return null;
  return (
    <GlassAlertStack inline className="chat-warning-stack">
      {warnings.map((w) => (
        <GlassAlert
          key={w.id}
          severity="warning"
          title={w.title}
          description={w.message}
          role="status"
        />
      ))}
      {showSharedFallback ? (
        <GlassAlert
          severity="warning"
          title="Cloud / shared unavailable"
          description="Shared memory and cross-device sync are degraded in this shell session."
          role="status"
        />
      ) : null}
    </GlassAlertStack>
  );
}

function MemoryCitations({ citations }: { citations: { id: string; label: string }[] }) {
  if (!citations.length) return null;
  return (
    <div className="chat-memory-citations" role="list" aria-label="Memory citations">
      {citations.map((c) => (
        <button
          key={c.id}
          type="button"
          className="chat-memory-citation"
          role="listitem"
          disabled
          title="Citation jump ships with live memory bridge"
        >
          {c.label}
        </button>
      ))}
    </div>
  );
}

function ToolCard({ message }: { message: ChatMessage }) {
  const state = message.toolState ?? 'proposed';
  return (
    <div
      className={state === 'running' ? 'chat-tool-card is-running' : 'chat-tool-card'}
      role="group"
      aria-label={`Tool ${message.toolName ?? 'call'}`}
    >
      <div className="chat-tool-card-header">
        <span>{message.toolName ?? 'tool'}</span>
        <span className="chat-tool-card-badge">{state}</span>
      </div>
      <p className="muted chat-tool-card-body">{message.text}</p>
      {state === 'proposed' ? (
        <div className="chat-tool-card-actions">
          <button
            type="button"
            className="primary"
            disabled
            title="Approval flows ride agent runs, not gateway chat."
          >
            Approve
          </button>
          <button
            type="button"
            className="ghost"
            disabled
            title="Approval flows ride agent runs, not gateway chat."
          >
            Deny
          </button>
        </div>
      ) : null}
    </div>
  );
}

function ThinkingBlock({ message }: { message: ChatMessage }) {
  return (
    <details className="chat-thinking">
      <summary>Reasoning</summary>
      <div className="chat-thinking-body">{message.text}</div>
    </details>
  );
}

function MercuryIdle() {
  return (
    <div className="chat-mercury-idle" aria-label="Hermes is thinking" role="status">
      <span className="chat-mercury-dot" aria-hidden="true" />
      <span className="chat-mercury-dot" aria-hidden="true" />
      <span className="chat-mercury-dot" aria-hidden="true" />
    </div>
  );
}

function assistantLogoSrc(message: ChatMessage): string | null {
  // Hermes route always uses the Hermes mark (including via-Hermes gateway turns).
  if (message.viaHermes) return '/provider-logos/hermes.png';

  const provider = message.provider?.toLowerCase() ?? '';
  if (provider.includes('hermes') || provider.includes('openclaw')) {
    return '/provider-logos/hermes.png';
  }
  if (provider.includes('codex') || provider.includes('openai')) {
    return '/provider-logos/codex.png';
  }
  if (provider.includes('claude') || provider.includes('anthropic')) {
    return '/provider-logos/claude-code.png';
  }
  if (provider.includes('cursor')) return '/provider-logos/cursor.png';
  if (provider.includes('factory') || provider.includes('droid')) {
    return '/provider-logos/factory.png';
  }
  // Unknown / missing provider: no logo — never impersonate Hermes.
  return null;
}

type MessageStreamProps = {
  messages: ChatMessage[];
  loading: boolean;
  warnings: ChatWarningBanner[];
  sharedFeaturesAvailable: boolean;
  streamError: string | null;
  streaming?: boolean;
};

export function MessageStream({
  messages,
  loading,
  warnings,
  sharedFeaturesAvailable,
  streamError,
  streaming = false
}: MessageStreamProps) {
  if (loading) {
    return (
      <div className="chat-stream-loading" aria-busy="true">
        Loading messages…
      </div>
    );
  }

  const last = messages[messages.length - 1];
  const showMercuryIdle =
    streaming &&
    (!last || last.role !== 'assistant' || (last.role === 'assistant' && !last.text.trim()));

  return (
    <div className="chat-stream" role="log" aria-live="polite" aria-relevant="additions">
      <div className="chat-stream-column">
        <WarningBanners warnings={warnings} sharedFeaturesAvailable={sharedFeaturesAvailable} />
        {streamError ? (
          <div className="chat-warning-banner" role="alert">
            <span className="chat-warning-icon" aria-hidden="true">
              !
            </span>
            <div>
              <p className="chat-warning-title">Chat stream stopped</p>
              <p className="chat-warning-message">{streamError}</p>
            </div>
          </div>
        ) : null}
        {messages.map((m) => {
          if (m.role === 'tool') return <ToolCard key={m.id} message={m} />;
          if (m.role === 'thinking') return <ThinkingBlock key={m.id} message={m} />;

          if (m.role === 'user') {
            return (
              <div key={m.id} className="chat-bubble-row chat-bubble-row--user">
                <article className="chat-bubble chat-bubble--user">
                  <p className="chat-bubble-text">{m.text}</p>
                </article>
              </div>
            );
          }

          const logo = assistantLogoSrc(m);
          const hermesClass = m.viaHermes ? ' chat-bubble--hermes' : '';
          return (
            <div key={m.id} className="chat-bubble-row chat-bubble-row--assistant">
              {logo ? (
                <img className="chat-bubble-logo" src={logo} alt="" width={24} height={24} />
              ) : null}
              <article className={`chat-bubble chat-bubble--assistant${hermesClass}`}>
                {m.viaHermes ? <span className="chat-via-badge">via Hermes</span> : null}
                <p className="chat-bubble-text">{m.text}</p>
                <MemoryCitations citations={m.memoryCitations ?? []} />
              </article>
            </div>
          );
        })}
        {showMercuryIdle ? <MercuryIdle /> : null}
      </div>
    </div>
  );
}
