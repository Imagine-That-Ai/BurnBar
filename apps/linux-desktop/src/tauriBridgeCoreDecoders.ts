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
  PendingQuestion,
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
import { providerPathById } from './providerPathRegistry.js';
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

const FOUNDATION_REFERENCE_EPOCH_MS = Date.UTC(2001, 0, 1);
const QUOTA_DATE_MIN_MS = Date.UTC(2000, 0, 1);
const QUOTA_DATE_FUTURE_LIMIT_MS = 10 * 366 * 24 * 60 * 60 * 1000;

export function decodeQuotaDate(value: RawJsonValue, now = Date.now()): string | undefined {
  const milliseconds = typeof value === 'number'
    ? Number.isFinite(value) ? FOUNDATION_REFERENCE_EPOCH_MS + value * 1000 : Number.NaN
    : typeof value === 'string' && value.trim() ? Date.parse(value) : Number.NaN;
  if (!Number.isFinite(milliseconds) || milliseconds < QUOTA_DATE_MIN_MS
      || milliseconds > now + QUOTA_DATE_FUTURE_LIMIT_MS) return undefined;
  return new Date(milliseconds).toISOString();
}

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

function requireNonNegativeNumber(value: RawJsonValue, label: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    throw new Error(`${label} must be a non-negative finite number.`);
  }
  return value;
}

function requireNonNegativeSafeInteger(value: RawJsonValue, label: string): number {
  const number = requireNonNegativeNumber(value, label);
  if (!Number.isSafeInteger(number)) {
    throw new Error(`${label} must be a safe integer.`);
  }
  return number;
}

function utcDayKeys(now: number): string[] {
  const date = new Date(now);
  if (!Number.isFinite(date.getTime())) throw new Error('usage summary current time is invalid.');
  const today = Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate());
  return Array.from({ length: 7 }, (_, index) =>
    new Date(today - (6 - index) * 86_400_000).toISOString().slice(0, 10)
  );
}

function isCanonicalUTCDay(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

function addSafeInteger(current: number, increment: number, label: string): number {
  const sum = current + increment;
  if (!Number.isSafeInteger(sum)) throw new Error(`${label} must remain a safe integer.`);
  return sum;
}

function addFiniteNumber(current: number, increment: number, label: string): number {
  const sum = current + increment;
  if (!Number.isFinite(sum)) throw new Error(`${label} must remain finite.`);
  return sum;
}

export function mapUsageSummary(raw: RawJsonValue, now = Date.now()): UsageSummary {
  const source = requireObject(raw, 'usage summary');
  const projection = requireObject(source.projection, 'usage summary projection');
  const totals = requireObject(projection.totals, 'usage summary projection totals');
  requireNonNegativeSafeInteger(totals.totalTokens, 'usage summary projection totals.totalTokens');
  requireNonNegativeNumber(totals.cost, 'usage summary projection totals.cost');

  const dayKeys = utcDayKeys(now);
  const dayIndex = new Map(dayKeys.map((day, index) => [day, index]));
  const sevenDay = [0, 0, 0, 0, 0, 0, 0];
  const sevenDayCost = [0, 0, 0, 0, 0, 0, 0];
  const buckets = projection.buckets;
  if (!Array.isArray(buckets)) throw new Error('usage summary projection.buckets must be an array.');
  buckets.forEach((rawBucket, index) => {
    const bucket = requireObject(rawBucket, `usage summary projection.buckets[${index}]`);
    const dayUTC = requireString(bucket.dayUTC, `usage summary projection.buckets[${index}].dayUTC`);
    if (!isCanonicalUTCDay(dayUTC)) {
      throw new Error(`usage summary projection.buckets[${index}].dayUTC must be a UTC calendar day.`);
    }
    const bucketTotals = requireObject(bucket.totals, `usage summary projection.buckets[${index}].totals`);
    const tokens = requireNonNegativeSafeInteger(
      bucketTotals.totalTokens,
      `usage summary projection.buckets[${index}].totals.totalTokens`
    );
    const cost = requireNonNegativeNumber(
      bucketTotals.cost,
      `usage summary projection.buckets[${index}].totals.cost`
    );
    const target = dayIndex.get(dayUTC);
    if (target !== undefined) {
      sevenDay[target] = addSafeInteger(
        sevenDay[target]!,
        tokens,
        `usage summary projection day ${dayUTC} totalTokens`
      );
      sevenDayCost[target] = addFiniteNumber(
        sevenDayCost[target]!,
        cost,
        `usage summary projection day ${dayUTC} cost`
      );
    }
  });

  // Recent rows are presentation-only. All totals come from the daemon-owned
  // projection so a bounded activity response can never undercount history.
  const recent = requireObject(source.recent, 'usage summary recent response');
  const events = arr(pick(recent, 'usage', 'events', 'recent')).map(
    (e, i): UsageEvent => ({
      id: str(pick(e, 'id', 'event_id'), `evt-${i}`),
      provider: str(pick(e, 'providerId', 'provider', 'provider_id'), 'unknown'),
      model: str(pick(e, 'modelId', 'model', 'model_id'), 'unknown'),
      tokens: usageEventTokenTotal(e),
      cost: num(pick(e, 'costUsd', 'cost', 'estimatedCostUsd')),
      at: str(pick(e, 'at', 'timestamp', 'createdAt', 'recordedAt'), new Date().toISOString())
    })
  );
  return {
    todayTokens: sevenDay[6],
    todayCostUsd: sevenDayCost[6],
    sevenDay,
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
    const id = normalizedCatalogID(pick(bucket, 'id', 'bucketId', 'key', 'name'), MODEL_ID_PATTERN);
    const label = str(pick(bucket, 'label', 'name')).trim();
    if (!id && !label) return [];
    const stableID = id ?? label.toLowerCase().replace(/[^a-z0-9._:/-]+/g, '-').replace(/^-+|-+$/g, '');
    if (!stableID) return [];
    const directUsed = num(pick(bucket, 'usedPct', 'usedPercentage', 'usedPercent', 'pct'), Number.NaN);
    const usedValue = num(pick(bucket, 'usedValue', 'used'), Number.NaN);
    const limitValue = num(pick(bucket, 'limitValue', 'limit'), Number.NaN);
    const remainingValue = num(pick(bucket, 'remainingValue', 'remaining'), Number.NaN);
    const usedPct = Number.isFinite(directUsed)
      ? directUsed
      : Number.isFinite(usedValue) && Number.isFinite(limitValue) && limitValue > 0
        ? usedValue / limitValue * 100
        : Number.isFinite(remainingValue) && Number.isFinite(limitValue) && limitValue > 0
          ? (1 - remainingValue / limitValue) * 100
          : Number.NaN;
    if (!Number.isFinite(usedPct)) return [];
    const reset = decodeQuotaDate(pick(bucket, 'resetsAt', 'resetAt'));
    const explicitState = str(pick(bucket, 'state', 'status')).trim();
    const state = explicitState
      ? normalizeQuotaState(explicitState)
      : Number.isFinite(remainingValue)
        ? remainingValue <= 0 ? 'exhausted' : 'ok'
        : 'unknown';
    return [{
      id: stableID,
      label: label || stableID,
      usedPct: Math.min(100, Math.max(0, usedPct)),
      resetsAt: reset,
      state
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
  const quotaResponse = pick(raw, 'quota');
  const quotaSnapshots = arr(pick(quotaResponse, 'snapshots'));
  const providerIdentifier = (value: RawJsonValue): RawJsonValue => {
    const candidate = pick(value, 'providerID', 'providerId', 'provider', 'provider_id');
    return typeof candidate === 'object' && candidate !== null ? pick(candidate, 'rawValue') : candidate;
  };
  const providerIDs = new Map<string, string>();
  const addProviderID = (value: RawJsonValue) => {
    const id = normalizedCatalogID(value, PROVIDER_ID_PATTERN);
    if (id) providerIDs.set(id.toLowerCase(), id);
  };
  configuredProviders.forEach((provider) => addProviderID(pick(provider, 'id', 'providerId', 'providerID', 'provider_id')));
  catalogProviders.forEach((provider) => addProviderID(pick(provider, 'id', 'providerId', 'providerID', 'provider_id')));
  arr(pick(snapshot, 'credentialSlots', 'providerCredentialSlots')).forEach((slot) => addProviderID(pick(slot, 'providerId', 'providerID', 'provider_id')));
  quotaSnapshots.forEach((quotaSnapshot) => addProviderID(providerIdentifier(quotaSnapshot)));

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
    const canonicalPath = providerPathById(providerID);
    const quotaSnapshot = quotaSnapshots.find((candidate) => {
      const candidateID = str(providerIdentifier(candidate)).trim();
      return candidateID.toLowerCase() === providerID.toLowerCase()
        || providerPathById(candidateID)?.providerId === canonicalPath?.providerId;
    });
    const quotaMetadata = quotaSnapshot ?? provider ?? catalogProvider;
    const quotaSourceKind = normalizeQuotaSourceKind(
      pick(quotaMetadata, 'quotaSourceKind', 'quota_source_kind', 'sourceKind', 'source_kind')
    );
    const quotaSource = str(pick(quotaMetadata, 'quotaSource', 'quota_source', 'sourceLabel', 'source_label', 'source')).trim() || undefined;
    const quotaConfidence = normalizeQuotaConfidence(
      pick(quotaMetadata, 'quotaConfidence', 'quota_confidence', 'confidence')
    );
    const accountStorage = str(pick(quotaMetadata, 'accountStorage', 'account_storage', 'storageScope', 'storage_scope')).trim().toLowerCase();
    const normalizedAccountStorage = ['cloud', 'local', 'keychain', 'unknown'].includes(accountStorage)
      ? accountStorage as ProviderCatalogEntry['accountStorage']
      : undefined;
    const planTierBadge = str(pick(quotaMetadata, 'planTierBadge', 'plan_tier_badge', 'planTier', 'plan_tier')).trim() || undefined;
    const quotaSourceID = str(pick(quotaSnapshot, 'sourceId', 'sourceID')).trim() || undefined;
    const quotaFetchedAt = decodeQuotaDate(pick(quotaSnapshot, 'fetchedAt'));
    const quotaUpdatedAt = decodeQuotaDate(pick(quotaSnapshot, 'updatedAt'));
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
      quotaBuckets: mapQuotaBuckets(quotaSnapshot ?? provider ?? catalogProvider),
      ...(quotaSourceKind ? { quotaSourceKind } : {}),
      ...(quotaSource ? { quotaSource } : {}),
      ...(quotaConfidence ? { quotaConfidence } : {}),
      ...(quotaSourceID ? { quotaSourceID } : {}),
      ...(quotaFetchedAt ? { quotaFetchedAt } : {}),
      ...(quotaUpdatedAt ? { quotaUpdatedAt } : {}),
      ...(quotaConfidence ? { quotaStale: quotaConfidence === 'stale' } : {}),
      ...(canonicalPath ? { canonicalProviderID: canonicalPath.providerId, providerAliases: [...canonicalPath.aliases] } : {}),
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
    junie: 'Junie',
    fx: 'fx',
    vercel_fx: 'fx',
    vercel_fx_agent: 'fx',
    muse: 'Muse Code',
    muse_code: 'Muse Code',
    meta_muse: 'Muse Code'
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
    'image/webp',
    'audio/mpeg',
    'audio/wav',
    'audio/mp4',
    'audio/aac',
    'audio/flac',
    'audio/aiff'
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
  const events = arr(pick(raw, 'usage', 'events', 'recent')).filter((event) => (
    usageEventTimestamp(event) !== undefined
  ));
  const weekly = buildWeeklyBuckets(events);
  const providerMix = buildMix(events, (e) => str(pick(e, 'providerID', 'providerId', 'provider'), 'unknown'));
  const modelMix = buildMix(events, (e) => str(pick(e, 'modelID', 'modelId', 'model'), 'unknown'));
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

function usageEventTimestamp(event: RawJsonValue, now = Date.now()): number | undefined {
  const raw = pick(event, 'recordedAt', 'at', 'timestamp', 'createdAt');
  if (typeof raw !== 'string' || raw.trim().length === 0) return undefined;
  const timestamp = Date.parse(raw);
  if (!Number.isFinite(timestamp) || timestamp > now) return undefined;
  return timestamp;
}

function usageEventTokenTotal(event: RawJsonValue): number {
  const explicit = pick(event, 'tokens', 'totalTokens');
  if (explicit !== undefined) {
    const value = num(explicit, Number.NaN);
    return Number.isFinite(value) && value >= 0 ? value : 0;
  }

  let total = 0;
  for (const field of [
    'inputTokens',
    'outputTokens',
    'cacheCreationTokens',
    'cacheReadTokens',
    'reasoningTokens'
  ]) {
    const raw = pick(event, field);
    if (raw === undefined) continue;
    const value = num(raw, Number.NaN);
    if (!Number.isFinite(value) || value < 0) return 0;
    total += value;
  }
  return total;
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
    const at = usageEventTimestamp(e, now.getTime());
    if (at === undefined) continue;
    const tokens = usageEventTokenTotal(e);
    const cost = Math.max(0, num(pick(e, 'costUsd', 'cost')));
    const diff = (now.getTime() - at) / 86_400_000;
    const weekIdx = 7 - Math.floor(diff / 7);
    if (weekIdx >= 0 && weekIdx < buckets.length) {
      buckets[weekIdx].tokens += tokens;
      buckets[weekIdx].costUsd += cost;
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
    const t = usageEventTokenTotal(e);
    if (t <= 0) continue;
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

const MISSION_DATE_MIN_MS = Date.UTC(2000, 0, 1);
const MISSION_DATE_MAX_MS = Date.UTC(2100, 0, 1);

export function decodeMissionTimestamp(value: RawJsonValue, label: string): string {
  if (value === undefined || value === null || value === '') {
    throw new Error(`${label} is required.`);
  }
  if (typeof value === 'string') return requireTimestamp(value, label);
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Error(`${label} must be an ISO-8601 timestamp or Foundation-reference seconds.`);
  }
  const milliseconds = FOUNDATION_REFERENCE_EPOCH_MS + value * 1_000;
  if (!Number.isFinite(milliseconds) || milliseconds < MISSION_DATE_MIN_MS || milliseconds >= MISSION_DATE_MAX_MS) {
    throw new Error(`${label} is outside the supported date range.`);
  }
  return new Date(milliseconds).toISOString();
}

function optionalMissionTimestamp(value: RawJsonValue, label: string): string | undefined {
  if (value === undefined || value === null || value === '') return undefined;
  return decodeMissionTimestamp(value, label);
}

function missionArray(value: RawJsonValue, label: string, limit: number): RawJsonValue[] {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value) || value.length > limit) {
    throw new Error(`${label} must contain at most ${limit} entries.`);
  }
  return value;
}

function missionMetadata(value: RawJsonValue, label: string): Record<string, RawJsonValue> {
  if (value === undefined || value === null) return {};
  return requireObject(value, label);
}

function requireMissionNumber(value: RawJsonValue, label: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Error(`${label} must be a finite number.`);
  }
  return value;
}

export function mapMissionApproval(raw: RawJsonValue): MissionApprovalSnapshot | undefined {
  if (raw === undefined || raw === null) return undefined;
  const source = requireObject(raw, 'mission approval');
  return {
    approved: requireBoolean(source.approved, 'mission approval approved'),
    approvedAt: optionalMissionTimestamp(pick(source, 'approvedAt', 'approved_at'), 'mission approval approvedAt'),
    approvedBy: optionalBoundedString(pick(source, 'approvedBy', 'approved_by'), 'mission approval approvedBy', 256),
    note: optionalBoundedString(source.note, 'mission approval note', 8_192)
  };
}

export function mapMissionPacket(raw: RawJsonValue, index: number): MissionPacketSnapshot {
  const source = requireObject(raw, `mission packet ${index}`);
  return {
    id: requireBoundedString(pick(source, 'id', 'packetId', 'packetID'), `mission packet ${index} id`, 256),
    missionId: optionalBoundedString(pick(source, 'missionId', 'missionID', 'mission_id'), `mission packet ${index} missionId`, 256),
    workerName: requireBoundedString(pick(source, 'workerName', 'worker_name'), `mission packet ${index} workerName`, 512),
    objective: requireBoundedString(pick(source, 'objective', 'summary', 'title'), `mission packet ${index} objective`, 16_384),
    status: requireBoundedString(pick(source, 'status', 'state'), `mission packet ${index} status`, 64),
    runId: optionalBoundedString(pick(source, 'runId', 'runID', 'run_id'), `mission packet ${index} runId`, 512),
    dispatchedAt: optionalMissionTimestamp(pick(source, 'dispatchedAt', 'dispatched_at'), `mission packet ${index} dispatchedAt`),
    completedAt: optionalMissionTimestamp(pick(source, 'completedAt', 'completed_at'), `mission packet ${index} completedAt`),
    metadata: missionMetadata(source.metadata, `mission packet ${index} metadata`)
  };
}

export function mapMissionPRLinkage(raw: RawJsonValue): MissionPRLinkageSnapshot | undefined {
  if (raw === undefined || raw === null) return undefined;
  const source = requireObject(raw, 'mission PR linkage');
  return {
    schemaVersion: source.schemaVersion === undefined && source.schema_version === undefined
      ? undefined
      : requireCount(pick(source, 'schemaVersion', 'schema_version'), 'mission PR schemaVersion'),
    repository: requireBoundedString(pick(source, 'repository', 'repo'), 'mission PR repository', 1_024),
    prNumberOrId: requireBoundedString(
      pick(source, 'prNumberOrID', 'prNumberOrId', 'pr_number_or_id', 'number'),
      'mission PR number or ID',
      256
    ),
    url: requireBoundedString(pick(source, 'url', 'prUrl', 'pr_url'), 'mission PR URL', 2_048),
    state: requireBoundedString(source.state, 'mission PR state', 64),
    mergeCommitSha: optionalBoundedString(
      pick(source, 'mergeCommitSHA', 'mergeCommitSha', 'merge_commit_sha'),
      'mission PR merge commit SHA',
      128
    ),
    mergedAt: optionalMissionTimestamp(pick(source, 'mergedAt', 'merged_at'), 'mission PR mergedAt'),
    closedAt: optionalMissionTimestamp(pick(source, 'closedAt', 'closed_at'), 'mission PR closedAt')
  };
}

export function mapMissionResult(raw: RawJsonValue, index: number): MissionResultSnapshot {
  const source = requireObject(raw, `mission result ${index}`);
  return {
    id: requireBoundedString(pick(source, 'id', 'resultId', 'resultID'), `mission result ${index} id`, 256),
    missionId: optionalBoundedString(pick(source, 'missionId', 'missionID', 'mission_id'), `mission result ${index} missionId`, 256),
    packetId: optionalBoundedString(pick(source, 'packetId', 'packetID', 'packet_id'), `mission result ${index} packetId`, 256),
    runId: optionalBoundedString(pick(source, 'runId', 'runID', 'run_id'), `mission result ${index} runId`, 512),
    status: requireBoundedString(pick(source, 'status', 'state'), `mission result ${index} status`, 64),
    summary: requireBoundedString(pick(source, 'summary', 'title'), `mission result ${index} summary`, 16_384),
    detail: optionalBoundedString(pick(source, 'detail', 'description'), `mission result ${index} detail`, 65_536),
    burnDelta: requireMissionNumber(pick(source, 'burnDelta', 'burn_delta'), `mission result ${index} burnDelta`),
    createdAt: decodeMissionTimestamp(pick(source, 'createdAt', 'created_at'), `mission result ${index} createdAt`),
    evidenceRefs: missionArray(pick(source, 'evidenceRefs', 'evidence_refs', 'evidence'), `mission result ${index} evidenceRefs`, 100)
      .map((value, evidenceIndex) => requireBoundedString(value, `mission result ${index} evidenceRefs[${evidenceIndex}]`, 2_048)),
    prLinkage: mapMissionPRLinkage(pick(source, 'prLinkage', 'pr_linkage')),
    metadata: missionMetadata(source.metadata, `mission result ${index} metadata`)
  };
}

export function mapMissionBurnRecord(raw: RawJsonValue, index: number): MissionBurnRecord {
  const source = requireObject(raw, `mission burn ${index}`);
  return {
    id: requireBoundedString(pick(source, 'id', 'recordId', 'recordID'), `mission burn ${index} id`, 256),
    label: requireBoundedString(pick(source, 'label', 'name'), `mission burn ${index} label`, 512),
    amount: requireMissionNumber(source.amount, `mission burn ${index} amount`),
    unit: requireBoundedString(source.unit, `mission burn ${index} unit`, 64),
    recordedAt: decodeMissionTimestamp(pick(source, 'recordedAt', 'recorded_at'), `mission burn ${index} recordedAt`)
  };
}

export function mapMissionTakeover(raw: RawJsonValue, index: number): MissionTakeoverRecord {
  const source = requireObject(raw, `mission takeover ${index}`);
  return {
    id: requireBoundedString(pick(source, 'id', 'takeoverId', 'takeoverID'), `mission takeover ${index} id`, 256),
    projectSlug: requireBoundedString(pick(source, 'projectSlug', 'project_slug'), `mission takeover ${index} projectSlug`, 256),
    missionId: optionalBoundedString(pick(source, 'missionId', 'missionID', 'mission_id'), `mission takeover ${index} missionId`, 256),
    sourceRunId: optionalBoundedString(pick(source, 'sourceRunId', 'sourceRunID', 'source_run_id'), `mission takeover ${index} sourceRunId`, 512),
    takeoverRunId: optionalBoundedString(pick(source, 'takeoverRunId', 'takeoverRunID', 'takeover_run_id'), `mission takeover ${index} takeoverRunId`, 512),
    status: requireBoundedString(pick(source, 'status', 'state'), `mission takeover ${index} status`, 64),
    reason: requireBoundedString(source.reason, `mission takeover ${index} reason`, 16_384),
    createdAt: decodeMissionTimestamp(pick(source, 'createdAt', 'created_at'), `mission takeover ${index} createdAt`),
    updatedAt: decodeMissionTimestamp(pick(source, 'updatedAt', 'updated_at'), `mission takeover ${index} updatedAt`),
    metadata: missionMetadata(source.metadata, `mission takeover ${index} metadata`)
  };
}

export const MISSION_HEALTH_STATUSES: readonly MissionHealthStatus[] = ['healthy', 'degraded', 'stalled', 'failed', 'unknown'];

export function mapMissionHealth(raw: RawJsonValue): MissionHealthResult {
  const root = requireObject(raw, 'mission health response');
  const source = requireObject(root.health ?? raw, 'mission health');
  const history = missionArray(root.history, 'mission health history', 1_000);
  return {
    missionId: requireBoundedString(pick(root, 'missionID', 'missionId', 'mission_id'), 'mission health missionId', 256),
    health: {
      status: requireKnownValue(source.status, MISSION_HEALTH_STATUSES, 'mission health status'),
      detail: requireBoundedString(source.detail, 'mission health detail', 16_384),
      checkedAt: decodeMissionTimestamp(pick(source, 'checkedAt', 'checked_at'), 'mission health checkedAt'),
      lastActivityAt: decodeMissionTimestamp(pick(source, 'lastActivityAt', 'last_activity_at'), 'mission health lastActivityAt'),
      activePacketCount: requireCount(pick(source, 'activePacketCount', 'active_packet_count'), 'mission health activePacketCount'),
      failedResultCount: requireCount(pick(source, 'failedResultCount', 'failed_result_count'), 'mission health failedResultCount')
    },
    history: history.map((entry, index): MissionHistoryEntry => {
      const row = requireObject(entry, `mission history ${index}`);
      return {
        id: requireBoundedString(row.id, `mission history ${index} id`, 512),
        kind: requireBoundedString(row.kind, `mission history ${index} kind`, 64),
        status: requireBoundedString(row.status, `mission history ${index} status`, 64),
        summary: requireBoundedString(row.summary, `mission history ${index} summary`, 16_384),
        occurredAt: decodeMissionTimestamp(pick(row, 'occurredAt', 'occurred_at'), `mission history ${index} occurredAt`),
        metadata: missionMetadata(row.metadata, `mission history ${index} metadata`)
      };
    })
  };
}

const MISSION_STATUSES = [
  'draft',
  'awaiting_approval',
  'approved',
  'dispatching',
  'in_progress',
  'partially_completed',
  'completed',
  'failed',
  'cancelled'
] as const;

export function mapMissionSnapshot(raw: RawJsonValue, index = 0): MissionRecord {
  const source = requireObject(raw, `mission ${index}`);
  const packets = missionArray(source.packets, `mission ${index} packets`, 1_000).map(mapMissionPacket);
  const results = missionArray(source.results, `mission ${index} results`, 1_000).map(mapMissionResult);
  const updatedAt = decodeMissionTimestamp(pick(source, 'updatedAt', 'updated_at', 'modifiedAt'), `mission ${index} updatedAt`);
  const approval = mapMissionApproval(source.approval);
  return {
    id: requireBoundedString(pick(source, 'id', 'missionId', 'missionID'), `mission ${index} id`, 256),
    title: requireBoundedString(pick(source, 'title', 'name'), `mission ${index} title`, 512),
    state: requireKnownValue(pick(source, 'state', 'status'), MISSION_STATUSES, `mission ${index} status`),
    updatedAt,
    laneCount: packets.length,
    projectSlug: optionalBoundedString(pick(source, 'projectSlug', 'project_slug', 'projectName', 'project'), `mission ${index} projectSlug`, 256),
    summary: optionalBoundedString(pick(source, 'summary', 'description'), `mission ${index} summary`, 16_384),
    recommendation: optionalBoundedString(source.recommendation, `mission ${index} recommendation`, 64),
    createdAt: optionalMissionTimestamp(pick(source, 'createdAt', 'created_at'), `mission ${index} createdAt`),
    approval,
    packets,
    results,
    burnRecords: missionArray(pick(source, 'burnRecords', 'burn_records'), `mission ${index} burnRecords`, 1_000).map(mapMissionBurnRecord),
    takeoverHistory: missionArray(pick(source, 'takeoverHistory', 'takeover_history'), `mission ${index} takeoverHistory`, 1_000).map(mapMissionTakeover),
    prLinkage: mapMissionPRLinkage(pick(source, 'prLinkage', 'pr_linkage')),
    metadata: missionMetadata(source.metadata, `mission ${index} metadata`),
    freshness: missionFreshness(updatedAt)
  };
}

const QUESTION_STATUSES = ['pending', 'answered', 'dismissed', 'expired'] as const;
const QUESTION_PRIORITIES = ['low', 'medium', 'high', 'critical'] as const;
const QUESTION_DEEP_LINK_KINDS = ['session_log', 'dashboard', 'project', 'settings'] as const;

function requireKnownValue<const T extends readonly string[]>(
  value: RawJsonValue,
  values: T,
  label: string
): T[number] {
  const parsed = requireBoundedString(value, label, 64);
  if (!values.includes(parsed as T[number])) throw new Error(`${label} is unsupported.`);
  return parsed as T[number];
}

export function mapPendingQuestion(raw: RawJsonValue, index = 0): PendingQuestion {
  const source = requireObject(raw, `question[${index}]`);
  const evidence = source.evidenceRefs ?? source.evidence_refs ?? [];
  if (!Array.isArray(evidence) || evidence.length > 100) {
    throw new Error(`question[${index}].evidenceRefs must contain at most 100 entries.`);
  }
  const options = source.suggestedOptions ?? source.suggested_options ?? [];
  if (!Array.isArray(options) || options.length > 20) {
    throw new Error(`question[${index}].suggestedOptions must contain at most 20 entries.`);
  }
  const deepLinkRaw = source.deepLink ?? source.deep_link;
  const deepLink = deepLinkRaw === undefined || deepLinkRaw === null
    ? undefined
    : (() => {
        const value = requireObject(deepLinkRaw, `question[${index}].deepLink`);
        return {
          kind: requireKnownValue(value.kind, QUESTION_DEEP_LINK_KINDS, `question[${index}].deepLink.kind`),
          targetId: optionalBoundedString(
            value.targetID ?? value.targetId ?? value.target_id,
            `question[${index}].deepLink.targetID`,
            512
          ),
          title: requireBoundedString(value.title, `question[${index}].deepLink.title`, 512),
          subtitle: optionalBoundedString(value.subtitle, `question[${index}].deepLink.subtitle`, 1_024)
        };
      })();
  return {
    id: requireBoundedString(source.id, `question[${index}].id`, 256),
    projectSlug: requireBoundedString(
      source.projectSlug ?? source.project_slug,
      `question[${index}].projectSlug`,
      256
    ),
    sessionId: optionalBoundedString(
      source.sessionID ?? source.sessionId ?? source.session_id,
      `question[${index}].sessionID`,
      512
    ),
    title: requireBoundedString(source.title, `question[${index}].title`, 512),
    prompt: requireBoundedString(source.prompt, `question[${index}].prompt`, 16_384),
    stageLabel: optionalBoundedString(
      source.stageLabel ?? source.stage_label,
      `question[${index}].stageLabel`,
      256
    ),
    status: requireKnownValue(source.status, QUESTION_STATUSES, `question[${index}].status`),
    priority: requireKnownValue(source.priority, QUESTION_PRIORITIES, `question[${index}].priority`),
    askedAt: decodeMissionTimestamp(source.askedAt ?? source.asked_at, `question[${index}].askedAt`),
    dueAt: source.dueAt === undefined && source.due_at === undefined
      ? undefined
      : decodeMissionTimestamp(source.dueAt ?? source.due_at, `question[${index}].dueAt`),
    answerPlaceholder: optionalBoundedString(
      source.answerPlaceholder ?? source.answer_placeholder,
      `question[${index}].answerPlaceholder`,
      1_024
    ),
    contextSummary: optionalBoundedString(
      source.contextSummary ?? source.context_summary,
      `question[${index}].contextSummary`,
      8_192
    ),
    evidenceRefs: evidence.map((value, evidenceIndex) =>
      requireBoundedString(value, `question[${index}].evidenceRefs[${evidenceIndex}]`, 2_048)
    ),
    suggestedOptions: options.map((rawOption, optionIndex) => {
      const option = requireObject(rawOption, `question[${index}].suggestedOptions[${optionIndex}]`);
      return {
        id: requireBoundedString(option.id, `question[${index}].suggestedOptions[${optionIndex}].id`, 256),
        title: requireBoundedString(option.title, `question[${index}].suggestedOptions[${optionIndex}].title`, 512),
        detail: optionalBoundedString(option.detail, `question[${index}].suggestedOptions[${optionIndex}].detail`, 2_048),
        answer: requireBoundedString(option.answer, `question[${index}].suggestedOptions[${optionIndex}].answer`, 8_192)
      };
    }),
    deepLink
  };
}

export function mapQuestionList(raw: RawJsonValue): PendingQuestion[] {
  const source = requireObject(raw, 'question list');
  if (!Array.isArray(source.questions) || source.questions.length > 100) {
    throw new Error('question list must contain at most 100 questions.');
  }
  return source.questions.map((question, index) => mapPendingQuestion(question, index));
}

export function mapQuestionAnswer(raw: RawJsonValue): PendingQuestion {
  const source = requireObject(raw, 'question answer');
  return mapPendingQuestion(source.question, 0);
}

export function mapMissionList(raw: RawJsonValue): MissionListResult {
  const source = requireObject(raw, 'mission list');
  if (!Array.isArray(source.missions) || source.missions.length > 1_000) {
    throw new Error('mission list must contain at most 1000 missions.');
  }
  const missions = source.missions.map((mission, index) => mapMissionSnapshot(mission, index));
  const approvalsRaw = pick(source, 'pendingApprovals', 'approvals', 'questions');
  const explicitApprovals = missionArray(approvalsRaw, 'mission pending approvals', 1_000).map(
    (rawApproval, index): PendingApproval => {
      const approval = requireObject(rawApproval, `mission pending approval ${index}`);
      const risk = requireBoundedString(pick(approval, 'risk', 'severity'), `mission pending approval ${index} risk`, 64);
      if (risk !== 'standard' && risk !== 'high') {
        throw new Error(`mission pending approval ${index} risk is unsupported.`);
      }
      return {
        id: requireBoundedString(pick(approval, 'id', 'approvalId'), `mission pending approval ${index} id`, 256),
        missionId: requireBoundedString(pick(approval, 'missionId', 'missionID', 'mission_id'), `mission pending approval ${index} missionId`, 256),
        summary: requireBoundedString(pick(approval, 'summary', 'question', 'prompt', 'body'), `mission pending approval ${index} summary`, 16_384),
        requestedAt: decodeMissionTimestamp(pick(approval, 'requestedAt', 'created_at', 'createdAt'), `mission pending approval ${index} requestedAt`),
        risk
      };
    }
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
