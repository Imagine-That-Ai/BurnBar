import type {
  UsageSummary,
  QuotaBucketState,
  QuotaBucket,
  ProviderCatalogEntry,
  ProviderHealthState,
  ProviderCatalogProvenance,
  ProviderModelProvenance,
  ProviderCatalogModel,
  ProviderFailoverState,
  ProviderCatalog,
  SessionEntry,
  SessionListResult,
  SessionHistoryEntry,
  SessionHistoryResult,
  SessionReplayResult,
  ChatThreadSummary,
  PersistedChatMessageRole,
  PersistedChatMessage,
  ChatThreadListResult,
  ChatThreadGetResult,
  ChatMessageAppendRequest,
  ChatMessageAppendResult,
  WeeklyPoint,
  MixEntry,
  UsageInsightsQualitativeCitation,
  UsageInsightsQualitativeFinding,
  UsageInsightsQualitativeAnalysis,
  UsageInsights,
  PendingApproval,
  MissionApprovalSnapshot,
  MissionPacketSnapshot,
  MissionResultSnapshot,
  MissionBurnRecord,
  MissionTakeoverRecord,
  MissionPRLinkageSnapshot,
  MissionFreshness,
  MissionHealthStatus,
  MissionHistoryEntry,
  MissionHealthResult,
  MissionRecord,
  MissionListResult,
  MissionDetail,
  ChatAttachmentUploadResult,
  GatewayAttachmentCapability,
  DaemonSubscriptionEvent,
  DaemonSubscriptionResponse,
  DaemonSubscriptionStopResponse
} from './tauriBridgeTypes.js';
import {
  CHAT_ATTACHMENT_MAX_BYTES
} from './tauriBridgeTypes.js';
import type { RawJsonValue } from './tauriBridgeRaw.js';
import {
  num,
  str,
  arr,
  obj,
  pick,
  requireObject,
  requireString,
  requireBoolean,
  optionalBoolean,
  requireSequence,
  decodeSubscriptionTopic
} from './tauriBridgeRaw.js';
import { mapCredentialSlot } from './tauriBridgeSystemDecoders.js';

export function decodeDaemonSubscriptionResponse(raw: RawJsonValue): DaemonSubscriptionResponse {
  const source = requireObject(pick(raw, 'result') ?? raw, 'subscription response');
  const eventsRaw = source.events;
  if (!Array.isArray(eventsRaw)) throw new Error('subscription.events must be an array.');
  const events = eventsRaw.map((rawEvent, index): DaemonSubscriptionEvent => {
    const event = requireObject(rawEvent, `subscription.events[${index}]`);
    const rawSnapshot = requireObject(event.snapshot, `subscription.events[${index}].snapshot`);
    const snapshot: Record<string, string> = {};
    for (const [key, value] of Object.entries(rawSnapshot)) {
      snapshot[key] = requireString(value, `subscription.events[${index}].snapshot.${key}`);
    }
    return {
      seq: requireSequence(event.seq, `subscription.events[${index}].seq`),
      kind: requireString(event.kind, `subscription.events[${index}].kind`),
      snapshot,
      terminal: requireBoolean(event.terminal, `subscription.events[${index}].terminal`)
    };
  });
  const degradationReason = source.degradation_reason;
  if (degradationReason !== undefined && degradationReason !== null && typeof degradationReason !== 'string') {
    throw new Error('subscription.degradation_reason must be a string when present.');
  }
  return {
    subscriptionId: requireString(source.subscription_id, 'subscription.subscription_id'),
    topic: decodeSubscriptionTopic(source.topic),
    seq: requireSequence(source.seq, 'subscription.seq'),
    cursor: requireString(source.cursor, 'subscription.cursor'),
    firstSnapshot: requireBoolean(source.first_snapshot, 'subscription.first_snapshot'),
    events,
    degradedFallback: requireBoolean(source.degraded_fallback, 'subscription.degraded_fallback'),
    degradationReason: typeof degradationReason === 'string' ? degradationReason : undefined,
    backpressure: requireString(source.backpressure, 'subscription.backpressure'),
    disconnectDetected: requireBoolean(source.disconnect_detected, 'subscription.disconnect_detected'),
    recoveredAfterRestart: requireBoolean(
      source.recovered_after_restart,
      'subscription.recovered_after_restart'
    ),
    terminalStateDelivered: requireBoolean(
      source.terminal_state_delivered,
      'subscription.terminal_state_delivered'
    )
  };
}

export function decodeDaemonSubscriptionStopResponse(raw: RawJsonValue): DaemonSubscriptionStopResponse {
  const source = requireObject(pick(raw, 'result') ?? raw, 'subscription stop response');
  return {
    subscriptionId: requireString(source.subscription_id, 'subscription stop.subscription_id'),
    stopped: requireBoolean(source.stopped, 'subscription stop.stopped'),
    lastSeq: requireSequence(source.last_seq, 'subscription stop.last_seq')
  };
}

export type UsageEvent = {
  id: string;
  provider: string;
  model: string;
  tokens: number;
  cost: number;
  at: string;
};

export function mapUsageSummary(raw: RawJsonValue): UsageSummary {
  // Map to an intermediate shape that preserves raw numeric tokens/cost.
  // Aggregate from these numbers directly — never re-parse display strings,
  // which lose sub-cent precision (toFixed) and break under locale separators.
  const events = arr(pick(raw, 'usage', 'events', 'recent')).map(
    (e, i): UsageEvent => ({
      id: str(pick(e, 'id', 'event_id'), `evt-${i}`),
      provider: str(pick(e, 'providerId', 'provider', 'provider_id'), 'unknown'),
      model: str(pick(e, 'modelId', 'model', 'model_id'), 'unknown'),
      tokens: num(pick(e, 'tokens', 'totalTokens', 'tokenCount')),
      cost: num(pick(e, 'costUsd', 'cost', 'estimatedCostUsd')),
      at: str(pick(e, 'at', 'timestamp', 'createdAt', 'recordedAt'), new Date().toISOString())
    })
  );
  const today = events.filter((e) => isToday(e.at));
  return {
    todayTokens: today.reduce((s, e) => s + e.tokens, 0),
    todayCostUsd: today.reduce((s, e) => s + e.cost, 0),
    sevenDay: bucketSevenDay(events),
    recentEvents: events.slice(0, 12).map((e) => ({
      id: e.id,
      title: `${e.provider} / ${e.model}`,
      // Display-only formatting; pinned to en-US so separators never vary by locale.
      detail: `${e.tokens.toLocaleString('en-US')} tokens · $${e.cost.toFixed(2)}`,
      at: e.at
    }))
  };
}

export function isToday(at: string): boolean {
  try {
    const d = new Date(at);
    const now = new Date();
    return d.toDateString() === now.toDateString();
  } catch {
    return false;
  }
}

export function bucketSevenDay(events: UsageEvent[]): number[] {
  const days: number[] = [0, 0, 0, 0, 0, 0, 0];
  const now = Date.now();
  for (const e of events) {
    try {
      const diff = now - new Date(e.at).getTime();
      const dayIdx = 6 - Math.floor(diff / 86_400_000);
      if (dayIdx >= 0 && dayIdx < 7) days[dayIdx] += e.tokens;
    } catch {
      /* skip malformed timestamp */
    }
  }
  return days;
}

export const PROVIDER_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/;
export const MODEL_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$/;

export function normalizedCatalogID(value: RawJsonValue, pattern: RegExp): string | null {
  const candidate = str(value).trim();
  if (
    !candidate ||
    [...candidate].some((character) => character.charCodeAt(0) < 0x20 || character.charCodeAt(0) === 0x7f)
  ) return null;
  return pattern.test(candidate) ? candidate : null;
}

export function normalizedModelID(value: RawJsonValue): string | null {
  return normalizedCatalogID(value, MODEL_ID_PATTERN);
}

export function modelIdentityMatches(
  model: Pick<ProviderCatalogModel, 'id' | 'aliases' | 'canonicalModelID'>,
  requested: string
): boolean {
  const normalized = requested.trim().toLowerCase();
  return [model.id, model.canonicalModelID ?? '', ...model.aliases]
    .some((value) => value.trim().toLowerCase() === normalized);
}

export function normalizeProviderHealth(raw: string): ProviderHealthState {
  const value = raw.trim().toLowerCase();
  if (!value) return 'unknown';
  if (['ready', 'ok', 'healthy', 'active', 'connected', 'available'].some((token) => value.includes(token))) {
    return 'healthy';
  }
  if (['cool', 'rate', 'degrad', 'stale', 'warming', 'pending'].some((token) => value.includes(token))) {
    return 'degraded';
  }
  if (['missing', 'credential', 'unauth', 'expired', 'error', 'failed', 'unavailable', 'disabled', 'invalid'].some((token) => value.includes(token))) {
    return 'unavailable';
  }
  return 'unknown';
}

export function normalizeQuotaSourceKind(raw: RawJsonValue): ProviderCatalogEntry['quotaSourceKind'] {
  switch (str(raw).trim().toLowerCase()) {
    case 'provider':
      return 'provider';
    case 'officialapi':
    case 'official-api':
    case 'api':
      return 'officialAPI';
    case 'localcli':
    case 'local-cli':
      return 'localCLI';
    case 'localsession':
    case 'local-session':
    case 'locallog':
    case 'local-log':
      return 'localSession';
    case 'manualestimate':
    case 'manual-estimate':
    case 'estimated':
      return 'manualEstimate';
    case 'unavailable':
      return 'unavailable';
    default:
      return undefined;
  }
}

export function normalizeQuotaConfidence(raw: RawJsonValue): ProviderCatalogEntry['quotaConfidence'] {
  switch (str(raw).trim().toLowerCase()) {
    case 'high':
    case 'exact':
      return 'high';
    case 'medium':
    case 'estimated':
      return 'medium';
    case 'low':
      return 'low';
    case 'stale':
    case 'unavailable':
      return 'stale';
    default:
      return undefined;
  }
}

export function providerHealth(
  provider: RawJsonValue | undefined,
  catalogProvider: RawJsonValue | undefined
): ProviderHealthState {
  const configured = provider !== undefined;
  const enabledValue = pick(provider, 'isEnabled', 'enabled');
  if (configured && enabledValue !== undefined && !enabledValue) return 'unavailable';
  const slots = arr(pick(provider, 'credentialSlots', 'credentials', 'accounts'));
  if (slots.length > 0) {
    const states = slots.map((slot) => normalizeProviderHealth(str(pick(slot, 'status', 'state', 'health'))));
    if (states.includes('healthy')) return 'healthy';
    if (states.includes('degraded')) return 'degraded';
    if (states.includes('unavailable')) return 'unavailable';
    return 'unknown';
  }
  // A local provider may not need a credential slot, but its endpoint still
  // needs a daemon probe before it is advertised as route-ready.
  if (configured && Boolean(pick(catalogProvider, 'local'))) return 'degraded';
  return configured ? 'unavailable' : 'unknown';
}

export function catalogModelCapabilities(raw: RawJsonValue): string[] {
  return arr(pick(raw, 'capabilities', 'features', 'capabilityClassIDs', 'capabilityClassIds'))
    .map((value) => str(value).trim())
    .filter(Boolean)
    .slice(0, 32);
}

export function mapCatalogModel(
  raw: RawJsonValue,
  providerHealthState: ProviderHealthState,
  providerEnabled: boolean,
  disabledModelIDs: string[],
  preferredModelIDs: string[],
  displayOverrides: Map<string, string>
): ProviderCatalogModel | null {
  const id = normalizedModelID(pick(raw, 'id', 'modelID', 'modelId'));
  if (!id) return null;
  const aliases = arr(pick(raw, 'aliases')).map((value) => normalizedModelID(value)).filter((value): value is string => value !== null);
  const canonicalModelID = normalizedModelID(pick(raw, 'canonicalModelID', 'canonicalModelId')) ?? undefined;
  const disabled = disabledModelIDs.some((disabledID) => modelIdentityMatches({ id, aliases, canonicalModelID }, disabledID));
  const preferred = preferredModelIDs.length === 0 || preferredModelIDs.some((preferredID) => modelIdentityMatches({ id, aliases, canonicalModelID }, preferredID));
  const displayName = displayOverrides.get(id.toLowerCase()) ?? (str(pick(raw, 'displayName', 'label', 'name')).trim() || id);
  const routeReady = providerEnabled && providerHealthState === 'healthy';
  return {
    id,
    label: displayName,
    aliases,
    canonicalModelID,
    capabilities: catalogModelCapabilities(raw),
    enabled: routeReady && !disabled && preferred,
    health: providerEnabled ? providerHealthState : 'unavailable',
    provenance: 'daemon-catalog',
    detail: disabled
      ? 'Disabled by provider configuration.'
      : !preferred
        ? 'Catalog entry is not selected as a preferred model.'
        : !routeReady
          ? 'Provider route is not verified by the daemon.'
          : undefined
  };
}

export function failoverState(snapshot: RawJsonValue, provider: RawJsonValue | undefined, health: ProviderHealthState): ProviderFailoverState {
  const mode = str(pick(snapshot, 'routerMode'), 'provider_family_failover').trim() || 'provider_family_failover';
  const enabled = provider !== undefined && Boolean(pick(provider, 'isEnabled', 'enabled'));
  if (!enabled) return { mode, eligible: false, detail: 'Provider is disabled or not configured in the daemon.' };
  if (health === 'healthy') return { mode, eligible: true, detail: 'Verified credential route is eligible for provider-family failover.' };
  if (health === 'degraded') return { mode, eligible: false, detail: 'Provider is configured, but the daemon has not verified a healthy route.' };
  if (health === 'unavailable') return { mode, eligible: false, detail: 'No verified credential route is available.' };
  return { mode, eligible: false, detail: 'Route health is not available yet.' };
}

export function mapQuotaBuckets(raw: RawJsonValue): QuotaBucket[] {
  return arr(pick(raw, 'quotaBuckets', 'quota', 'buckets')).flatMap((bucket): QuotaBucket[] => {
    const id = normalizedCatalogID(pick(bucket, 'id', 'bucketId'), MODEL_ID_PATTERN);
    const label = str(pick(bucket, 'label', 'name')).trim();
    if (!id && !label) return [];
    const stableID = id ?? label.toLowerCase().replace(/[^a-z0-9._:/-]+/g, '-').replace(/^-+|-+$/g, '');
    if (!stableID) return [];
    return [{
      id: stableID,
      label: label || stableID,
      usedPct: Math.min(100, Math.max(0, num(pick(bucket, 'usedPct', 'usedPercentage', 'pct')))),
      resetsAt: str(pick(bucket, 'resetsAt', 'resetAt')).trim() || undefined,
      state: normalizeQuotaState(str(pick(bucket, 'state', 'status')))
    }];
  });
}

/** Map daemon.config.get plus optional daemon.catalog into a truthful UI catalog. */
export function mapProviderCatalog(raw: RawJsonValue): ProviderCatalog {
  const configResponse = pick(raw, 'config');
  const snapshot = pick(configResponse, 'snapshot', 'config') ?? pick(raw, 'snapshot', 'config') ?? raw;
  const catalogResponse = pick(raw, 'catalog');
  const catalog = pick(catalogResponse, 'catalog') ?? catalogResponse;
  const catalogProviders = arr(pick(catalog, 'providers'));
  const configuredProviders = arr(pick(snapshot, 'providers', 'providerAccounts'));
  const catalogAvailable = pick(raw, 'catalogAvailable') === true || catalogProviders.length > 0;
  const catalogError = str(pick(raw, 'catalogError')).trim() || undefined;
  const providerIDs = new Map<string, string>();
  const addProviderID = (value: RawJsonValue) => {
    const id = normalizedCatalogID(value, PROVIDER_ID_PATTERN);
    if (id) providerIDs.set(id.toLowerCase(), id);
  };
  configuredProviders.forEach((provider) => addProviderID(pick(provider, 'id', 'providerId', 'providerID', 'provider_id')));
  catalogProviders.forEach((provider) => addProviderID(pick(provider, 'id', 'providerId', 'providerID', 'provider_id')));
  arr(pick(snapshot, 'credentialSlots', 'providerCredentialSlots')).forEach((slot) => addProviderID(pick(slot, 'providerId', 'providerID', 'provider_id')));

  return [...providerIDs.values()].map((providerID): ProviderCatalogEntry => {
    const normalizedID = providerID.toLowerCase();
    const provider = configuredProviders.find((candidate) => normalizedCatalogID(pick(candidate, 'id', 'providerId', 'providerID', 'provider_id'), PROVIDER_ID_PATTERN)?.toLowerCase() === normalizedID);
    const catalogProvider = catalogProviders.find((candidate) => normalizedCatalogID(pick(candidate, 'id', 'providerId', 'providerID', 'provider_id'), PROVIDER_ID_PATTERN)?.toLowerCase() === normalizedID);
    const enabled = provider !== undefined && Boolean(pick(provider, 'isEnabled', 'enabled'));
    const health = providerHealth(provider, catalogProvider);
    const preferredModelIDs = arr(pick(provider, 'preferredModelIDs', 'preferredModelIds', 'preferred_model_ids')).map((value) => normalizedModelID(value)).filter((value): value is string => value !== null);
    const disabledModelIDs = arr(pick(provider, 'disabledAdvertisedModelIDs', 'disabledAdvertisedModelIds')).map((value) => normalizedModelID(value)).filter((value): value is string => value !== null);
    const displayOverrides = new Map(
      arr(pick(provider, 'modelDisplayOverrides')).flatMap((override) => {
        const id = normalizedModelID(pick(override, 'modelID', 'modelId'));
        const label = str(pick(override, 'displayName')).trim();
        return id && label ? [[id.toLowerCase(), label] as const] : [];
      })
    );
    const models = arr(pick(catalogProvider, 'models')).flatMap((model) => {
      const mapped = mapCatalogModel(model, health, enabled, disabledModelIDs, preferredModelIDs, displayOverrides);
      return mapped ? [mapped] : [];
    });
    const modelIDs = new Set(models.flatMap((model) => [model.id, model.canonicalModelID ?? '', ...model.aliases].map((value) => value.toLowerCase())));
    const appendConfiguredModel = (idValue: RawJsonValue, labelValue: RawJsonValue, provenance: ProviderModelProvenance, detail?: string) => {
      const id = normalizedModelID(idValue);
      if (!id || modelIDs.has(id.toLowerCase())) return;
      modelIDs.add(id.toLowerCase());
      const label = str(labelValue).trim() || displayOverrides.get(id.toLowerCase()) || id;
      models.push({
        id,
        label,
        aliases: [],
        capabilities: [],
        enabled: enabled && health === 'healthy',
        health: enabled ? health : 'unavailable',
        provenance,
        detail: detail ?? (enabled && health === 'healthy' ? undefined : 'Provider route is not verified by the daemon.')
      });
    };
    preferredModelIDs.forEach((id) => appendConfiguredModel(id, displayOverrides.get(id.toLowerCase()), 'configured-model'));
    arr(pick(provider, 'customModels')).forEach((model) => appendConfiguredModel(pick(model, 'modelID', 'modelId'), pick(model, 'displayName', 'label'), 'custom-model'));
    arr(pick(provider, 'modelAliases')).forEach((alias) => appendConfiguredModel(
      pick(alias, 'aliasID', 'aliasId'),
      pick(alias, 'displayName', 'label'),
      'model-alias',
      `Routes to ${str(pick(alias, 'baseModelID', 'baseModelId')).trim() || 'a configured model'}.`
    ));
    arr(pick(provider, 'modelVariants')).forEach((variant) => appendConfiguredModel(
      pick(variant, 'variantID', 'variantId'),
      pick(variant, 'label'),
      'model-variant',
      `Variant of ${str(pick(variant, 'baseModelID', 'baseModelId')).trim() || 'a configured model'}.`
    ));
    const label = str(pick(provider, 'label', 'displayName', 'name')).trim() || str(pick(catalogProvider, 'displayName', 'label', 'name')).trim() || providerID;
    const slots = arr(pick(provider, 'credentialSlots', 'credentials', 'accounts'));
    const credentialSlots = slots.map((slot, index) => mapCredentialSlot(slot, index));
    const preferredCredentialSlotID = str(pick(provider, 'preferredCredentialSlotID', 'preferredCredentialSlotId')).trim() || undefined;
    const preferredSlot = preferredCredentialSlotID
      ? credentialSlots.find((slot) => slot.slotID === preferredCredentialSlotID)
      : undefined;
    const accountLabel = str(pick(provider, 'accountLabel', 'account')).trim()
      || preferredSlot?.label
      || credentialSlots.find((slot) => slot.isEnabled)?.label
      || credentialSlots[0]?.label
      || (provider ? 'Not configured' : 'Catalog only');
    const capabilities = arr(pick(catalogProvider, 'capabilities', 'features')).map((value) => str(value).trim()).filter(Boolean).slice(0, 32);
    const quotaMetadata = provider ?? catalogProvider;
    const quotaSourceKind = normalizeQuotaSourceKind(
      pick(quotaMetadata, 'quotaSourceKind', 'quota_source_kind', 'sourceKind', 'source_kind')
    );
    const quotaSource = str(pick(quotaMetadata, 'quotaSource', 'quota_source', 'sourceLabel', 'source_label')).trim() || undefined;
    const quotaConfidence = normalizeQuotaConfidence(
      pick(quotaMetadata, 'quotaConfidence', 'quota_confidence', 'confidence')
    );
    const accountStorage = str(pick(quotaMetadata, 'accountStorage', 'account_storage', 'storageScope', 'storage_scope')).trim().toLowerCase();
    const normalizedAccountStorage = ['cloud', 'local', 'keychain', 'unknown'].includes(accountStorage)
      ? accountStorage as ProviderCatalogEntry['accountStorage']
      : undefined;
    const planTierBadge = str(pick(quotaMetadata, 'planTierBadge', 'plan_tier_badge', 'planTier', 'plan_tier')).trim() || undefined;
    const provenance: ProviderCatalogProvenance = catalogProvider && provider
      ? 'daemon-catalog+daemon-config'
      : catalogProvider
        ? 'daemon-catalog'
        : provider
          ? 'daemon-config'
          : 'daemon-config';
    return {
      id: providerID,
      label,
      accountLabel,
      quotaBuckets: mapQuotaBuckets(provider ?? catalogProvider),
      ...(quotaSourceKind ? { quotaSourceKind } : {}),
      ...(quotaSource ? { quotaSource } : {}),
      ...(quotaConfidence ? { quotaConfidence } : {}),
      ...(normalizedAccountStorage ? { accountStorage: normalizedAccountStorage } : {}),
      ...(planTierBadge ? { planTierBadge } : {}),
      credentialSlots,
      preferredCredentialSlotID,
      models,
      capabilities,
      health,
      provenance,
      failover: failoverState(snapshot, provider, health),
      catalogAvailable,
      catalogError
    };
  });
}

export function normalizeQuotaState(s: string): QuotaBucketState {
  const lower = s.toLowerCase();
  if (!lower.trim()) return 'unknown';
  if (lower.includes('cool') || lower.includes('rate')) return 'cooling_down';
  if (lower.includes('missing') || lower.includes('credential') || lower.includes('unauth'))
    return 'missing_credential';
  if (lower.includes('exhaust') || lower.includes('deplet') || lower.includes('limit'))
    return 'exhausted';
  if (lower.includes('ok') || lower.includes('healthy') || lower.includes('ready') || lower.includes('available')) return 'ok';
  return 'unknown';
}

export const SESSION_LIST_RESULT_LIMIT = 500;
export const SESSION_ID_MAX_CHARS = 512;

export function safeSessionIdentity(value: RawJsonValue): string | undefined {
  if (typeof value !== 'string') return undefined;
  const normalized = value.trim();
  if (
    normalized.length === 0 ||
    normalized.length > SESSION_ID_MAX_CHARS ||
    normalized.split('').some((character) => character.charCodeAt(0) < 0x20 || character === '\u007f')
  ) {
    return undefined;
  }
  return normalized;
}

/** Match ConversationRecord.stableId's provider prefix without guessing unknown providers. */
export function stableProviderPrefix(provider: string): string | undefined {
  const normalized = provider.trim().toLowerCase().replace(/[\s-]+/g, '_');
  const known: Record<string, string> = {
    factory: 'Factory',
    claude: 'Claude Code',
    claude_code: 'Claude Code',
    copilot: 'Copilot',
    aider: 'Aider',
    cursor: 'Cursor',
    openai: 'OpenAI',
    open_burn_bar: 'OpenBurnBar',
    deepseek: 'DeepSeek',
    codex: 'Codex',
    opencode: 'OpenCode',
    open_code: 'OpenCode',
    zai: 'Zai',
    minimax: 'MiniMax',
    kimi: 'Kimi',
    cline: 'Cline',
    kilocode: 'Kilo Code',
    kilo_code: 'Kilo Code',
    roocode: 'Roo Code',
    roo_code: 'Roo Code',
    forge: 'Forge',
    augment: 'Augment',
    hermes: 'Hermes',
    pi_agent: 'Pi Agent',
    gemini: 'Gemini CLI',
    gemini_cli: 'Gemini CLI',
    antigravity: 'Antigravity',
    goose: 'Goose',
    openclaw: 'OpenClaw',
    open_claw: 'OpenClaw',
    openclaude: 'OpenClaude',
    open_claude: 'OpenClaude',
    omp: 'OMP',
    ollama: 'Ollama',
    windsurf: 'Windsurf',
    warp: 'Warp',
    xai: 'xAI',
    x_ai: 'xAI',
    mimo: 'MiMo',
    cursor_agent: 'Cursor Agent',
    junie: 'Junie'
  };
  return known[normalized];
}

export type ResolvedSessionIdentity = Pick<
  SessionEntry,
  'sourceID' | 'sourceIDVerified' | 'providerSessionID' | 'runID' | 'projectName'
>;

export function resolveSessionIdentity(raw: RawJsonValue, provider: string): ResolvedSessionIdentity {
  const explicitSourceID = safeSessionIdentity(
    pick(raw, 'sourceID', 'sourceId', 'source_id', 'conversationID', 'conversationId', 'conversation_id')
  );
  const rawID = safeSessionIdentity(pick(raw, 'id'));
  const providerSessionID = safeSessionIdentity(pick(raw, 'sessionID', 'sessionId', 'session_id'));
  const normalizedProviderSessionID = providerSessionID?.includes(':')
    ? providerSessionID
    : stableProviderPrefix(provider) && providerSessionID
      ? `${stableProviderPrefix(provider)}:${providerSessionID}`
      : undefined;
  const resolvedSourceID = explicitSourceID ?? (rawID?.includes(':') ? rawID : normalizedProviderSessionID);
  // A provider-prefixed fallback is a useful display identity, but it is not
  // proof that the indexed conversation exists. Only daemon-supplied IDs (or
  // already canonical provider-prefixed IDs) can be replayed directly.
  const sourceIDVerified = resolvedSourceID
    ? Boolean(explicitSourceID || rawID?.includes(':') || providerSessionID?.includes(':'))
    : undefined;
  return {
    sourceID: resolvedSourceID,
    sourceIDVerified,
    providerSessionID,
    runID: safeSessionIdentity(pick(raw, 'runID', 'runId', 'run_id')),
    projectName: safeSessionIdentity(pick(raw, 'projectName', 'project', 'workspaceName', 'workspace'))
  };
}

export function mapSessionList(raw: RawJsonValue): SessionListResult {
  const directList = arr(pick(raw, 'sessions', 'usage', 'results'));
  // `daemon.search.query` returns indexed hits rather than usage rows. Keep the
  // hit's source identity so a later replay can target the exact conversation;
  // token/cost fields remain explicit zeroes because the search contract does
  // not provide usage totals.
  const list = directList.length > 0 ? directList : arr(pick(raw, 'hits'));
  const sessions = list.map(
    (s, i): SessionEntry => {
      const provider = str(pick(s, 'provider', 'providerID', 'providerId', 'provider_id'), 'unknown');
      const identity = resolveSessionIdentity(s, provider);
      const displayID =
        safeSessionIdentity(pick(s, 'id', 'sessionID', 'sessionId', 'session_id')) ??
        identity.sourceID ??
        `session-${i}`;
      return {
        id: displayID,
        provider,
        model: str(pick(s, 'model', 'modelID', 'modelId', 'model_id'), 'unknown'),
        startedAt: str(
          pick(s, 'startedAt', 'recordedAt', 'timestamp', 'createdAt', 'at'),
          new Date().toISOString()
        ),
        tokens: num(
          pick(s, 'tokens', 'totalTokens', 'tokenCount'),
          num(pick(s, 'inputTokens')) + num(pick(s, 'outputTokens'))
        ),
        costUsd: num(pick(s, 'costUsd', 'cost', 'estimatedCostUsd')),
        title: str(
          pick(s, 'title', 'summary', 'name', 'projectName'),
          identity.projectName ?? 'Untitled session'
        ),
        ...identity
      };
    }
  );
  const nextCursor = str(pick(raw, 'nextCursor', 'cursor')) || null;
  const explicitComplete = pick(raw, 'complete', 'isComplete');
  const complete =
    typeof explicitComplete === 'boolean'
      ? explicitComplete
      : nextCursor === null && sessions.length < SESSION_LIST_RESULT_LIMIT;
  return { sessions, nextCursor, complete };
}

export const SESSION_BRIEFING_MAX_BYTES = 65_536;

export function mapSessionHistory(raw: RawJsonValue): SessionHistoryResult {
  const source = obj(pick(raw, 'result') ?? raw);
  const historyComplete = pick(source, 'historyComplete', 'history_complete') === true;
  const nextCursorValue = pick(source, 'nextCursor', 'next_cursor', 'cursor');
  const nextCursor =
    nextCursorValue === undefined || nextCursorValue === null
      ? null
      : requireBoundedString(nextCursorValue, 'activity history nextCursor', 256);
  const historyLimit = requireCount(
    pick(source, 'historyLimit', 'history_limit'),
    'activity history historyLimit'
  );
  const totalCount = requireCount(
    pick(source, 'totalCount', 'total_count'),
    'activity history totalCount'
  );
  if (historyLimit < 1 || historyLimit > 500 || totalCount > 100_000) {
    throw new Error('activity history metadata is outside the supported bounds.');
  }

  if (!historyComplete) {
    return {
      sessions: [],
      nextCursor,
      complete: false,
      historyComplete: false,
      historyLimit,
      totalCount
    };
  }

  const rows = arr(pick(source, 'sessions'));
  const sessions = rows.map((row, index): SessionHistoryEntry => {
    const provider = requireBoundedString(
      pick(row, 'provider', 'providerID', 'providerId'),
      `activity history session ${index} provider`,
      256
    );
    const sourceID = requireBoundedString(
      pick(row, 'sourceID', 'sourceId', 'source_id'),
      `activity history session ${index} sourceID`,
      512
    );
    const providerSessionID = requireBoundedString(
      pick(row, 'providerSessionID', 'providerSessionId', 'provider_session_id'),
      `activity history session ${index} providerSessionID`,
      512
    );
    const tokens = requireCount(
      pick(row, 'tokens', 'totalTokens', 'tokenCount'),
      `activity history session ${index} tokens`
    );
    const costUsd = num(pick(row, 'costUsd', 'cost', 'estimatedCostUsd'), NaN);
    if (!Number.isFinite(costUsd) || costUsd < 0) {
      throw new Error(`activity history session ${index} costUsd must be a non-negative number.`);
    }
    const bodyMD = requireBoundedString(
      pick(row, 'bodyMD', 'body_md', 'briefingMD', 'briefing_md'),
      `activity history session ${index} bodyMD`,
      SESSION_BRIEFING_MAX_BYTES
    );
    const runID = safeSessionIdentity(pick(row, 'runID', 'runId', 'run_id'));
    const projectName = safeSessionIdentity(pick(row, 'projectName', 'project', 'workspaceName', 'workspace'));
    return {
      id: requireBoundedString(pick(row, 'id'), `activity history session ${index} id`, 512),
      provider,
      model: requireBoundedString(
        pick(row, 'model', 'modelID', 'modelId'),
        `activity history session ${index} model`,
        512
      ),
      startedAt: requireBoundedString(
        pick(row, 'startedAt', 'started_at', 'startTime'),
        `activity history session ${index} startedAt`,
        128
      ),
      tokens,
      costUsd,
      title: requireBoundedString(
        pick(row, 'title', 'summary', 'name'),
        `activity history session ${index} title`,
        4_096
      ),
      sourceID,
      providerSessionID,
      ...(runID ? { runID } : {}),
      ...(projectName ? { projectName } : {}),
      bodyMD
    };
  });
  if (sessions.length !== totalCount) {
    throw new Error('activity history complete response does not match totalCount.');
  }
  return {
    sessions,
    nextCursor,
    complete: historyComplete && nextCursor === null,
    historyComplete,
    historyLimit,
    totalCount
  };
}

export function mapSessionReplay(raw: RawJsonValue): SessionReplayResult {
  const source = obj(pick(raw, 'result') ?? raw);
  const briefing = optionalBoundedString(
    pick(source, 'briefingMD', 'briefing_md'),
    'session briefing',
    SESSION_BRIEFING_MAX_BYTES
  );
  return {
    kind: str(pick(source, 'kind', 'status'), 'error'),
    briefingMD: briefing,
    briefingTruncated: optionalBoolean(
      pick(source, 'briefingTruncated', 'briefing_truncated'),
      'session briefingTruncated'
    ),
    targetHarness: str(pick(source, 'targetHarness', 'target_harness')) || undefined,
    workingDirectory: str(pick(source, 'workingDirectory', 'working_directory')) || undefined,
    note: str(pick(source, 'note')) || undefined,
    pid: Number.isSafeInteger(num(pick(source, 'pid'), NaN)) ? num(pick(source, 'pid')) : undefined,
    errorCode: str(pick(source, 'errorCode', 'error_code', 'code')) || undefined,
    errorRecovery: str(pick(source, 'errorRecovery', 'error_recovery', 'recovery')) || undefined
  };
}

export const CHAT_THREAD_RESULT_LIMIT = 100;
export const CHAT_MESSAGE_RESULT_LIMIT = 500;
export const CHAT_ID_LIMIT = 256;
export const CHAT_TITLE_LIMIT = 512;
export const CHAT_PREVIEW_LIMIT = 4_096;
export const CHAT_CONTENT_LIMIT = 262_144;
export const CHAT_BACKEND_ID_LIMIT = 64;

export function requireBoundedString(
  value: RawJsonValue,
  label: string,
  maxBytes: number,
  options: { allowEmpty?: boolean } = {}
): string {
  if (typeof value !== 'string' || (!options.allowEmpty && value.length === 0)) {
    throw new Error(`${label} must be ${options.allowEmpty ? 'a' : 'a non-empty'} string.`);
  }
  if (new TextEncoder().encode(value).length > maxBytes) {
    throw new Error(`${label} exceeds ${maxBytes} UTF-8 bytes.`);
  }
  return value;
}

export function optionalBoundedString(value: RawJsonValue, label: string, maxBytes: number): string | undefined {
  if (value === undefined || value === null) return undefined;
  return requireBoundedString(value, label, maxBytes);
}

export function requireTimestamp(value: RawJsonValue, label: string): string {
  const timestamp = requireBoundedString(value, label, 64);
  if (
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/.test(timestamp) ||
    !Number.isFinite(Date.parse(timestamp))
  ) {
    throw new Error(`${label} must be a canonical ISO-8601 timestamp.`);
  }
  return timestamp;
}

export function requireCount(value: RawJsonValue, label: string): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${label} must be a non-negative safe integer.`);
  }
  return value;
}

export function decodePersistedChatRole(value: RawJsonValue, label: string): PersistedChatMessageRole {
  if (value === 'user' || value === 'assistant' || value === 'system') return value;
  throw new Error(`${label} is unsupported.`);
}

export function decodeChatThreadSummary(raw: RawJsonValue, label: string): ChatThreadSummary {
  const source = requireObject(raw, label);
  return {
    id: requireBoundedString(source.id, `${label}.id`, CHAT_ID_LIMIT),
    title: requireBoundedString(source.title, `${label}.title`, CHAT_TITLE_LIMIT),
    preview: requireBoundedString(source.preview, `${label}.preview`, CHAT_PREVIEW_LIMIT, { allowEmpty: true }),
    messageCount: requireCount(source.messageCount, `${label}.messageCount`),
    createdAt: requireTimestamp(source.createdAt, `${label}.createdAt`),
    updatedAt: requireTimestamp(source.updatedAt, `${label}.updatedAt`),
    lastMessageAt:
      source.lastMessageAt === undefined || source.lastMessageAt === null
        ? undefined
        : requireTimestamp(source.lastMessageAt, `${label}.lastMessageAt`),
    backendID: optionalBoundedString(source.backendID, `${label}.backendID`, CHAT_BACKEND_ID_LIMIT)
  };
}

export function decodePersistedChatMessage(raw: RawJsonValue, label: string): PersistedChatMessage {
  const source = requireObject(raw, label);
  return {
    id: requireBoundedString(source.id, `${label}.id`, CHAT_ID_LIMIT),
    threadID: requireBoundedString(source.threadID, `${label}.threadID`, CHAT_ID_LIMIT),
    role: decodePersistedChatRole(source.role, `${label}.role`),
    content: requireBoundedString(source.content, `${label}.content`, CHAT_CONTENT_LIMIT, { allowEmpty: true }),
    timestamp: requireTimestamp(source.timestamp, `${label}.timestamp`),
    backendID: optionalBoundedString(source.backendID, `${label}.backendID`, CHAT_BACKEND_ID_LIMIT),
    attachments: decodeChatAttachmentMetadata(source.attachments, `${label}.attachments`)
  };
}

export function decodeChatAttachmentMetadata(
  value: RawJsonValue,
  label: string
): ChatAttachmentUploadResult[] | undefined {
  if (value === undefined || value === null) return undefined;
  if (!Array.isArray(value)) throw new Error(`${label} must be an array.`);
  if (value.length > 8) throw new Error(`${label} exceeds 8 entries.`);
  return value.map((rawAttachment, index) => {
    try {
      return decodeChatAttachmentUpload(rawAttachment);
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      throw new Error(`${label}[${index}]: ${detail}`);
    }
  });
}

export function decodeChatThreadList(raw: RawJsonValue): ChatThreadListResult {
  const source = requireObject(pick(raw, 'result') ?? raw, 'chat thread list');
  if (!Array.isArray(source.threads)) throw new Error('chat thread list.threads must be an array.');
  if (source.threads.length > CHAT_THREAD_RESULT_LIMIT) {
    throw new Error(`chat thread list.threads exceeds ${CHAT_THREAD_RESULT_LIMIT} entries.`);
  }
  return {
    threads: source.threads.map((thread, index) =>
      decodeChatThreadSummary(thread, `chat thread list.threads[${index}]`)
    )
  };
}

export function decodeChatThreadGet(raw: RawJsonValue): ChatThreadGetResult {
  const source = requireObject(pick(raw, 'result') ?? raw, 'chat thread get');
  if (!Array.isArray(source.messages)) throw new Error('chat thread get.messages must be an array.');
  if (source.messages.length > CHAT_MESSAGE_RESULT_LIMIT) {
    throw new Error(`chat thread get.messages exceeds ${CHAT_MESSAGE_RESULT_LIMIT} entries.`);
  }
  const thread = source.thread === undefined || source.thread === null
    ? undefined
    : decodeChatThreadSummary(source.thread, 'chat thread get.thread');
  const messages = source.messages.map((message, index) =>
    decodePersistedChatMessage(message, `chat thread get.messages[${index}]`)
  );
  if (!thread && messages.length > 0) {
    throw new Error('chat thread get cannot contain messages when the thread is missing.');
  }
  if (thread && messages.some((message) => message.threadID !== thread.id)) {
    throw new Error('chat thread get contains a message for a different thread.');
  }
  return {
    thread,
    messages,
    hasMoreBefore: requireBoolean(source.hasMoreBefore, 'chat thread get.hasMoreBefore')
  };
}

export function decodeChatMessageAppend(raw: RawJsonValue): ChatMessageAppendResult {
  const source = requireObject(pick(raw, 'result') ?? raw, 'chat message append');
  return {
    message: decodePersistedChatMessage(source.message, 'chat message append.message'),
    inserted: requireBoolean(source.inserted, 'chat message append.inserted')
  };
}

export function decodeChatAttachmentUpload(raw: RawJsonValue): ChatAttachmentUploadResult {
  const source = requireObject(pick(raw, 'result') ?? raw, 'chat attachment upload');
  if ('path' in source || 'absolutePath' in source || 'workspacePath' in source) {
    throw new Error('chat attachment upload response must not expose a filesystem path.');
  }
  const byteSize = requireCount(source.byteSize, 'chat attachment upload.byteSize');
  if (byteSize === 0 || byteSize > CHAT_ATTACHMENT_MAX_BYTES) {
    throw new Error(`chat attachment upload.byteSize must be between 1 and ${CHAT_ATTACHMENT_MAX_BYTES}.`);
  }
  const sha256 = requireBoundedString(source.sha256, 'chat attachment upload.sha256', 64);
  if (!/^[0-9a-f]{64}$/i.test(sha256)) {
    throw new Error('chat attachment upload.sha256 must be a SHA-256 hex digest.');
  }
  const mimeType = requireBoundedString(source.mimeType, 'chat attachment upload.mimeType', 128);
  if (![
    'text/plain',
    'text/markdown',
    'text/csv',
    'application/json',
    'application/pdf',
    'image/png',
    'image/jpeg',
    'image/webp'
  ].includes(mimeType)) {
    throw new Error('chat attachment upload.mimeType is unsupported.');
  }
  const attachmentId = requireBoundedString(source.attachmentId, 'chat attachment upload.attachmentId', 128);
  if (!/^[A-Za-z0-9_-]+$/.test(attachmentId)) {
    throw new Error('chat attachment upload.attachmentId is invalid.');
  }
  const fileName = requireBoundedString(source.fileName, 'chat attachment upload.fileName', 240);
  if (fileName === '.' || fileName === '..' || fileName.includes('/') || fileName.includes('\\')) {
    throw new Error('chat attachment upload.fileName is invalid.');
  }
  return {
    attachmentId,
    fileName,
    mimeType,
    byteSize,
    sha256: sha256.toLowerCase()
  };
}

export function decodeGatewayAttachmentCapability(raw: RawJsonValue): GatewayAttachmentCapability {
  const source = requireObject(pick(raw, 'result') ?? raw, 'gateway attachment capability');
  const mimeType = requireBoundedString(
    pick(source, 'mimeType', 'mime_type'),
    'gateway attachment capability.mimeType',
    128
  ).toLowerCase();
  const state = pick(source, 'state');
  if (state !== 'supported' && state !== 'unsupported' && state !== 'unknown') {
    throw new Error('gateway attachment capability.state is unsupported.');
  }
  const reason = requireBoundedString(
    pick(source, 'reason'),
    'gateway attachment capability.reason',
    512,
    { allowEmpty: true }
  );
  const maxBytesRaw = pick(source, 'maxBytes', 'max_bytes');
  let maxBytes: number | undefined;
  if (maxBytesRaw !== undefined && maxBytesRaw !== null) {
    maxBytes = requireCount(maxBytesRaw, 'gateway attachment capability.maxBytes');
    if (maxBytes === 0 || maxBytes > CHAT_ATTACHMENT_MAX_BYTES) {
      throw new Error('gateway attachment capability.maxBytes is out of bounds.');
    }
  }
  return { mimeType, state, reason, maxBytes };
}

export function assertAppendEcho(request: ChatMessageAppendRequest, result: ChatMessageAppendResult): void {
  const message = result.message;
  const timestampsMatch = Math.abs(Date.parse(message.timestamp) - Date.parse(request.timestamp)) < 1;
  const requestedAttachments = request.attachments ?? [];
  const echoedAttachments = message.attachments ?? [];
  const attachmentsMatch =
    requestedAttachments.length === echoedAttachments.length &&
    requestedAttachments.every((requested, index) => {
      const echoed = echoedAttachments[index];
      return (
        echoed?.attachmentId === requested.attachmentId &&
        echoed.fileName === requested.fileName &&
        echoed.mimeType === requested.mimeType &&
        echoed.byteSize === requested.byteSize &&
        echoed.sha256 === requested.sha256
      );
    });
  if (
    message.id !== request.messageID ||
    message.threadID !== request.threadID ||
    message.role !== request.role ||
    message.content !== request.content ||
    message.backendID !== request.backendID ||
    !attachmentsMatch ||
    !timestampsMatch
  ) {
    throw new Error('chat message append response does not match the requested idempotency identity.');
  }
}

export function mapQualitativeAnalysis(raw: RawJsonValue): UsageInsightsQualitativeAnalysis | undefined {
  const source = obj(raw);
  const requestID = str(source.requestID);
  const generatedAt = str(source.generatedAt);
  const executiveSummary = str(source.executiveSummary);
  const modelTag = obj(source.modelTag);
  const modelDisplayName = str(modelTag.displayName, 'Linux local rules');
  if (!requestID || !generatedAt || !executiveSummary) return undefined;
  const citations = arr(source.citations)
    .slice(0, 24)
    .map((rawCitation) => {
      const citation = obj(rawCitation);
      const id = str(citation.id);
      const label = str(citation.label);
      return id && label ? { id, label } : null;
    })
    .filter((citation): citation is UsageInsightsQualitativeCitation => citation !== null);
  const findings = arr(source.findings)
    .slice(0, 6)
    .map((rawFinding) => {
      const finding = obj(rawFinding);
      const id = str(finding.id);
      const title = str(finding.title);
      const whyItMatters = str(finding.whyItMatters);
      const recommendedAction = str(finding.recommendedAction);
      if (!id || !title || !whyItMatters || !recommendedAction) return null;
      const evidence = arr(finding.evidence)
        .slice(0, 8)
        .map((rawCitation) => {
          const citation = obj(rawCitation);
          const citationID = str(citation.id);
          const label = str(citation.label);
          return citationID && label ? { id: citationID, label } : null;
        })
        .filter((citation): citation is UsageInsightsQualitativeCitation => citation !== null);
      return { id, title, whyItMatters, recommendedAction, evidence };
    })
    .filter((finding): finding is UsageInsightsQualitativeFinding => finding !== null);
  return { requestID, generatedAt, executiveSummary, modelDisplayName, findings, citations };
}

export function decodeUsageInsights(raw: RawJsonValue): UsageInsights {
  // The daemon owns both the bounded usage rows and the qualitative result;
  // the bridge only normalizes them for the existing chart/workspace model.
  const events = arr(pick(raw, 'usage', 'events', 'recent'));
  const weekly = buildWeeklyBuckets(events);
  const providerMix = buildMix(events, (e) => str(pick(e, 'providerId', 'provider'), 'unknown'));
  const modelMix = buildMix(events, (e) => str(pick(e, 'modelId', 'model'), 'unknown'));
  const analysis = mapQualitativeAnalysis(pick(raw, 'analysis', 'qualitativeAnalysis'));
  const sourceID = str(pick(raw, 'sourceID', 'sourceId'));
  const sourceLabel = str(pick(raw, 'sourceLabel'), 'daemon-authored qualitative insights');
  return {
    weekly,
    providerMix,
    modelMix,
    cacheHitRatePct: computeCacheHitRatePct(events),
    source: {
      id: analysis ? 'daemon.usage.insights' : 'daemon.usage.recent',
      kind: 'daemon-method',
      label: analysis ? sourceLabel : 'live daemon usage insights'
    },
    qualitative: analysis
      ? {
          state: 'available',
          reason: 'The daemon produced a bounded local-rules brief from usage data only.',
          method: 'daemon.usage.insights',
          sourceID: sourceID || 'daemon.usage.ledger',
          analysis
        }
      : {
          state: 'unavailable',
          reason: 'The connected daemon returned usage aggregates but no qualitative-analysis result.',
          method: 'daemon.usage.insights'
        }
  };
}

// Mirrors macOS CacheEfficiency.hitRate (UnifiedCacheHitRateBadge.swift):
// cacheReadTokens / (inputTokens + cacheCreationTokens + cacheReadTokens),
// prompt-side denominator only. Events may nest token fields under `event`.
export function computeCacheHitRatePct(events: RawJsonValue[]): number {
  let read = 0;
  let create = 0;
  let input = 0;
  for (const e of events) {
    const nested = pick(e, 'event');
    const field = (name: string) => {
      const top = num(pick(e, name));
      return top > 0 ? top : num(pick(nested, name));
    };
    read += Math.max(0, field('cacheReadTokens'));
    create += Math.max(0, field('cacheCreationTokens'));
    input += Math.max(0, field('inputTokens'));
  }
  const basis = input + create + read;
  if (basis <= 0) return 0;
  return Math.round((read / basis) * 100);
}

export function buildWeeklyBuckets(events: RawJsonValue[]): WeeklyPoint[] {
  const buckets: { label: string; tokens: number; costUsd: number }[] = [];
  const now = new Date();
  for (let i = 7; i >= 0; i--) {
    const d = new Date(now);
    d.setDate(d.getDate() - i * 7);
    buckets.push({ label: `W${buckets.length + 1}`, tokens: 0, costUsd: 0 });
  }
  for (const e of events) {
    const at = str(pick(e, 'at', 'timestamp', 'createdAt'));
    const tokens = num(pick(e, 'tokens', 'totalTokens'));
    const cost = num(pick(e, 'costUsd', 'cost'));
    try {
      const diff = (now.getTime() - new Date(at).getTime()) / 86_400_000;
      const weekIdx = 8 - Math.floor(diff / 7);
      if (weekIdx >= 0 && weekIdx < buckets.length) {
        buckets[weekIdx].tokens += tokens;
        buckets[weekIdx].costUsd += cost;
      }
    } catch {
      /* skip */
    }
  }
  return buckets;
}

export function buildMix(
  events: RawJsonValue[],
  keyFn: (e: RawJsonValue) => string
): MixEntry[] {
  const totals = new Map<string, number>();
  let grand = 0;
  for (const e of events) {
    const k = keyFn(e);
    const t = num(pick(e, 'tokens', 'totalTokens'));
    totals.set(k, (totals.get(k) ?? 0) + t);
    grand += t;
  }
  if (grand === 0) return [];
  return [...totals.entries()]
    .map(([id, t]) => ({
      id,
      label: id.charAt(0).toUpperCase() + id.slice(1),
      pct: Math.round((t / grand) * 100)
    }))
    .sort((a, b) => b.pct - a.pct);
}

export function missionFreshness(updatedAt: string): MissionFreshness {
  const timestamp = Date.parse(updatedAt);
  if (!updatedAt || Number.isNaN(timestamp)) return 'unknown';
  const ageMs = Math.max(0, Date.now() - timestamp);
  return ageMs <= 5 * 60_000 ? 'fresh' : 'stale';
}

export function mapMissionApproval(raw: RawJsonValue): MissionApprovalSnapshot | undefined {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return undefined;
  return {
    approved: pick(raw, 'approved') === true,
    approvedAt: str(pick(raw, 'approvedAt', 'approved_at')) || undefined,
    approvedBy: str(pick(raw, 'approvedBy', 'approved_by')) || undefined,
    note: str(pick(raw, 'note')) || undefined
  };
}

export function mapMissionPacket(raw: RawJsonValue, index: number): MissionPacketSnapshot {
  return {
    id: str(pick(raw, 'id', 'packetId', 'packetID'), `packet-${index}`),
    missionId: str(pick(raw, 'missionId', 'missionID', 'mission_id')) || undefined,
    workerName: str(pick(raw, 'workerName', 'worker_name'), 'Unknown worker'),
    objective: str(pick(raw, 'objective', 'summary', 'title'), 'Objective unavailable'),
    status: str(pick(raw, 'status', 'state'), 'unknown'),
    runId: str(pick(raw, 'runId', 'runID', 'run_id')) || undefined,
    dispatchedAt: str(pick(raw, 'dispatchedAt', 'dispatched_at')) || undefined,
    completedAt: str(pick(raw, 'completedAt', 'completed_at')) || undefined,
    metadata: obj(pick(raw, 'metadata'))
  };
}

export function mapMissionPRLinkage(raw: RawJsonValue): MissionPRLinkageSnapshot | undefined {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return undefined;
  const repository = str(pick(raw, 'repository', 'repo'));
  const prNumberOrId = str(pick(raw, 'prNumberOrID', 'prNumberOrId', 'pr_number_or_id', 'number'));
  const url = str(pick(raw, 'url', 'prUrl', 'pr_url'));
  if (!repository && !prNumberOrId && !url) return undefined;
  return {
    schemaVersion: num(pick(raw, 'schemaVersion', 'schema_version')) || undefined,
    repository,
    prNumberOrId,
    url,
    state: str(pick(raw, 'state'), 'unknown'),
    mergeCommitSha: str(pick(raw, 'mergeCommitSHA', 'mergeCommitSha', 'merge_commit_sha')) || undefined,
    mergedAt: str(pick(raw, 'mergedAt', 'merged_at')) || undefined,
    closedAt: str(pick(raw, 'closedAt', 'closed_at')) || undefined
  };
}

export function mapMissionResult(raw: RawJsonValue, index: number): MissionResultSnapshot {
  return {
    id: str(pick(raw, 'id', 'resultId', 'resultID'), `result-${index}`),
    missionId: str(pick(raw, 'missionId', 'missionID', 'mission_id')) || undefined,
    packetId: str(pick(raw, 'packetId', 'packetID', 'packet_id')) || undefined,
    runId: str(pick(raw, 'runId', 'runID', 'run_id')) || undefined,
    status: str(pick(raw, 'status', 'state'), 'unknown'),
    summary: str(pick(raw, 'summary', 'title'), 'Result summary unavailable'),
    detail: str(pick(raw, 'detail', 'description')) || undefined,
    burnDelta: num(pick(raw, 'burnDelta', 'burn_delta')),
    createdAt: str(pick(raw, 'createdAt', 'created_at'), ''),
    evidenceRefs: arr(pick(raw, 'evidenceRefs', 'evidence_refs', 'evidence')).map((value) => str(value)).filter(Boolean),
    prLinkage: mapMissionPRLinkage(pick(raw, 'prLinkage', 'pr_linkage')),
    metadata: obj(pick(raw, 'metadata'))
  };
}

export function mapMissionBurnRecord(raw: RawJsonValue, index: number): MissionBurnRecord {
  return {
    id: str(pick(raw, 'id', 'recordId', 'recordID'), `burn-${index}`),
    label: str(pick(raw, 'label', 'name'), 'Burn record'),
    amount: num(pick(raw, 'amount')),
    unit: str(pick(raw, 'unit'), 'unknown'),
    recordedAt: str(pick(raw, 'recordedAt', 'recorded_at'), '')
  };
}

export function mapMissionTakeover(raw: RawJsonValue, index: number): MissionTakeoverRecord {
  return {
    id: str(pick(raw, 'id', 'takeoverId', 'takeoverID'), `takeover-${index}`),
    projectSlug: str(pick(raw, 'projectSlug', 'project_slug'), ''),
    missionId: str(pick(raw, 'missionId', 'missionID', 'mission_id')) || undefined,
    sourceRunId: str(pick(raw, 'sourceRunId', 'sourceRunID', 'source_run_id')) || undefined,
    takeoverRunId: str(pick(raw, 'takeoverRunId', 'takeoverRunID', 'takeover_run_id')) || undefined,
    status: str(pick(raw, 'status', 'state'), 'unknown'),
    reason: str(pick(raw, 'reason'), 'Reason unavailable'),
    createdAt: str(pick(raw, 'createdAt', 'created_at'), ''),
    updatedAt: str(pick(raw, 'updatedAt', 'updated_at'), ''),
    metadata: obj(pick(raw, 'metadata'))
  };
}

export const MISSION_HEALTH_STATUSES: readonly MissionHealthStatus[] = ['healthy', 'degraded', 'stalled', 'failed', 'unknown'];

export function mapMissionHealth(raw: RawJsonValue): MissionHealthResult {
  const source = pick(raw, 'health') ?? raw;
  const status = str(pick(source, 'status')).toLowerCase() as MissionHealthStatus;
  return {
    missionId: str(pick(raw, 'missionID', 'missionId', 'mission_id'), 'unknown'),
    health: {
      status: MISSION_HEALTH_STATUSES.includes(status) ? status : 'unknown',
      detail: str(pick(source, 'detail'), 'Mission health detail unavailable.'),
      checkedAt: str(pick(source, 'checkedAt', 'checked_at'), ''),
      lastActivityAt: str(pick(source, 'lastActivityAt', 'last_activity_at'), ''),
      activePacketCount: Math.max(0, num(pick(source, 'activePacketCount', 'active_packet_count'))),
      failedResultCount: Math.max(0, num(pick(source, 'failedResultCount', 'failed_result_count')))
    },
    history: arr(pick(raw, 'history')).map((entry, index): MissionHistoryEntry => ({
      id: str(pick(entry, 'id'), `history-${index}`),
      kind: str(pick(entry, 'kind'), 'event'),
      status: str(pick(entry, 'status'), 'unknown'),
      summary: str(pick(entry, 'summary'), 'Mission event'),
      occurredAt: str(pick(entry, 'occurredAt', 'occurred_at'), ''),
      metadata: obj(pick(entry, 'metadata'))
    }))
  };
}

export function mapMissionSnapshot(raw: RawJsonValue, index = 0): MissionRecord {
  const packets = arr(pick(raw, 'packets')).map(mapMissionPacket);
  const results = arr(pick(raw, 'results')).map(mapMissionResult);
  const updatedAt = str(pick(raw, 'updatedAt', 'updated_at', 'modifiedAt'), '');
  const approval = mapMissionApproval(pick(raw, 'approval'));
  return {
    id: str(pick(raw, 'id', 'missionId', 'missionID'), `mission-${index}`),
    title: str(pick(raw, 'title', 'name', 'summary'), 'Untitled mission'),
    state: str(pick(raw, 'state', 'status'), 'active'),
    updatedAt,
    laneCount: packets.length || num(pick(raw, 'laneCount', 'lane_count', 'packetCount')),
    projectSlug: str(pick(raw, 'projectSlug', 'project_slug', 'projectName', 'project'), '') || undefined,
    summary: str(pick(raw, 'summary', 'description')) || undefined,
    recommendation: str(pick(raw, 'recommendation')) || undefined,
    createdAt: str(pick(raw, 'createdAt', 'created_at')) || undefined,
    approval,
    packets,
    results,
    burnRecords: arr(pick(raw, 'burnRecords', 'burn_records')).map(mapMissionBurnRecord),
    takeoverHistory: arr(pick(raw, 'takeoverHistory', 'takeover_history')).map(mapMissionTakeover),
    prLinkage: mapMissionPRLinkage(pick(raw, 'prLinkage', 'pr_linkage')),
    metadata: obj(pick(raw, 'metadata')),
    freshness: missionFreshness(updatedAt)
  };
}

export function mapMissionList(raw: RawJsonValue): MissionListResult {
  const missions = arr(pick(raw, 'missions')).map((mission, index) => mapMissionSnapshot(mission, index));
  const explicitApprovals = arr(pick(raw, 'pendingApprovals', 'approvals', 'questions')).map(
    (a, i): PendingApproval => ({
      id: str(pick(a, 'id', 'approvalId'), `approval-${i}`),
      missionId: str(pick(a, 'missionId', 'missionID', 'mission_id'), 'unknown'),
      summary: str(pick(a, 'summary', 'question', 'prompt', 'body'), 'Approval requested'),
      requestedAt: str(pick(a, 'requestedAt', 'created_at', 'createdAt'), new Date().toISOString()),
      risk: str(pick(a, 'risk', 'severity'), '').toLowerCase().includes('high') ? 'high' : 'standard'
    })
  );
  const pendingApprovals = explicitApprovals.length > 0
    ? explicitApprovals
    : missions
        .filter((mission) => mission.approval?.approved === false && ['draft', 'awaiting_approval'].includes(mission.state))
        .map((mission): PendingApproval => ({
          id: `approval-${mission.id}`,
          missionId: mission.id,
          summary: mission.summary || mission.title,
          requestedAt: mission.createdAt || mission.updatedAt,
          risk: 'standard'
        }));
  return { missions, pendingApprovals };
}

export function mapMissionDetail(raw: RawJsonValue): MissionDetail | null {
  const mission = pick(raw, 'mission') ?? raw;
  if (!mission || typeof mission !== 'object' || Array.isArray(mission)) return null;
  return mapMissionSnapshot(mission);
}

export function mapMissionMutation(raw: RawJsonValue): MissionListResult['missions'][number] | null {
  return mapMissionDetail(raw);
}
