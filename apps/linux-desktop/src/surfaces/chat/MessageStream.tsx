import type { ChatMessage } from '../../state/chatStore.js';
import { GlassAlert, GlassAlertStack } from '../../components/GlassAlert.js';
import { RichContent } from '../../richContent/RichContent.js';
import {
  openHermesAtom,
  openRichContentExternalURL
} from '../../richContent/richContentNavigation.js';
import {
  citationAffordance,
  normalizeMemoryCitations,
  type ChatApprovalDecision,
  type ChatWarningBanner,
  type MemoryCitation
} from './chatTypes.js';

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

function MemoryCitations({
  citations,
  onOpenCitation
}: {
  citations: MemoryCitation[];
  onOpenCitation?: (citation: MemoryCitation) => void;
}) {
  const normalized = normalizeMemoryCitations(citations);
  if (!normalized.length) return null;
  const canonical = normalized.find((citation) => citationAffordance(citation) === 'jump-local') ?? normalized[0];
  const extraCount = Math.max(0, normalized.length - 1);
  const affordance = citationAffordance(canonical);
  const canOpen = affordance === 'jump-local' && Boolean(onOpenCitation);
  const label =
    affordance === 'jump-local'
      ? `Source message${extraCount ? ` +${extraCount} more` : ''}`
      : affordance === 'cross-device'
        ? `Source on another device${extraCount ? ` +${extraCount} more` : ''}`
        : `Source no longer available${extraCount ? ` +${extraCount} more` : ''}`;
  return (
    <ul className="chat-memory-citations" aria-label="Memory citations">
      <li key={canonical.id}>
        {canOpen ? (
          <button
            type="button"
            className="chat-memory-citation"
            onClick={() => onOpenCitation?.(canonical)}
            aria-label={`Open ${label}`}
            title="Open the cited source message"
            data-citation-id={canonical.id}
          >
            {label}
          </button>
        ) : (
          <span
            className="chat-memory-citation is-unavailable"
            role="status"
            aria-label={label}
            title={label}
            data-citation-id={canonical.id}
          >
            {label}
          </span>
        )}
      </li>
    </ul>
  );
}

function ToolCard({
  message,
  onOpenMissionControl,
  onToolApproval,
  onRetryToolApproval
}: {
  message: ChatMessage;
  onOpenMissionControl?: () => void;
  onToolApproval?: (messageID: string, decision: ChatApprovalDecision) => void;
  onRetryToolApproval?: (messageID: string) => void;
}) {
  const state = message.toolState ?? 'proposed';
  const approval = message.toolApproval;
  const gatewayApprovalUnavailable = approval?.state === 'unavailable';
  const daemonApprovalAvailable =
    approval && approval.state !== 'unavailable' &&
    ['pending', 'available', 'error'].includes(approval.state) &&
    Boolean(approval.approvalID.trim());
  const submitting = approval?.state === 'submitting';
  const terminal = approval?.state === 'approved' || approval?.state === 'rejected' || approval?.state === 'cancelled';
  return (
    <div
      className={`${state === 'running' ? 'chat-tool-card is-running' : 'chat-tool-card'}${approval?.state === 'error' ? ' is-error' : ''}`}
      role="group"
      aria-label={`Tool ${message.toolName ?? 'call'}`}
      aria-busy={submitting}
    >
      <div className="chat-tool-card-header">
        <span>{message.toolName ?? 'tool'}</span>
        <span className="chat-tool-card-badge">{approval?.state === 'pending' || approval?.state === 'available' ? 'pending' : approval?.state ?? state}</span>
      </div>
      <p className="muted chat-tool-card-body">{message.text}</p>
      {gatewayApprovalUnavailable ? (
        <div className="chat-tool-card-availability" aria-label="Tool approval availability">
          <p className="chat-tool-card-capability" role="status">
            Gateway chat does not expose the daemon run approval identity required to approve this tool call.
          </p>
          {onOpenMissionControl ? (
            <button type="button" className="ghost" onClick={onOpenMissionControl}>
              Open Mission Control
            </button>
          ) : null}
          </div>
      ) : daemonApprovalAvailable && approval?.state !== 'error' && !terminal ? (
        <div className="chat-tool-card-actions">
          <button
            type="button"
            className="primary"
            disabled={submitting}
            onClick={() => onToolApproval?.(message.id, 'approve')}
            aria-busy={submitting}
          >
            Approve
          </button>
          <button
            type="button"
            className="ghost"
            disabled={submitting}
            onClick={() => onToolApproval?.(message.id, 'reject')}
          >
            Reject
          </button>
          <button
            type="button"
            className="ghost"
            disabled={submitting}
            onClick={() => onToolApproval?.(message.id, 'cancel')}
          >
            Cancel
          </button>
        </div>
      ) : approval?.state === 'error' ? (
        <div className="chat-tool-card-approval-error" role="alert">
          <p>{approval.error || 'The daemon did not resolve this approval.'}</p>
          {approval.lastDecision && onRetryToolApproval ? (
            <button type="button" className="ghost" onClick={() => onRetryToolApproval(message.id)}>
              Retry {approval.lastDecision}
            </button>
          ) : null}
        </div>
      ) : null}
      {terminal ? (
        <p className="chat-tool-card-approval-status" role="status">
          Approval {approval.state === 'approved' ? 'accepted' : approval.state === 'rejected' ? 'rejected' : 'cancelled'} by the daemon.
        </p>
      ) : null}
    </div>
  );
}

function ThinkingBlock({ message }: { message: ChatMessage }) {
  return (
    <details className="chat-thinking">
      <summary>Reasoning</summary>
      <RichContent
        className="chat-thinking-body"
        text={message.text}
        label="Reasoning content"
        onOpenAtom={openHermesAtom}
        onOpenExternal={openRichContentExternalURL}
      />
    </details>
  );
}

function AttachmentSummary({ message }: { message: ChatMessage }) {
  const attachments = message.attachments ?? [];
  if (attachments.length === 0) return null;
  return (
    <ul className="chat-attachment-summary" aria-label="Message attachments">
      {attachments.map((attachment) => (
        <li key={attachment.attachmentId}>
          <span aria-hidden="true">+</span>
          <span>{attachment.fileName}</span>
          <span className="muted">{(attachment.byteSize / 1024).toFixed(1)} KB</span>
        </li>
      ))}
    </ul>
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
  if (provider.includes('pi') || provider === 'pi-agent') {
    return '/provider-logos/openburnbar.png';
  }
  // Unknown / missing provider: no logo — never impersonate Hermes.
  return null;
}

type MessageStreamProps = {
  messages: ChatMessage[];
  loading: boolean;
  hasMoreBefore?: boolean;
  loadingOlderMessages?: boolean;
  loadingAllMessages?: boolean;
  totalMessageCount?: number;
  onLoadOlder?: () => void;
  onLoadAll?: () => void;
  warnings: ChatWarningBanner[];
  sharedFeaturesAvailable: boolean;
  streamError: string | null;
  historyError?: string | null;
  streaming?: boolean;
  onOpenMissionControl?: () => void;
  onOpenCitation?: (citation: MemoryCitation) => void;
  onToolApproval?: (messageID: string, decision: ChatApprovalDecision) => void;
  onRetryToolApproval?: (messageID: string) => void;
};

export function MessageStream({
  messages,
  loading,
  hasMoreBefore = false,
  loadingOlderMessages = false,
  loadingAllMessages = false,
  totalMessageCount,
  onLoadOlder,
  onLoadAll,
  warnings,
  sharedFeaturesAvailable,
  streamError,
  historyError = null,
  streaming = false,
  onOpenMissionControl,
  onOpenCitation,
  onToolApproval,
  onRetryToolApproval
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
        {hasMoreBefore && onLoadOlder ? (
          <div className="chat-load-older">
            <button
              type="button"
              className="ghost"
              onClick={onLoadOlder}
              disabled={loadingOlderMessages || loadingAllMessages}
              aria-busy={loadingOlderMessages || loadingAllMessages}
            >
              {loadingOlderMessages ? 'Loading earlier messages…' : 'Load earlier messages'}
            </button>
            {onLoadAll && (totalMessageCount === undefined || messages.length < totalMessageCount) ? (
              <button
                type="button"
                className="ghost"
                onClick={onLoadAll}
                disabled={loadingOlderMessages || loadingAllMessages}
                aria-busy={loadingAllMessages}
              >
                {loadingAllMessages ? 'Loading complete history…' : 'Load all earlier messages'}
              </button>
            ) : null}
          </div>
        ) : null}
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
        {historyError ? (
          <div className="chat-warning-banner" role="alert">
            <span className="chat-warning-icon" aria-hidden="true">
              !
            </span>
            <div>
              <p className="chat-warning-title">Chat history unavailable</p>
              <p className="chat-warning-message">{historyError}</p>
            </div>
          </div>
        ) : null}
        {messages.map((m) => {
          if (m.role === 'tool') {
            return (
              <ToolCard
                key={m.id}
                message={m}
                onOpenMissionControl={onOpenMissionControl}
                onToolApproval={onToolApproval}
                onRetryToolApproval={onRetryToolApproval}
              />
            );
          }
          if (m.role === 'thinking') return <ThinkingBlock key={m.id} message={m} />;

          if (m.role === 'system') {
            return (
              <div key={m.id} className="chat-system-message" role="note" aria-label="System message">
                <RichContent text={m.text} preservePlainText expanded />
              </div>
            );
          }

          if (m.role === 'user') {
            return (
              <div key={m.id} className="chat-bubble-row chat-bubble-row--user">
                <article className="chat-bubble chat-bubble--user" data-chat-message-id={m.id}>
                  <RichContent
                    className="chat-bubble-text"
                    text={m.text}
                    preservePlainText
                    label="Your message"
                  />
                  <AttachmentSummary message={m} />
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
              <article
                className={`chat-bubble chat-bubble--assistant${hermesClass}`}
                data-chat-message-id={m.id}
              >
                {m.viaHermes ? <span className="chat-via-badge">via Hermes</span> : null}
                <RichContent
                  className="chat-bubble-text"
                  text={m.text}
                  label="Assistant message"
                  onOpenAtom={openHermesAtom}
                  onOpenExternal={openRichContentExternalURL}
                />
                <MemoryCitations citations={m.memoryCitations ?? []} onOpenCitation={onOpenCitation} />
              </article>
            </div>
          );
        })}
        {showMercuryIdle ? <MercuryIdle /> : null}
      </div>
    </div>
  );
}
