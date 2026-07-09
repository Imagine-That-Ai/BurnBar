import type { ChatMessage } from '../../state/chatStore.js';
import { GlassAlert, GlassAlertStack } from '../../components/GlassAlert.js';
import type { ChatWarningBanner } from './chatTypes.js';

function WarningBanners({ warnings, sharedFeaturesAvailable }: { warnings: ChatWarningBanner[]; sharedFeaturesAvailable: boolean }) {
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
    <ul className="chat-memory-citations" aria-label="Memory citations">
      {citations.map((c) => (
        <li key={c.id}>
          <button type="button" className="chat-memory-citation" disabled title="Citation jump ships with live memory bridge">
            {c.label}
          </button>
        </li>
      ))}
    </ul>
  );
}

function ToolCard({ message }: { message: ChatMessage }) {
  const state = message.toolState ?? 'proposed';
  return (
    <div className="chat-tool-card" role="group" aria-label={`Tool ${message.toolName ?? 'call'}`}>
      <div className="chat-tool-card-header">
        <span>{message.toolName ?? 'tool'}</span>
        <span className="chat-tool-card-badge">{state}</span>
      </div>
      <p className="muted chat-tool-card-body">{message.text}</p>
      {state === 'proposed' ? (
        <div className="chat-tool-card-actions">
          <button type="button" className="primary" disabled title="Approval flows ride agent runs, not gateway chat.">
            Approve
          </button>
          <button type="button" className="ghost" disabled title="Approval flows ride agent runs, not gateway chat.">
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
      <summary>Thinking</summary>
      <div className="chat-thinking-body">{message.text}</div>
    </details>
  );
}

type MessageStreamProps = {
  messages: ChatMessage[];
  loading: boolean;
  warnings: ChatWarningBanner[];
  sharedFeaturesAvailable: boolean;
  streamError: string | null;
};

export function MessageStream({ messages, loading, warnings, sharedFeaturesAvailable, streamError }: MessageStreamProps) {
  if (loading) {
    return (
      <div className="chat-stream-loading" aria-busy="true">
        Loading messages…
      </div>
    );
  }

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
          const className =
            m.role === 'user' ? 'chat-bubble chat-bubble--user' : 'chat-bubble chat-bubble--assistant';
          return (
            <article key={m.id} className={className}>
              {m.role === 'assistant' && m.viaHermes ? (
                <span className="chat-via-badge">via Hermes</span>
              ) : null}
              <p className="chat-bubble-text">{m.text}</p>
              {m.role === 'assistant' ? <MemoryCitations citations={m.memoryCitations ?? []} /> : null}
            </article>
          );
        })}
      </div>
    </div>
  );
}
