import type { ChatThreadSummary } from '../../tauriBridge.js';

export type ChatBackendId = 'hermes' | 'codex' | 'claude' | 'pi-agent' | 'cli';

export const CHAT_BACKENDS: { id: ChatBackendId; label: string }[] = [
  { id: 'hermes', label: 'Hermes' },
  { id: 'codex', label: 'Codex' },
  { id: 'claude', label: 'Claude Code' },
  { id: 'pi-agent', label: 'Pi' },
  { id: 'cli', label: 'CLI' }
];

export type ChatWarningBanner = {
  id: string;
  title: string;
  message: string;
};

export type ChatApprovalDecision = 'approve' | 'reject' | 'cancel';

export type ChatToolApprovalState =
  | 'pending'
  | 'available'
  | 'submitting'
  | 'approved'
  | 'rejected'
  | 'cancelled'
  | 'error';

/**
 * Approval capabilities are transport-specific. Gateway tool-call frames do
 * not include the daemon run/approval identity required by `approval.respond`;
 * keep that boundary explicit instead of making a card appear actionable.
 */
export type ChatToolApprovalCapability =
  | {
      state: 'unavailable';
      source: 'gateway';
      reason: 'gateway-tool-call-missing-run-approval-identity';
      fallbackRoute: 'missions';
    }
  | {
      state: ChatToolApprovalState;
      source: 'daemon-run';
      approvalID: string;
      lastDecision?: ChatApprovalDecision;
      error?: string;
    };

export type MemoryCitationState = 'live' | 'cross-device' | 'source-unavailable';

export type MemoryCitation = {
  id: string;
  label: string;
  messageId?: string;
  threadID?: string;
  state?: MemoryCitationState;
};

export const CHAT_CITATION_MAX_COUNT = 8;
export const CHAT_CITATION_ID_MAX_BYTES = 256;
export const CHAT_CITATION_LABEL_MAX_BYTES = 160;

const SAFE_CITATION_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$/;

function boundedCitationText(value: string, maxBytes: number): string | null {
  const trimmed = value.trim();
  if (!trimmed || trimmed.includes('\u0000') || /[\u0000-\u001f\u007f]/.test(trimmed)) return null;
  if (new TextEncoder().encode(trimmed).length > maxBytes) return null;
  return trimmed;
}

function safeCitationID(value: string | undefined): string | undefined {
  const bounded = value === undefined ? undefined : boundedCitationText(value, CHAT_CITATION_ID_MAX_BYTES);
  if (!bounded) return undefined;
  return SAFE_CITATION_ID.test(bounded) ? bounded : undefined;
}

/**
 * Normalize renderer-owned citation metadata before it reaches the DOM.
 * Citations are provenance references, not source bodies; invalid references
 * are dropped rather than rendered as dead or attacker-controlled links.
 */
export function normalizeMemoryCitations(citations: readonly MemoryCitation[] | undefined): MemoryCitation[] {
  if (!citations?.length) return [];
  const seen = new Set<string>();
  const normalized: MemoryCitation[] = [];
  for (const citation of citations) {
    if (normalized.length >= CHAT_CITATION_MAX_COUNT) break;
    const id = safeCitationID(citation.id);
    const label = boundedCitationText(citation.label, CHAT_CITATION_LABEL_MAX_BYTES);
    if (!id || !label || seen.has(id)) continue;
    const messageId = safeCitationID(citation.messageId);
    const threadID = safeCitationID(citation.threadID);
    const state = citation.state ?? 'live';
    if (state !== 'live' && state !== 'cross-device' && state !== 'source-unavailable') continue;
    seen.add(id);
    normalized.push({ id, label, messageId, threadID, state });
  }
  return normalized;
}

export type ChatCitationAffordance = 'jump-local' | 'cross-device' | 'source-unavailable';

export function citationAffordance(citation: MemoryCitation): ChatCitationAffordance {
  if (citation.state === 'source-unavailable') return 'source-unavailable';
  if (citation.state === 'cross-device' || !safeCitationID(citation.messageId)) return 'cross-device';
  return 'jump-local';
}

export function canOpenChatCitation(
  citation: MemoryCitation,
  selectedThreadID: string | null,
  availableThreadIDs?: readonly string[]
): boolean {
  const normalized = normalizeMemoryCitations([citation])[0];
  if (!normalized || citationAffordance(normalized) !== 'jump-local') return false;
  const targetThreadID = normalized.threadID;
  if (!targetThreadID || targetThreadID === selectedThreadID) return true;
  return Boolean(availableThreadIDs?.includes(targetThreadID));
}

export function threadPreview(thread: ChatThreadSummary): string {
  return thread.preview || 'No messages yet';
}

export function threadMessageCount(thread: ChatThreadSummary): number {
  return thread.messageCount;
}

export function formatThreadActivity(startedAt: string): string {
  const d = new Date(startedAt);
  if (Number.isNaN(d.getTime())) return startedAt;
  return d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

export function composerPlaceholder(backend: ChatBackendId): string {
  switch (backend) {
    case 'codex':
      return 'Ask Codex…';
    case 'claude':
      return 'Ask Claude Code…';
    case 'pi-agent':
      return 'Ask Pi…';
    case 'cli':
      return 'Ask CLI…';
    default:
      return 'Ask Hermes…';
  }
}
