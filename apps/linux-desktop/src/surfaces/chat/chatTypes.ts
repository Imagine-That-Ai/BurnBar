import type {
  ChatThreadSummary,
  ConfigSnapshot,
  ProviderCatalog,
  ProviderCatalogEntry,
  ProviderCredentialSlot
} from '../../tauriBridge.js';

/**
 * Mirrors macOS ChatBackendID. `cli` remains a legacy read-only compatibility
 * token for old persisted threads; it is intentionally never advertised as a
 * selectable Linux backend.
 */
export type ChatBackendId =
  | 'hermes'
  | 'codex'
  | 'claude'
  | 'pi-agent'
  | 'openclaw'
  | 'openclaude'
  | 'omp'
  | 'droid'
  | 'forge'
  | 'antigravity'
  | 'cursor-agent'
  | 'junie'
  | 'fx'
  | 'muse'
  | 'cli';

export type ChatBackendAvailability = 'available' | 'unconfigured' | 'disabled' | 'unknown' | 'unsupported';

export type ChatBackendDescriptor = {
  id: ChatBackendId;
  label: string;
  providerIDs: readonly string[];
};

export const CHAT_BACKENDS: readonly ChatBackendDescriptor[] = [
  { id: 'codex', label: 'Codex', providerIDs: ['codex', 'openai'] },
  { id: 'claude', label: 'Claude Code', providerIDs: ['claude-code', 'anthropic', 'claude'] },
  { id: 'hermes', label: 'Hermes', providerIDs: ['hermes', 'openburnbar', 'open-burn-bar'] },
  { id: 'pi-agent', label: 'Pi', providerIDs: ['pi', 'pi-agent', 'piagent'] },
  { id: 'openclaw', label: 'OpenClaw', providerIDs: ['openclaw'] },
  { id: 'openclaude', label: 'OpenClaude', providerIDs: ['openclaude'] },
  { id: 'omp', label: 'OMP', providerIDs: ['omp'] },
  { id: 'droid', label: 'Droid', providerIDs: ['droid', 'factory'] },
  { id: 'forge', label: 'Forge', providerIDs: ['forge', 'forgedev'] },
  { id: 'antigravity', label: 'Antigravity', providerIDs: ['antigravity'] },
  { id: 'cursor-agent', label: 'Cursor Agent', providerIDs: ['cursor-agent', 'cursoragent'] },
  { id: 'junie', label: 'Junie', providerIDs: ['junie'] },
  { id: 'fx', label: 'fx', providerIDs: ['fx', 'vercel-fx', 'vercelfx'] },
  { id: 'muse', label: 'Muse Code', providerIDs: ['muse', 'muse-code', 'musecode', 'meta-muse', 'metamuse'] }
];

const LEGACY_CLI_DESCRIPTOR: ChatBackendDescriptor = { id: 'cli', label: 'CLI', providerIDs: ['cli', 'local-cli'] };

export function chatBackendDescriptor(id: ChatBackendId): ChatBackendDescriptor {
  return CHAT_BACKENDS.find((entry) => entry.id === id) ?? LEGACY_CLI_DESCRIPTOR;
}

function normalizedProvider(value: string): string {
  return value.trim().toLowerCase();
}

function credentialIsReady(slot: ProviderCredentialSlot): boolean {
  if (!slot.isEnabled) return false;
  const status = slot.status.trim().toLowerCase();
  return ['ready', 'ok', 'healthy', 'active', 'connected', 'available'].some((token) => status.includes(token));
}

function catalogProviderMatches(provider: ProviderCatalogEntry, descriptor: ChatBackendDescriptor): boolean {
  const catalogIDs = [provider.id, provider.canonicalProviderID, ...(provider.providerAliases ?? [])]
    .filter((value): value is string => Boolean(value?.trim()))
    .map(normalizedProvider);
  return descriptor.providerIDs.some((providerID) => catalogIDs.includes(normalizedProvider(providerID)));
}

function catalogAdvertisesRouting(provider: ProviderCatalogEntry): boolean {
  return (provider.capabilities ?? []).some((capability) => normalizedProvider(capability) === 'routing');
}

/**
 * Availability is derived from daemon config plus the daemon catalog. A
 * provider logo or a persisted backend id never makes a route actionable by
 * itself. A null catalog means capability evidence is still unknown; callers
 * must fail closed before sending until a live catalog proves routing.
 */
export function chatBackendAvailability(
  config: ConfigSnapshot | null,
  backend: ChatBackendId,
  catalog: ProviderCatalog | null
): { state: ChatBackendAvailability; reason: string } {
  if (backend === 'cli') return { state: 'unsupported', reason: 'The legacy CLI backend is retained only for old thread history.' };
  if (!config) return { state: 'unknown', reason: 'Daemon provider configuration has not been loaded.' };
  const descriptor = chatBackendDescriptor(backend);
  const provider = config.providers?.find((candidate) =>
    descriptor.providerIDs.some((id) => normalizedProvider(id) === normalizedProvider(candidate.providerID))
  );
  if (!provider) return { state: 'unconfigured', reason: 'No daemon provider configuration is available; add a credential in Settings.' };
  if (!provider.isEnabled) return { state: 'disabled', reason: 'The daemon provider is disabled in routing settings.' };
  if (!provider.credentialSlots.some(credentialIsReady) && !provider.providerID.toLowerCase().includes('ollama')) {
    return { state: 'unconfigured', reason: 'No enabled credential has been verified by the daemon.' };
  }
  if (!catalog) {
    return { state: 'unknown', reason: 'Daemon provider capability catalog has not been loaded.' };
  }
  const catalogProvider = catalog.find((candidate) => catalogProviderMatches(candidate, descriptor));
  if (!catalogProvider) {
    return { state: 'unsupported', reason: 'The daemon catalog does not advertise this provider for chat routing.' };
  }
  if (!catalogAdvertisesRouting(catalogProvider)) {
    return { state: 'unsupported', reason: 'The daemon catalog does not advertise chat routing for this provider.' };
  }
  return { state: 'available', reason: 'Daemon provider configuration, routing capability, and a credential route are present.' };
}

export function canSelectChatBackend(
  config: ConfigSnapshot | null,
  backend: ChatBackendId,
  catalog: ProviderCatalog | null
): boolean {
  const availability = chatBackendAvailability(config, backend, catalog).state;
  return availability === 'available' || availability === 'unknown';
}

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
  if (
    !trimmed ||
    [...trimmed].some((character) => character.charCodeAt(0) < 0x20 || character.charCodeAt(0) === 0x7f)
  ) return null;
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
    case 'openclaw':
      return 'Ask OpenClaw…';
    case 'openclaude':
      return 'Ask OpenClaude…';
    case 'omp':
      return 'Ask OMP…';
    case 'droid':
      return 'Ask Droid…';
    case 'forge':
      return 'Ask Forge…';
    case 'antigravity':
      return 'Ask Antigravity…';
    case 'cursor-agent':
      return 'Ask Cursor Agent…';
    case 'junie':
      return 'Ask Junie…';
    case 'fx':
      return 'Ask fx…';
    case 'muse':
      return 'Ask Muse Code…';
    case 'cli':
      return 'Ask CLI…';
    default:
      return 'Ask Hermes…';
  }
}
