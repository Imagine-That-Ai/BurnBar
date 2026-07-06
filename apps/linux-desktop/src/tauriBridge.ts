import { invoke } from '@tauri-apps/api/core';
import { open as openExternal } from '@tauri-apps/plugin-shell';
import type { DaemonHealth } from './daemonClient.js';
import { ENTITLEMENT_DOC_IDS, evaluateEntitlement } from '@openburnbar/entitlements';

// ─────────────────────────── P01: usage summary ───────────────────────────

export type UsageSummary = {
  todayTokens: number;
  todayCostUsd: number;
  sevenDay: number[];
  recentEvents: { id: string; title: string; detail: string; at: string }[];
};

// ─────────────────────────── P02: provider catalog ─────────────────────────

export type QuotaBucketState = 'ok' | 'cooling_down' | 'missing_credential' | 'exhausted';
export type QuotaBucket = {
  id: string;
  label: string;
  usedPct: number;
  resetsAt?: string;
  state: QuotaBucketState;
};
export type ProviderCatalogEntry = {
  id: string;
  label: string;
  accountLabel: string;
  quotaBuckets: QuotaBucket[];
};
export type ProviderCatalog = ProviderCatalogEntry[];

// ─────────────────────────── P03: sessions ────────────────────────────────

export type SessionEntry = {
  id: string;
  provider: string;
  model: string;
  startedAt: string;
  tokens: number;
  costUsd: number;
  title: string;
};
export type SessionListResult = { sessions: SessionEntry[]; nextCursor: string | null };

// ─────────────────────────── P05: insights ────────────────────────────────

export type WeeklyPoint = { label: string; tokens: number; costUsd: number };
export type MixEntry = { id: string; label: string; pct: number };
export type UsageInsights = {
  weekly: WeeklyPoint[];
  providerMix: MixEntry[];
  modelMix: MixEntry[];
  cacheHitRatePct: number;
};

// ─────────────────────────── P06: missions ────────────────────────────────

export type PendingApproval = {
  id: string;
  missionId: string;
  summary: string;
  requestedAt: string;
  risk: 'standard' | 'high';
};
export type MissionListResult = {
  missions: {
    id: string;
    title: string;
    state: string;
    updatedAt: string;
    laneCount: number;
    projectSlug?: string;
  }[];
  pendingApprovals: PendingApproval[];
};
export type ApprovalDecision = 'approve' | 'deny';
export type MissionCreateInput = {
  projectSlug: string;
  title: string;
  summary: string;
};

// ─────────────────────────── P07: system ──────────────────────────────────

export type ConfigSnapshot = {
  paths: {
    supportDir: string;
    socketPath: string;
    configDir: string;
    providerLogPaths: string[];
  };
  secretServiceStatus: string;
  telemetryEnabled: boolean;
  privacyOptIn: boolean;
  providers?: ProviderSettings[];
  routerMode?: string;
};
export type ProviderCredentialSlot = {
  slotID: string;
  label: string;
  isEnabled: boolean;
  status: string;
  cooldownUntil?: string;
  lastQuotaRemainingPercent?: number;
  lastQuotaResetsAt?: string;
  lastStatusMessage?: string;
  endpointProfileID?: string;
  authMethodID?: string;
  updatedAt?: string;
};
export type ModelVariant = {
  variantID: string;
  label: string;
  baseModelID: string;
  thinkingLevel: 'low' | 'medium' | 'high' | 'xhigh' | 'max';
  maxOutputTokens?: number | null;
  createdAt?: string;
  updatedAt?: string;
};
export type ModelAlias = {
  aliasID: string;
  baseModelID: string;
  displayName: string;
  hidesBaseModel: boolean;
  createdAt?: string;
  updatedAt?: string;
};
export type ModelDisplayOverride = {
  modelID: string;
  displayName: string;
  createdAt?: string;
  updatedAt?: string;
};
export type CustomModel = {
  modelID: string;
  displayName: string;
  createdAt?: string;
  updatedAt?: string;
};
export type ProviderSettings = {
  providerID: string;
  isEnabled: boolean;
  baseURL: string;
  preferredModelIDs: string[];
  disabledAdvertisedModelIDs: string[];
  preferredCredentialSlotID?: string;
  credentialSlots: ProviderCredentialSlot[];
  modelVariants: ModelVariant[];
  modelAliases: ModelAlias[];
  modelDisplayOverrides: ModelDisplayOverride[];
  customModels: CustomModel[];
};
export type DbStatus = {
  sqlcipherOk: boolean;
  migrationVersion: number;
  sizeBytes: number;
  walMode: boolean;
};
export type ProjectEntry = { id: string; name: string; path: string; scope: string };
export type MemoryBoundary = { id: string; scope: string; label: string; detail: string };
export type MemoryReviewStatus = 'pending' | 'approved' | 'rejected';
export type MemoryReviewItem = {
  id: string;
  body: string;
  kind: string;
  confidence: number;
  sourceLabel: string;
  status: MemoryReviewStatus;
  canApprove: boolean;
  auditHash?: string;
};
export type MemoryReviewInbox = {
  items: MemoryReviewItem[];
  auditEvents: { id: string; action: string; actor: string; at: string; subjectId?: string }[];
  degradedReason?: string;
};
export type DatabaseWorkspaceFile = {
  id: string;
  filePath: string;
  lang: string;
  symbolCount: number;
};
export type DatabaseWorkspaceDiagnostic = {
  id: string;
  filePath: string;
  tool: string;
  cachedAt: string;
};
export type DatabaseWorkspaceStatus = {
  sourceLabel: string;
  projectID: string;
  projectRoot?: string;
  indexedAt?: string;
  artifactCount: number;
  chunkCount: number;
  symbolCount: number;
  referenceCount: number;
  callEdgeCount: number;
  rejectedCount: number;
  storageByteCount: number;
  storageBudgetBytes: number;
  storageWithinBudget: boolean;
  productionReady: boolean;
  productionReadinessReasons: string[];
  parserAvailable: boolean;
  databaseEncrypted: boolean;
  hostedCodeToolsEnabled: boolean;
  semanticAvailable: boolean;
  files: DatabaseWorkspaceFile[];
  languages: { id: string; lang: string; fileCount: number; byteCount: number }[];
  diagnostics: DatabaseWorkspaceDiagnostic[];
  ops?: {
    schemaVersion: number;
    databaseFileBytes: number;
    totalArtifactCount: number;
    totalSymbolCount: number;
    totalStorageByteCount: number;
    agentMemoryCount: number;
    pendingCloudForgetCount: number;
    projectCount: number;
  };
  degradedReasons: string[];
};
export type DatabaseIndexActionResult = {
  projectID: string;
  projectRoot: string;
  indexedFiles: number;
  chunkCount?: number;
  symbolCount?: number;
  watching?: boolean;
  pollIntervalSeconds?: number;
  auditHash?: string;
};

// ─────────────────────────── P08: account ─────────────────────────────────

export type AccountStatus = {
  signedIn: boolean;
  identityLabel?: string;
  trustClass: 'linux-lower-trust';
  syncState: 'local-only' | 'paused' | 'active';
  lastSyncAt?: string;
};

// ─────────────────────────── P10: membership ──────────────────────────────

export type MembershipTier = 'free' | 'pro';
export type MembershipStatus = {
  tier: MembershipTier;
  entitlements: string[];
  renewsAt?: string;
  restoreAvailable: boolean;
  state?: 'active' | 'cancelled' | 'paymentFailed' | 'offline';
  cacheEvent?: string;
};

// ─────────────────────────── P09: version / diagnostics ───────────────────

export type AppVersionInfo = {
  shellVersion: string;
  daemonVersion: string;
  packageChannel: 'deb' | 'appimage' | 'unknown';
  updateCheck: string;
};
export type DiagnosticsExport = { path: string };

// ─────────────────────────── P10: proxy route log ─────────────────────────

export type ProxyRouteLogEntry = {
  id: string;
  occurredAt: string;
  endpoint: string;
  clientModelSlug: string;
  routingModelSlug?: string;
  upstreamModelSlug?: string;
  providerName?: string;
  accountLabel?: string;
  finalStatus: string;
  rewriteKind: string;
  exactModelInvariant: string;
  streamed: boolean;
  httpStatus?: number;
  failureMessage?: string;
};

// ─────────────────────────── P12: notifications ──────────────────────────

export type NotificationConfig = {
  defaultSnoozeMinutes: number;
  nudgeHoursLocal: number[];
  local: {
    isEnabled: boolean;
    quietHoursStart: number | null;
    quietHoursEnd: number | null;
  };
  telegram: {
    isEnabled: boolean;
    botTokenConfigured: boolean;
    botToken?: string | null;
    botTokenHint?: string | null;
    chatID?: string | null;
    supportedCommands: string[];
  };
  calendar: {
    isEnabled: boolean;
    defaultDurationMinutes: number;
    defaultCalendarName?: string | null;
  };
};
export type NotificationHealth = {
  checkedAt: string;
  channels: { channel: 'local' | 'telegram' | 'calendar'; status: string; detail?: string | null; checkedAt: string }[];
};
export type NotificationCommandResult = { command: string; ok: boolean; message: string };

// ─────────────────────────── P11: session env ─────────────────────────────

export type SessionEnv = { XDG_SESSION_TYPE?: string; XDG_CURRENT_DESKTOP?: string };

// ─────────────────────────── P12: Mercury media ───────────────────────────

export type MercuryDevicePlatform = 'ios' | 'android' | 'macos' | 'linux' | 'unknown';
export type MercurySessionKind = 'screen-share' | 'file' | 'call';
export type MercurySessionState = 'staged' | 'connecting' | 'active' | 'ended';
export type MercuryCallPhase = 'idle' | 'ringing' | 'streaming' | 'cooldown' | 'capability-absent';
export type MercuryPairedDevice = {
  id: string;
  name: string;
  platform: MercuryDevicePlatform;
  isOnline: boolean;
  lastSeenAt: string;
  capabilities: string[];
};
export type MercuryActiveSession = {
  kind: MercurySessionKind;
  state: MercurySessionState;
  peer: string;
  requestId?: string;
  startedAt?: string;
};
export type MercuryMediaStatus = {
  capabilityAvailable: boolean;
  pairedDevices: MercuryPairedDevice[];
  activeSession?: MercuryActiveSession;
};
export type MercuryMediaSessionState = {
  phase: MercuryCallPhase;
  requestId?: string;
  peerName?: string;
  peerId?: string;
  kind: MercurySessionKind;
  startedAt?: string;
  endedAt?: string;
  capabilityAvailable: boolean;
  raw?: RawJsonValue;
};
export type MercuryMediaCapability = {
  available: boolean;
  renderer: 'media-gst' | 'stub' | 'unknown';
  canReceiveCalls: boolean;
  canViewScreenShare: boolean;
  reason?: string;
};
export type MercuryCaptureCodec = 'vp9' | 'av1';
export type MercuryCaptureStatus = {
  active: boolean;
  sessionId?: string;
  source?: string;
  codec?: MercuryCaptureCodec | string;
  targetBitrateBps?: number;
  socketConnected: boolean;
};
// ─────────────────────────── P13: integrations status ─────────────────────

export type IntegrationKind =
  | 'smart_hub_bridge'
  | 'google_cast'
  | 'home_assistant'
  | 'pixel_clock'
  | 'awtrix_http';
export type IntegrationState = 'connected' | 'configured' | 'unavailable' | 'disabled';
export type IntegrationStatus = {
  kind: IntegrationKind;
  label: string;
  state: IntegrationState;
  detail: string;
  dependency?: string;
  configLocation?: string;
  docsHref?: string;
};
export type IntegrationsStatus = { integrations: IntegrationStatus[] };

// ─────────────────────────── Bridge contract ──────────────────────────────

export interface LinuxShellBridge {
  daemonHealth(): Promise<DaemonHealth>;
  gatewayAuthToken(): Promise<string | null>;
  openDashboard(): Promise<void>;
  quitApp(): Promise<void>;
  trayDegraded(): Promise<boolean>;
  measurePerfOperation(
    name: string
  ): Promise<{ name: string; ms: number; source: string; ok: boolean; detail?: string }>;

  // P01–P11 lane extensions — each maps the raw daemon `result` JSON to a typed shape.
  usageSummary(): Promise<UsageSummary>;
  providerCatalog(): Promise<ProviderCatalog>;
  sessionList(): Promise<SessionListResult>;
  sessionSearch(query: string): Promise<SessionListResult>;
  usageInsights(): Promise<UsageInsights>;
  missionList(): Promise<MissionListResult>;
  missionApprovalDecision(id: string, decision: ApprovalDecision): Promise<void>;
  missionCreate(input: MissionCreateInput): Promise<MissionListResult['missions'][number] | null>;
  configSnapshot(): Promise<ConfigSnapshot>;
  dbStatus(): Promise<DbStatus>;
  projectList(): Promise<ProjectEntry[]>;
  memoryBoundaries(): Promise<MemoryBoundary[]>;
  memoryReviewInbox(): Promise<MemoryReviewInbox>;
  memoryReviewDecision(id: string, decision: Exclude<MemoryReviewStatus, 'pending'>): Promise<void>;
  databaseWorkspaceStatus(projectPath?: string): Promise<DatabaseWorkspaceStatus>;
  databaseIndexProject(projectPath?: string): Promise<DatabaseIndexActionResult>;
  databaseWatchProject(projectPath?: string): Promise<DatabaseIndexActionResult>;
  accountStatus(): Promise<AccountStatus>;
  membershipStatus?(): Promise<MembershipStatus>;
  membershipCheckoutUrl?(): Promise<string>;
  openExternalUrl?(url: string): Promise<void>;
  membershipRestore?(): Promise<void>;
  appVersionInfo(): Promise<AppVersionInfo>;
  exportDiagnostics(): Promise<DiagnosticsExport>;
  configUpdate?(snapshot: ConfigSnapshot): Promise<ConfigSnapshot>;
  providerCredentialSlotUpsert?(params: {
    providerID: string;
    slotID?: string;
    label: string;
    apiKey: string;
    isEnabled: boolean;
    endpointProfileID?: string | null;
    authMethodID?: string | null;
  }): Promise<ConfigSnapshot>;
  providerCredentialSlotRemove?(providerID: string, slotID: string): Promise<ConfigSnapshot>;
  providerModelVariantUpsert?(providerID: string, variant: ModelVariant): Promise<ConfigSnapshot>;
  providerModelVariantRemove?(providerID: string, variantID: string): Promise<ConfigSnapshot>;
  providerModelAliasUpsert?(providerID: string, alias: ModelAlias): Promise<ConfigSnapshot>;
  providerModelAliasRemove?(providerID: string, aliasID: string): Promise<ConfigSnapshot>;
  providerCustomModelUpsert?(providerID: string, customModel: CustomModel): Promise<ConfigSnapshot>;
  providerCustomModelRemove?(providerID: string, modelID: string): Promise<ConfigSnapshot>;
  providerModelDisplayNameSet?(providerID: string, modelID: string, displayName: string): Promise<ConfigSnapshot>;
  providerModelDisplayNameClear?(providerID: string, modelID: string): Promise<ConfigSnapshot>;
  proxyRouteLogRecent?(limit: number): Promise<ProxyRouteLogEntry[]>;
  proxyRouteLogClear?(): Promise<boolean>;
  notificationConfigGet?(): Promise<NotificationConfig>;
  notificationConfigUpdate?(config: NotificationConfig): Promise<NotificationConfig>;
  notificationHealth?(): Promise<NotificationHealth>;
  notificationCommand?(command: string, args?: string[]): Promise<NotificationCommandResult>;
  sessionEnv(): Promise<SessionEnv>;
  mediaStatus(): Promise<MercuryMediaStatus>;
  mediaSessionState(): Promise<MercuryMediaSessionState>;
  mediaAcceptCall(requestId: string): Promise<MercuryMediaSessionState>;
  mediaDeclineCall(requestId: string): Promise<MercuryMediaSessionState>;
  mediaEndCall(): Promise<MercuryMediaSessionState>;
  mediaCapabilityGet(): Promise<MercuryMediaCapability>;
  mediaCaptureStartPipeWire?(
    sessionId: string,
    pwFd: number,
    pwNodeId: number,
    targetBitrateBps?: number,
    codec?: MercuryCaptureCodec | string
  ): Promise<MercuryCaptureStatus>;
  mediaCaptureStartTest?(
    sessionId: string,
    numBuffers?: number,
    targetBitrateBps?: number,
    codec?: MercuryCaptureCodec | string
  ): Promise<MercuryCaptureStatus>;
  mediaCaptureStop?(): Promise<MercuryCaptureStatus>;
  mediaCaptureStatus?(): Promise<MercuryCaptureStatus>;
  integrationsStatus(): Promise<IntegrationsStatus>;
}

// ──────────────────── Raw-daemon → typed-shape mappers ────────────────────
//
// The daemon returns JSON whose exact field names depend on Swift Codable
// serialization. These mappers are defensive: they read the fields they know
// about, fall back to zero/empty, and never throw.  The jsdom test suite
// exercises fixture mode (no bridge) so only the packaged Tauri runtime calls
// these — a mismatched field name degrades to empty data rather than crashing.

type RawJsonValue = unknown;

function num(v: RawJsonValue, fallback = 0): number {
  const n = typeof v === 'number' ? v : typeof v === 'string' ? Number(v) : NaN;
  return Number.isFinite(n) ? n : fallback;
}

function str(v: RawJsonValue, fallback = ''): string {
  return typeof v === 'string' ? v : fallback;
}

function arr(v: RawJsonValue): RawJsonValue[] {
  return Array.isArray(v) ? v : [];
}

function pick(v: RawJsonValue, ...keys: string[]): RawJsonValue {
  if (v && typeof v === 'object') {
    const o = v as Record<string, RawJsonValue>;
    for (const k of keys) {
      if (k in o) return o[k];
    }
  }
  return undefined;
}

type UsageEvent = {
  id: string;
  provider: string;
  model: string;
  tokens: number;
  cost: number;
  at: string;
};

function mapUsageSummary(raw: RawJsonValue): UsageSummary {
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

function isToday(at: string): boolean {
  try {
    const d = new Date(at);
    const now = new Date();
    return d.toDateString() === now.toDateString();
  } catch {
    return false;
  }
}

function bucketSevenDay(events: UsageEvent[]): number[] {
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

function mapProviderCatalog(raw: RawJsonValue): ProviderCatalog {
  const snapshot = pick(raw, 'snapshot', 'config') ?? raw;
  const providers = arr(pick(snapshot, 'providers', 'providerAccounts'));
  if (providers.length === 0) {
    // Fall back to deriving from credential slots — daemon.config.get returns these.
    const slots = arr(pick(snapshot, 'credentialSlots', 'providerCredentialSlots'));
    const byProvider = new Map<string, ProviderCatalogEntry>();
    for (const slot of slots) {
      const pid = str(pick(slot, 'providerId', 'provider_id'), 'unknown');
      if (!byProvider.has(pid)) {
        byProvider.set(pid, {
          id: pid,
          label: pid.charAt(0).toUpperCase() + pid.slice(1),
          accountLabel: str(pick(slot, 'label'), 'Default'),
          quotaBuckets: []
        });
      }
    }
    return [...byProvider.values()];
  }
  return providers.map(
    (p, i): ProviderCatalogEntry => ({
      id: str(pick(p, 'id', 'providerId', 'provider_id'), `provider-${i}`),
      label: str(pick(p, 'label', 'displayName', 'name'), `Provider ${i + 1}`),
      accountLabel: str(pick(p, 'accountLabel', 'account', 'label'), 'Default'),
      quotaBuckets: arr(pick(p, 'quotaBuckets', 'quota', 'buckets')).map(
        (b, j): QuotaBucket => ({
          id: str(pick(b, 'id', 'bucketId'), `bucket-${j}`),
          label: str(pick(b, 'label', 'name'), `Bucket ${j + 1}`),
          usedPct: Math.min(100, Math.max(0, num(pick(b, 'usedPct', 'usedPercentage', 'pct')))),
          resetsAt: str(pick(b, 'resetsAt', 'resetAt')) || undefined,
          state: normalizeQuotaState(str(pick(b, 'state', 'status'), 'ok'))
        })
      )
    })
  );
}

function normalizeQuotaState(s: string): QuotaBucketState {
  const lower = s.toLowerCase();
  if (lower.includes('cool') || lower.includes('rate')) return 'cooling_down';
  if (lower.includes('missing') || lower.includes('credential') || lower.includes('unauth'))
    return 'missing_credential';
  if (lower.includes('exhaust') || lower.includes('deplet') || lower.includes('limit'))
    return 'exhausted';
  return 'ok';
}

function mapSessionList(raw: RawJsonValue): SessionListResult {
  const list = arr(pick(raw, 'sessions', 'usage', 'results'));
  const sessions = list.map(
    (s, i): SessionEntry => ({
      id: str(pick(s, 'id', 'sessionId', 'session_id'), `session-${i}`),
      provider: str(pick(s, 'provider', 'providerId', 'provider_id'), 'unknown'),
      model: str(pick(s, 'model', 'modelId', 'model_id'), 'unknown'),
      startedAt: str(pick(s, 'startedAt', 'timestamp', 'createdAt', 'at'), new Date().toISOString()),
      tokens: num(pick(s, 'tokens', 'totalTokens', 'tokenCount')),
      costUsd: num(pick(s, 'costUsd', 'cost', 'estimatedCostUsd')),
      title: str(pick(s, 'title', 'summary', 'name'), 'Untitled session')
    })
  );
  return { sessions, nextCursor: str(pick(raw, 'nextCursor', 'cursor')) || null };
}

function mapUsageInsights(raw: RawJsonValue): UsageInsights {
  // Derived from daemon.usage.recent — the bridge aggregates events client-side.
  const events = arr(pick(raw, 'usage', 'events', 'recent'));
  const weekly = buildWeeklyBuckets(events);
  const providerMix = buildMix(events, (e) => str(pick(e, 'providerId', 'provider'), 'unknown'));
  const modelMix = buildMix(events, (e) => str(pick(e, 'modelId', 'model'), 'unknown'));
  return { weekly, providerMix, modelMix, cacheHitRatePct: computeCacheHitRatePct(events) };
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

function buildWeeklyBuckets(events: RawJsonValue[]): WeeklyPoint[] {
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

function buildMix(
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
    .map(([id, t], i) => ({
      id,
      label: id.charAt(0).toUpperCase() + id.slice(1),
      pct: Math.round((t / grand) * 100)
    }))
    .sort((a, b) => b.pct - a.pct);
}

function mapMissionList(raw: RawJsonValue): MissionListResult {
  const missions = arr(pick(raw, 'missions')).map(
    (m, i): MissionListResult['missions'][number] => ({
      id: str(pick(m, 'id', 'missionId'), `mission-${i}`),
      title: str(pick(m, 'title', 'name', 'summary'), 'Untitled mission'),
      state: str(pick(m, 'state', 'status'), 'active'),
      updatedAt: str(pick(m, 'updatedAt', 'updated_at', 'modifiedAt'), new Date().toISOString()),
      laneCount: num(pick(m, 'laneCount', 'lane_count', 'packetCount')),
      projectSlug: str(pick(m, 'projectSlug', 'project_slug', 'projectName', 'project'), '') || undefined
    })
  );
  const pendingApprovals = arr(pick(raw, 'pendingApprovals', 'approvals', 'questions')).map(
    (a, i): PendingApproval => ({
      id: str(pick(a, 'id', 'approvalId'), `approval-${i}`),
      missionId: str(pick(a, 'missionId', 'mission_id'), 'unknown'),
      summary: str(pick(a, 'summary', 'question', 'prompt', 'body'), 'Approval requested'),
      requestedAt: str(pick(a, 'requestedAt', 'created_at', 'createdAt'), new Date().toISOString()),
      risk: str(pick(a, 'risk', 'severity'), '').toLowerCase().includes('high') ? 'high' : 'standard'
    })
  );
  return { missions, pendingApprovals };
}

function mapMissionMutation(raw: RawJsonValue): MissionListResult['missions'][number] | null {
  const mission = pick(raw, 'mission') ?? raw;
  if (!mission || typeof mission !== 'object') return null;
  return {
    id: str(pick(mission, 'id', 'missionId'), ''),
    title: str(pick(mission, 'title', 'name', 'summary'), 'Untitled mission'),
    state: str(pick(mission, 'state', 'status'), 'active'),
    updatedAt: str(pick(mission, 'updatedAt', 'updated_at', 'modifiedAt'), new Date().toISOString()),
    laneCount: arr(pick(mission, 'packets')).length || num(pick(mission, 'laneCount', 'lane_count', 'packetCount')),
    projectSlug: str(pick(mission, 'projectSlug', 'project_slug', 'projectName', 'project'), '') || undefined
  };
}

function mapConfigSnapshot(raw: RawJsonValue): ConfigSnapshot {
  const snap = pick(raw, 'snapshot', 'config') ?? raw;
  return {
    paths: {
      supportDir: str(pick(snap, 'supportDir', 'support_dir', 'dataDir')),
      socketPath: str(pick(snap, 'socketPath', 'socket_path')),
      configDir: str(pick(snap, 'configDir', 'config_dir')),
      providerLogPaths: arr(pick(snap, 'providerLogPaths', 'provider_log_paths')).map((p) => str(p))
    },
    secretServiceStatus: str(pick(snap, 'secretServiceStatus', 'secret_service_status'), 'unknown'),
    telemetryEnabled: Boolean(pick(snap, 'telemetryEnabled', 'telemetry_enabled')),
    privacyOptIn: Boolean(pick(snap, 'privacyOptIn', 'privacy_opt_in')),
    providers: arr(pick(snap, 'providers')).map(mapProviderSettings),
    routerMode: str(pick(snap, 'routerMode'), 'providerFamilyFailover')
  };
}

function mapProviderSettings(raw: RawJsonValue, i = 0): ProviderSettings {
  return {
    providerID: str(pick(raw, 'providerID', 'providerId', 'provider_id'), `provider-${i}`),
    isEnabled: Boolean(pick(raw, 'isEnabled', 'enabled')),
    baseURL: str(pick(raw, 'baseURL', 'baseUrl', 'base_url')),
    preferredModelIDs: arr(pick(raw, 'preferredModelIDs', 'preferredModelIds', 'preferred_model_ids')).map((v) => str(v)).filter(Boolean),
    disabledAdvertisedModelIDs: arr(pick(raw, 'disabledAdvertisedModelIDs', 'disabledAdvertisedModelIds')).map((v) => str(v)).filter(Boolean),
    preferredCredentialSlotID: str(pick(raw, 'preferredCredentialSlotID', 'preferredCredentialSlotId')) || undefined,
    credentialSlots: arr(pick(raw, 'credentialSlots')).map(mapCredentialSlot),
    modelVariants: arr(pick(raw, 'modelVariants')).map(mapModelVariant),
    modelAliases: arr(pick(raw, 'modelAliases')).map(mapModelAlias),
    modelDisplayOverrides: arr(pick(raw, 'modelDisplayOverrides')).map(mapModelDisplayOverride),
    customModels: arr(pick(raw, 'customModels')).map(mapCustomModel)
  };
}

function mapCredentialSlot(raw: RawJsonValue, i = 0): ProviderCredentialSlot {
  return {
    slotID: str(pick(raw, 'slotID', 'slotId', 'id'), `slot-${i}`),
    label: str(pick(raw, 'label'), `Slot ${i + 1}`),
    isEnabled: Boolean(pick(raw, 'isEnabled', 'enabled')),
    status: str(pick(raw, 'status'), 'missingSecret'),
    cooldownUntil: str(pick(raw, 'cooldownUntil')) || undefined,
    lastQuotaRemainingPercent: pick(raw, 'lastQuotaRemainingPercent') == null ? undefined : num(pick(raw, 'lastQuotaRemainingPercent')),
    lastQuotaResetsAt: str(pick(raw, 'lastQuotaResetsAt')) || undefined,
    lastStatusMessage: str(pick(raw, 'lastStatusMessage')) || undefined,
    endpointProfileID: str(pick(raw, 'endpointProfileID', 'endpointProfileId')) || undefined,
    authMethodID: str(pick(raw, 'authMethodID', 'authMethodId')) || undefined,
    updatedAt: str(pick(raw, 'updatedAt')) || undefined
  };
}

function mapModelVariant(raw: RawJsonValue, i = 0): ModelVariant {
  const level = str(pick(raw, 'thinkingLevel'), 'medium') as ModelVariant['thinkingLevel'];
  return {
    variantID: str(pick(raw, 'variantID', 'variantId'), `variant-${i}`),
    label: str(pick(raw, 'label'), 'Variant'),
    baseModelID: str(pick(raw, 'baseModelID', 'baseModelId')),
    thinkingLevel: ['low', 'medium', 'high', 'xhigh', 'max'].includes(level) ? level : 'medium',
    maxOutputTokens: pick(raw, 'maxOutputTokens') == null ? null : num(pick(raw, 'maxOutputTokens')),
    createdAt: str(pick(raw, 'createdAt')) || undefined,
    updatedAt: str(pick(raw, 'updatedAt')) || undefined
  };
}

function mapModelAlias(raw: RawJsonValue, i = 0): ModelAlias {
  return {
    aliasID: str(pick(raw, 'aliasID', 'aliasId'), `alias-${i}`),
    baseModelID: str(pick(raw, 'baseModelID', 'baseModelId')),
    displayName: str(pick(raw, 'displayName')),
    hidesBaseModel: Boolean(pick(raw, 'hidesBaseModel')),
    createdAt: str(pick(raw, 'createdAt')) || undefined,
    updatedAt: str(pick(raw, 'updatedAt')) || undefined
  };
}

function mapModelDisplayOverride(raw: RawJsonValue): ModelDisplayOverride {
  return {
    modelID: str(pick(raw, 'modelID', 'modelId')),
    displayName: str(pick(raw, 'displayName')),
    createdAt: str(pick(raw, 'createdAt')) || undefined,
    updatedAt: str(pick(raw, 'updatedAt')) || undefined
  };
}

function mapCustomModel(raw: RawJsonValue): CustomModel {
  return {
    modelID: str(pick(raw, 'modelID', 'modelId')),
    displayName: str(pick(raw, 'displayName')),
    createdAt: str(pick(raw, 'createdAt')) || undefined,
    updatedAt: str(pick(raw, 'updatedAt')) || undefined
  };
}

function mapDbStatus(raw: RawJsonValue): DbStatus {
  // Derived from daemon.config.get + daemon.health — no dedicated db RPC exists.
  return {
    sqlcipherOk: Boolean(pick(raw, 'sqlcipherOk', 'sqlcipher_ok', 'encrypted')),
    migrationVersion: num(pick(raw, 'migrationVersion', 'migration_version', 'schemaVersion')),
    sizeBytes: num(pick(raw, 'sizeBytes', 'size_bytes', 'dbSize')),
    walMode: Boolean(pick(raw, 'walMode', 'wal_mode', 'walEnabled'))
  };
}

function mapProjectList(raw: RawJsonValue): ProjectEntry[] {
  const projects = arr(pick(raw, 'projects', 'items'));
  return projects.map(
    (p, i): ProjectEntry => ({
      id: str(pick(p, 'id', 'slug'), `project-${i}`),
      name: str(pick(p, 'name', 'title', 'displayName'), `Project ${i + 1}`),
      path: str(pick(p, 'path', 'rootPath', 'workingDirectory'), ''),
      scope: str(pick(p, 'scope', 'codeMemoryScope'), 'workspace')
    })
  );
}

function mapMemoryBoundaries(raw: RawJsonValue): MemoryBoundary[] {
  const byScope = pick(raw, 'byScope');
  if (byScope && typeof byScope === 'object' && !Array.isArray(byScope)) {
    return Object.entries(byScope as Record<string, RawJsonValue>).map(([scope, count], i) => ({
      id: `scope-${scope || i}`,
      scope: scope || 'workspace',
      label: `${scope || 'workspace'} memory`,
      detail: `${num(count)} durable memories in this recall boundary`
    }));
  }
  const items = arr(pick(raw, 'boundaries', 'scopes', 'analytics'));
  return items.map((m, i): MemoryBoundary => ({
    id: str(pick(m, 'id', 'scopeId'), `mem-${i}`),
    scope: str(pick(m, 'scope', 'projectSlug'), 'workspace'),
    label: str(pick(m, 'label', 'name'), `Memory scope ${i + 1}`),
    detail: str(pick(m, 'detail', 'description', 'policy'), 'Recall boundary active')
  }));
}

function rpcReportResult(raw: RawJsonValue): RawJsonValue {
  return Boolean(pick(raw, 'ok')) ? pick(raw, 'result') : undefined;
}

function rpcReportError(raw: RawJsonValue): string | undefined {
  return Boolean(pick(raw, 'ok')) ? undefined : str(pick(raw, 'error')) || 'RPC failed';
}

function mapMemoryReviewInbox(raw: RawJsonValue): MemoryReviewInbox {
  const recallReport = pick(raw, 'recall');
  const auditReport = pick(raw, 'auditTrail');
  const recall = rpcReportResult(recallReport);
  const audit = rpcReportResult(auditReport);
  const degradedReasons = [rpcReportError(recallReport), rpcReportError(auditReport)].filter(
    (value): value is string => Boolean(value)
  );
  const auditEvents = arr(pick(audit, 'events')).map((event, i) => ({
    id: str(pick(event, 'hash'), `audit-${i}`),
    action: str(pick(event, 'action'), 'unknown'),
    actor: str(pick(event, 'actor'), 'daemon'),
    at: str(pick(event, 'ts', 'createdAt', 'at'), ''),
    subjectId: str(pick(event, 'subjectID', 'subjectId')) || undefined
  }));
  const lastAuditBySubject = new Map<string, string>();
  for (const event of auditEvents) {
    if (event.subjectId) lastAuditBySubject.set(event.subjectId, event.id);
  }
  const items = arr(pick(recall, 'hits')).map((hit, i): MemoryReviewItem => {
    const id = str(pick(hit, 'memoryID', 'memoryId', 'id'), `memory-${i}`);
    const sourcePath = str(pick(hit, 'sourcePath', 'source_path'));
    const projectID = str(pick(hit, 'projectID', 'projectId'));
    return {
      id,
      body: str(pick(hit, 'bodyRedacted', 'snippet', 'text', 'body'), '(Memory contents unavailable)'),
      kind: str(pick(hit, 'kind'), 'memory'),
      confidence: Math.max(0, Math.min(1, num(pick(hit, 'confidence'), 1))),
      sourceLabel: sourcePath || projectID || 'Daemon memory recall',
      status: 'approved',
      canApprove: false,
      auditHash: lastAuditBySubject.get(id)
    };
  });
  return {
    items,
    auditEvents,
    degradedReason: degradedReasons.join(' · ') || undefined
  };
}

function mapDatabaseWorkspaceStatus(raw: RawJsonValue): DatabaseWorkspaceStatus {
  const indexReport = pick(raw, 'indexStatus');
  const exploreReport = pick(raw, 'explore');
  const diagnosticsReport = pick(raw, 'diagnostics');
  const opsReport = pick(raw, 'opsDiagnostics');
  const index = rpcReportResult(indexReport);
  const explore = rpcReportResult(exploreReport);
  const diagnostics = rpcReportResult(diagnosticsReport);
  const ops = rpcReportResult(opsReport);
  const degradedReasons = [
    rpcReportError(indexReport),
    rpcReportError(exploreReport),
    rpcReportError(diagnosticsReport),
    rpcReportError(opsReport)
  ].filter((value): value is string => Boolean(value));
  const repoMap = pick(explore, 'repoMap');
  const filesRaw = arr(pick(explore, 'files')).length > 0 ? arr(pick(explore, 'files')) : arr(pick(repoMap, 'topFiles'));
  return {
    sourceLabel: 'live daemon code-memory RPCs',
    projectID: str(pick(index, 'projectID', 'projectId'), str(pick(explore, 'projectID', 'projectId'), 'unknown')),
    projectRoot: str(pick(index, 'projectRoot'), str(pick(explore, 'projectRoot'))) || undefined,
    indexedAt: str(pick(index, 'indexedAt')) || undefined,
    artifactCount: num(pick(index, 'artifactCount'), num(pick(repoMap, 'artifactCount'))),
    chunkCount: num(pick(index, 'chunkCount')),
    symbolCount: num(pick(index, 'symbolCount'), num(pick(repoMap, 'symbolCount'))),
    referenceCount: num(pick(index, 'referenceCount')),
    callEdgeCount: num(pick(index, 'callEdgeCount')),
    rejectedCount: num(pick(index, 'rejectedCount')),
    storageByteCount: num(pick(index, 'storageByteCount')),
    storageBudgetBytes: num(pick(index, 'storageBudgetBytes')),
    storageWithinBudget: Boolean(pick(index, 'storageWithinBudget')),
    productionReady: Boolean(pick(index, 'productionReady')),
    productionReadinessReasons: arr(pick(index, 'productionReadinessReasons')).map((v) => str(v)).filter(Boolean),
    parserAvailable: Boolean(pick(index, 'parserAvailable')),
    databaseEncrypted: Boolean(pick(index, 'databaseEncrypted')),
    hostedCodeToolsEnabled: Boolean(pick(index, 'hostedCodeToolsEnabled')),
    semanticAvailable: Boolean(pick(index, 'semanticAvailable')),
    files: filesRaw.map((file, i): DatabaseWorkspaceFile => ({
      id: str(pick(file, 'filePath'), `file-${i}`),
      filePath: str(pick(file, 'filePath'), `file-${i}`),
      lang: str(pick(file, 'lang'), 'unknown'),
      symbolCount: num(pick(file, 'symbolCount'))
    })),
    languages: arr(pick(repoMap, 'languages')).map((lang, i) => ({
      id: str(pick(lang, 'lang'), `lang-${i}`),
      lang: str(pick(lang, 'lang'), 'unknown'),
      fileCount: num(pick(lang, 'fileCount')),
      byteCount: num(pick(lang, 'byteCount'))
    })),
    diagnostics: arr(pick(diagnostics, 'diagnostics')).map((diag, i): DatabaseWorkspaceDiagnostic => ({
      id: `${str(pick(diag, 'filePath'), 'diagnostic')}-${i}`,
      filePath: str(pick(diag, 'filePath'), 'unknown'),
      tool: str(pick(diag, 'tool'), 'diagnostic'),
      cachedAt: str(pick(diag, 'cachedAt'), '')
    })),
    ops: ops
      ? {
          schemaVersion: num(pick(ops, 'schemaVersion')),
          databaseFileBytes: num(pick(ops, 'databaseFileBytes')),
          totalArtifactCount: num(pick(ops, 'totalArtifactCount')),
          totalSymbolCount: num(pick(ops, 'totalSymbolCount')),
          totalStorageByteCount: num(pick(ops, 'totalStorageByteCount')),
          agentMemoryCount: num(pick(ops, 'agentMemoryCount')),
          pendingCloudForgetCount: num(pick(ops, 'pendingCloudForgetCount')),
          projectCount: arr(pick(ops, 'projects')).length
        }
      : undefined,
    degradedReasons
  };
}

function mapDatabaseIndexAction(raw: RawJsonValue): DatabaseIndexActionResult {
  return {
    projectID: str(pick(raw, 'projectID', 'projectId'), 'unknown'),
    projectRoot: str(pick(raw, 'projectRoot'), ''),
    indexedFiles: num(pick(raw, 'indexedFiles')),
    chunkCount: num(pick(raw, 'chunkCount')),
    symbolCount: num(pick(raw, 'symbolCount')),
    watching: typeof pick(raw, 'watching') === 'boolean' ? Boolean(pick(raw, 'watching')) : undefined,
    pollIntervalSeconds: num(pick(raw, 'pollIntervalSeconds')),
    auditHash: str(pick(raw, 'auditHash')) || undefined
  };
}

function mapAccountStatus(raw: RawJsonValue): AccountStatus {
  // Derived from daemon.config.get — no daemon.account.* RPC exists.
  const snap = pick(raw, 'snapshot', 'config') ?? raw;
  const cloud = pick(snap, 'cloud', 'sync', 'account');
  const signedIn = Boolean(pick(cloud, 'signedIn', 'signed_in', 'authenticated'));
  const syncStateRaw = str(pick(cloud, 'syncState', 'sync_state', 'status'), 'local-only');
  const syncState: AccountStatus['syncState'] = syncStateRaw.includes('active')
    ? 'active'
    : syncStateRaw.includes('pause')
      ? 'paused'
      : 'local-only';
  return {
    signedIn,
    identityLabel: str(pick(cloud, 'identityLabel', 'email', 'label')) || undefined,
    trustClass: 'linux-lower-trust',
    syncState,
    lastSyncAt: str(pick(cloud, 'lastSyncAt', 'last_sync_at')) || undefined
  };
}

function mapMembershipStatus(raw: RawJsonValue): MembershipStatus {
  const membership = pick(raw, 'membership', 'subscription', 'cloudMembership', 'cloud') ?? raw;
  const entitlementDocs = pick(membership, 'entitlementDocs', 'entitlementsByID', 'entitlements');
  const proDoc = pick(entitlementDocs, ENTITLEMENT_DOC_IDS.pro);
  const proMaxDoc = pick(entitlementDocs, ENTITLEMENT_DOC_IDS.proMax);
  const ultraDoc = pick(entitlementDocs, ENTITLEMENT_DOC_IDS.ultra);
  const hostedQuotaDoc = pick(entitlementDocs, ENTITLEMENT_DOC_IDS.hostedQuotaSync);
  const activeDocs = [
    [ENTITLEMENT_DOC_IDS.pro, proDoc, 'premium'],
    [ENTITLEMENT_DOC_IDS.proMax, proMaxDoc, 'cloudPro'],
    [ENTITLEMENT_DOC_IDS.ultra, ultraDoc, 'ultra'],
    [ENTITLEMENT_DOC_IDS.hostedQuotaSync, hostedQuotaDoc, 'hostedQuota']
  ] as const;
  const canonicalActive = activeDocs
    .filter(([, doc, feature]) =>
      evaluateEntitlement(doc as Record<string, unknown> | undefined, feature).active
    )
    .map(([id]) => id);
  const rawEntitlements = arr(pick(membership, 'entitlementIds', 'activeEntitlements'))
    .map((e) => str(e))
    .filter(Boolean);
  const proGrantIDs = new Set<string>([
    ENTITLEMENT_DOC_IDS.pro,
    ENTITLEMENT_DOC_IDS.proMax,
    ENTITLEMENT_DOC_IDS.ultra,
    ENTITLEMENT_DOC_IDS.hostedQuotaSync
  ]);
  const tierRaw = str(pick(membership, 'tier', 'cloudTier', 'plan', 'planTier', 'state'), 'free').toLowerCase();
  const tier: MembershipTier =
    tierRaw.includes('pro') ||
    canonicalActive.some((e) => proGrantIDs.has(e)) ||
    rawEntitlements.some((e) => proGrantIDs.has(e))
      ? 'pro'
      : 'free';
  const entitlements =
    canonicalActive.length > 0
      ? canonicalActive
      : rawEntitlements.length > 0
        ? rawEntitlements
      : tier === 'pro'
        ? [ENTITLEMENT_DOC_IDS.pro, ENTITLEMENT_DOC_IDS.hostedQuotaSync]
        : [];
  return {
    tier,
    entitlements,
    renewsAt: str(pick(membership, 'renewsAt', 'expiresAt', 'currentPeriodEnd')) || undefined,
    restoreAvailable: Boolean(pick(membership, 'restoreAvailable', 'canRestore', 'signedIn')),
    state: normalizeMembershipState(str(pick(membership, 'state', 'status'))),
    cacheEvent: str(pick(membership, 'cacheEvent', 'shellCacheEvent')) || undefined
  };
}

function normalizeMembershipState(value: string): MembershipStatus['state'] | undefined {
  switch (value) {
    case 'active':
    case 'cancelled':
    case 'paymentFailed':
    case 'offline':
      return value;
    default:
      return undefined;
  }
}

function mapMembershipCheckoutUrl(raw: RawJsonValue): string {
  const value = str(pick(raw, 'url', 'checkoutUrl', 'checkout_url'));
  if (!value) throw new Error('Daemon did not return a Stripe checkout URL.');
  return value;
}

function mapAppVersionInfo(raw: RawJsonValue): AppVersionInfo {
  return {
    shellVersion: str(pick(raw, 'shellVersion', 'shell_version')),
    daemonVersion: str(pick(raw, 'daemonVersion', 'daemon_version')),
    packageChannel: normalizeChannel(str(pick(raw, 'packageChannel', 'package_channel'), 'unknown')),
    updateCheck: 'unavailable-in-shell'
  };
}

function normalizeIntegrationKind(value: string): IntegrationKind {
  switch (value) {
    case 'smart_hub_bridge':
    case 'google_cast':
    case 'home_assistant':
    case 'pixel_clock':
    case 'awtrix_http':
      return value;
    default:
      return 'smart_hub_bridge';
  }
}

function normalizeIntegrationState(value: string): IntegrationState {
  switch (value.toLowerCase()) {
    case 'connected':
    case 'configured':
    case 'unavailable':
    case 'disabled':
      return value.toLowerCase() as IntegrationState;
    default:
      return 'unavailable';
  }
}

function mapIntegrationsStatus(raw: RawJsonValue): IntegrationsStatus {
  const payload = pick(raw, 'result', 'status', 'snapshot') ?? raw;
  const items = arr(pick(payload, 'integrations', 'items'));
  return {
    integrations: items.map((item, index): IntegrationStatus => {
      const kind = normalizeIntegrationKind(str(pick(item, 'kind', 'adapter', 'id'), 'smart_hub_bridge'));
      return {
        kind,
        label: str(pick(item, 'label', 'name'), `Integration ${index + 1}`),
        state: normalizeIntegrationState(str(pick(item, 'state', 'status'), 'unavailable')),
        detail: str(pick(item, 'detail', 'summary', 'blocker'), 'No daemon detail reported.'),
        dependency: str(pick(item, 'dependency', 'linuxDependency')) || undefined,
        configLocation: str(pick(item, 'configLocation', 'config_location')) || undefined,
        docsHref: str(pick(item, 'docsHref', 'docs_href', 'documentation')) || undefined
      };
    })
  };
}

function snapshotFromMutation(raw: RawJsonValue): ConfigSnapshot {
  return mapConfigSnapshot(pick(raw, 'snapshot') ? raw : { snapshot: pick(raw, 'snapshot') ?? raw });
}

function mapProxyRouteLog(raw: RawJsonValue): ProxyRouteLogEntry[] {
  return arr(pick(raw, 'entries')).map((entry, i): ProxyRouteLogEntry => ({
    id: str(pick(entry, 'id'), `route-log-${i}`),
    occurredAt: str(pick(entry, 'occurredAt'), new Date().toISOString()),
    endpoint: str(pick(entry, 'endpoint')),
    clientModelSlug: str(pick(entry, 'clientModelSlug')),
    routingModelSlug: str(pick(entry, 'routingModelSlug')) || undefined,
    upstreamModelSlug: str(pick(entry, 'upstreamModelSlug')) || undefined,
    providerName: str(pick(entry, 'providerName')) || undefined,
    accountLabel: str(pick(entry, 'accountLabel')) || undefined,
    finalStatus: str(pick(entry, 'finalStatus'), 'unknown'),
    rewriteKind: str(pick(entry, 'rewriteKind'), 'none'),
    exactModelInvariant: str(pick(entry, 'exactModelInvariant'), 'not_applicable'),
    streamed: Boolean(pick(entry, 'streamed')),
    httpStatus: pick(entry, 'httpStatus') == null ? undefined : num(pick(entry, 'httpStatus')),
    failureMessage: str(pick(entry, 'failureMessage')) || undefined
  }));
}

export function defaultNotificationConfig(): NotificationConfig {
  return {
    defaultSnoozeMinutes: 30,
    nudgeHoursLocal: [9, 13, 17],
    local: { isEnabled: true, quietHoursStart: null, quietHoursEnd: null },
    telegram: {
      isEnabled: false,
      botTokenConfigured: false,
      botToken: null,
      botTokenHint: null,
      chatID: null,
      supportedCommands: ['help', 'pending', 'followups', 'latest', 'status']
    },
    calendar: { isEnabled: false, defaultDurationMinutes: 30, defaultCalendarName: null }
  };
}

function mapNotificationConfig(raw: RawJsonValue): NotificationConfig {
  const c = pick(raw, 'config') ?? raw;
  const fallback = defaultNotificationConfig();
  return {
    defaultSnoozeMinutes: num(pick(c, 'defaultSnoozeMinutes'), fallback.defaultSnoozeMinutes),
    nudgeHoursLocal: arr(pick(c, 'nudgeHoursLocal')).map((v) => num(v)).filter((v) => v >= 0 && v <= 23),
    local: {
      isEnabled: Boolean(pick(pick(c, 'local'), 'isEnabled')),
      quietHoursStart: pick(pick(c, 'local'), 'quietHoursStart') == null ? null : num(pick(pick(c, 'local'), 'quietHoursStart')),
      quietHoursEnd: pick(pick(c, 'local'), 'quietHoursEnd') == null ? null : num(pick(pick(c, 'local'), 'quietHoursEnd'))
    },
    telegram: {
      isEnabled: Boolean(pick(pick(c, 'telegram'), 'isEnabled')),
      botTokenConfigured: Boolean(pick(pick(c, 'telegram'), 'botTokenConfigured')),
      botToken: str(pick(pick(c, 'telegram'), 'botToken')) || null,
      botTokenHint: str(pick(pick(c, 'telegram'), 'botTokenHint')) || null,
      chatID: str(pick(pick(c, 'telegram'), 'chatID', 'chatId')) || null,
      supportedCommands: arr(pick(pick(c, 'telegram'), 'supportedCommands')).map((v) => str(v)).filter(Boolean)
    },
    calendar: {
      isEnabled: Boolean(pick(pick(c, 'calendar'), 'isEnabled')),
      defaultDurationMinutes: num(pick(pick(c, 'calendar'), 'defaultDurationMinutes'), fallback.calendar.defaultDurationMinutes),
      defaultCalendarName: str(pick(pick(c, 'calendar'), 'defaultCalendarName')) || null
    }
  };
}

function mapNotificationHealth(raw: RawJsonValue): NotificationHealth {
  const h = pick(raw, 'health') ?? raw;
  return {
    checkedAt: str(pick(h, 'checkedAt'), new Date().toISOString()),
    channels: arr(pick(h, 'channels')).map((channel) => ({
      channel: str(pick(channel, 'channel'), 'local') as 'local' | 'telegram' | 'calendar',
      status: str(pick(channel, 'status'), 'disabled'),
      detail: str(pick(channel, 'detail')) || null,
      checkedAt: str(pick(channel, 'checkedAt'), new Date().toISOString())
    }))
  };
}

function mapNotificationCommand(raw: RawJsonValue): NotificationCommandResult {
  return {
    command: str(pick(raw, 'command'), 'status'),
    ok: Boolean(pick(raw, 'ok')),
    message: str(pick(raw, 'message'), 'Command finished.')
  };
}

function normalizeChannel(s: string): AppVersionInfo['packageChannel'] {
  const lower = s.toLowerCase();
  if (lower.includes('deb')) return 'deb';
  if (lower.includes('appimage') || lower.includes('app-image')) return 'appimage';
  return 'unknown';
}

function normalizeMercuryPlatform(raw: string): MercuryDevicePlatform {
  const lower = raw.toLowerCase();
  if (lower.includes('ios') || lower.includes('iphone') || lower.includes('ipad')) return 'ios';
  if (lower.includes('android')) return 'android';
  if (lower.includes('mac')) return 'macos';
  if (lower.includes('linux')) return 'linux';
  return 'unknown';
}

function normalizeMercuryKind(raw: string): MercurySessionKind {
  const lower = raw.toLowerCase();
  if (lower.includes('file')) return 'file';
  if (lower.includes('call') || lower.includes('voip')) return 'call';
  return 'screen-share';
}

function normalizeMercuryState(raw: string): MercurySessionState {
  const lower = raw.toLowerCase();
  if (lower.includes('connect') || lower.includes('start')) return 'connecting';
  if (lower.includes('active') || lower.includes('stream')) return 'active';
  if (lower.includes('end') || lower.includes('stop') || lower.includes('done')) return 'ended';
  return 'staged';
}

function normalizeMercuryCallPhase(raw: string): MercuryCallPhase {
  const lower = raw.toLowerCase();
  if (lower.includes('absent') || lower.includes('unsupported') || lower.includes('unavailable')) return 'capability-absent';
  if (lower.includes('ring') || lower.includes('incoming')) return 'ringing';
  if (lower.includes('stream') || lower.includes('active') || lower.includes('accepted') || lower.includes('viewer')) return 'streaming';
  if (lower.includes('cool') || lower.includes('end') || lower.includes('declin') || lower.includes('stop')) return 'cooldown';
  return 'idle';
}

function isCapabilityAbsentError(e: unknown): boolean {
  const message = e instanceof Error ? e.message : String(e);
  return /unknown|unsupported|not implemented|no such method/i.test(message);
}

function mapMercuryMediaStatus(raw: RawJsonValue): MercuryMediaStatus {
  const absent = Boolean(pick(raw, 'capabilityAbsent', 'capability_absent'));
  const availableRaw = pick(raw, 'capabilityAvailable', 'capability_available', 'available');
  const pairedDevices = arr(pick(raw, 'pairedDevices', 'paired_devices', 'devices', 'peers')).map(
    (d, i): MercuryPairedDevice => ({
      id: str(pick(d, 'id', 'deviceId', 'device_id', 'connectionID', 'connectionId'), `device-${i}`),
      name: str(pick(d, 'name', 'displayName', 'display_name', 'label'), `Device ${i + 1}`),
      platform: normalizeMercuryPlatform(str(pick(d, 'platform', 'kind', 'os'), 'unknown')),
      isOnline: Boolean(pick(d, 'isOnline', 'is_online', 'online')),
      lastSeenAt: str(pick(d, 'lastSeenAt', 'last_seen_at', 'updatedAt'), new Date(0).toISOString()),
      capabilities: arr(pick(d, 'capabilities', 'features')).map((capability) => str(capability)).filter(Boolean)
    })
  );
  const sessionRaw = pick(raw, 'activeSession', 'active_session', 'session');
  const activeSession =
    sessionRaw && typeof sessionRaw === 'object'
      ? {
          kind: normalizeMercuryKind(str(pick(sessionRaw, 'kind', 'type'), 'screen-share')),
          state: normalizeMercuryState(str(pick(sessionRaw, 'state', 'phase', 'status'), 'staged')),
          peer: str(pick(sessionRaw, 'peer', 'peerName', 'peer_name', 'deviceName'), 'Paired device'),
          requestId: str(pick(sessionRaw, 'requestId', 'request_id')) || undefined,
          startedAt: str(pick(sessionRaw, 'startedAt', 'started_at')) || undefined
        }
      : undefined;
  return {
    capabilityAvailable: absent ? false : availableRaw === undefined ? true : Boolean(availableRaw),
    pairedDevices,
    activeSession
  };
}

function mapMercurySessionState(raw: RawJsonValue): MercuryMediaSessionState {
  const incomingCall = pick(raw, 'incomingCall', 'incoming_call');
  const activeSession = pick(raw, 'activeSession', 'active_session', 'session');
  const source =
    incomingCall && typeof incomingCall === 'object'
      ? incomingCall
      : activeSession && typeof activeSession === 'object'
        ? activeSession
        : raw;
  const absent = Boolean(pick(raw, 'capabilityAbsent', 'capability_absent'));
  const availableRaw = pick(raw, 'capabilityAvailable', 'capability_available', 'available');
  const phaseRaw = str(
    pick(raw, 'phase', 'state', 'status') ?? pick(source, 'phase', 'state', 'status'),
    absent ? 'capability-absent' : 'idle'
  );
  const phase = absent ? 'capability-absent' : normalizeMercuryCallPhase(phaseRaw);
  return {
    phase,
    requestId: str(pick(raw, 'requestId', 'request_id') ?? pick(source, 'requestId', 'request_id')) || undefined,
    peerName:
      str(pick(raw, 'peerName', 'peer_name', 'peer', 'deviceName') ?? pick(source, 'peerName', 'peer_name', 'peer', 'deviceName')) ||
      undefined,
    peerId: str(pick(raw, 'peerId', 'peer_id', 'deviceId') ?? pick(source, 'peerId', 'peer_id', 'deviceId')) || undefined,
    kind: normalizeMercuryKind(str(pick(raw, 'kind', 'type') ?? pick(source, 'kind', 'type'), 'call')),
    startedAt: str(pick(raw, 'startedAt', 'started_at') ?? pick(source, 'startedAt', 'started_at')) || undefined,
    endedAt: str(pick(raw, 'endedAt', 'ended_at') ?? pick(source, 'endedAt', 'ended_at')) || undefined,
    capabilityAvailable: absent ? false : availableRaw === undefined ? true : Boolean(availableRaw),
    raw
  };
}

function mapMercuryCapability(raw: RawJsonValue): MercuryMediaCapability {
  const absent = Boolean(pick(raw, 'capabilityAbsent', 'capability_absent'));
  const availableRaw = pick(raw, 'available', 'capabilityAvailable', 'capability_available');
  const rendererRaw = str(pick(raw, 'renderer', 'source'), 'unknown');
  const renderer = rendererRaw === 'media-gst' || rendererRaw === 'stub' ? rendererRaw : 'unknown';
  const capabilities = arr(pick(raw, 'capabilities', 'features')).map((capability) => str(capability)).filter(Boolean);
  return {
    available: absent ? false : availableRaw === undefined ? true : Boolean(availableRaw),
    renderer,
    canReceiveCalls: Boolean(pick(raw, 'canReceiveCalls', 'can_receive_calls')) || capabilities.includes('call.receive'),
    canViewScreenShare:
      Boolean(pick(raw, 'canViewScreenShare', 'can_view_screen_share')) || capabilities.includes('mirror.viewer'),
    reason: str(pick(raw, 'reason', 'error')) || undefined
  };
}

function mapMercuryCaptureStatus(raw: RawJsonValue): MercuryCaptureStatus {
  const bitrateRaw = pick(raw, 'targetBitrateBps', 'target_bitrate_bps');
  const bitrate =
    typeof bitrateRaw === 'number'
      ? bitrateRaw
      : typeof bitrateRaw === 'string' && Number.isFinite(Number(bitrateRaw))
        ? Number(bitrateRaw)
        : undefined;
  return {
    active: Boolean(pick(raw, 'active')),
    sessionId: str(pick(raw, 'sessionId', 'session_id')) || undefined,
    source: str(pick(raw, 'source')) || undefined,
    codec: str(pick(raw, 'codec')) || undefined,
    targetBitrateBps: bitrate,
    socketConnected: Boolean(pick(raw, 'socketConnected', 'socket_connected'))
  };
}

// ─────────────────────────── Bridge loader ────────────────────────────────

export async function loadShellBridge(): Promise<LinuxShellBridge | null> {
  if (!('__TAURI_INTERNALS__' in window)) {
    return null;
  }
  return {
    daemonHealth: () => invoke<DaemonHealth>('daemon_health'),
    gatewayAuthToken: () => invoke<string | null>('gateway_auth_token'),
    openDashboard: () => invoke<void>('open_dashboard'),
    quitApp: () => invoke<void>('quit_app'),
    trayDegraded: () => invoke<boolean>('tray_degraded'),
    measurePerfOperation: (name) =>
      invoke<{
        name: string;
        ms: number;
        source: string;
        ok: boolean;
        detail?: string;
      }>('measure_perf_operation', { name }),

    // P01 — daemon.usage.recent → aggregated summary
    usageSummary: async () => {
      const raw = await invoke<RawJsonValue>('usage_summary');
      return mapUsageSummary(raw);
    },
    // P02 — daemon.config.get → provider catalog
    providerCatalog: async () => {
      const raw = await invoke<RawJsonValue>('provider_catalog');
      return mapProviderCatalog(raw);
    },
    // P03 — daemon.usage.recent → session list (client-side paginated by store)
    sessionList: async () => {
      const raw = await invoke<RawJsonValue>('session_list');
      return mapSessionList(raw);
    },
    // P03 — daemon.search.query → session search
    sessionSearch: async (query) => {
      const raw = await invoke<RawJsonValue>('session_search', { query });
      return mapSessionList(raw);
    },
    // P05 — daemon.usage.recent → insights aggregation
    usageInsights: async () => {
      const raw = await invoke<RawJsonValue>('usage_insights');
      return mapUsageInsights(raw);
    },
    // P06 — daemon.mission.list + pending approvals
    missionList: async () => {
      const raw = await invoke<RawJsonValue>('mission_list');
      return mapMissionList(raw);
    },
    // P06 — daemon.mission.approve / daemon.mission.cancel
    missionApprovalDecision: async (id, decision) => {
      await invoke<void>('mission_approval_decision', { id, decision });
    },
    // P06 — daemon.mission.create
    missionCreate: async (input) => {
      const raw = await invoke<RawJsonValue>('mission_create', input);
      return mapMissionMutation(raw);
    },
    // P07 — daemon.config.get → read-only settings snapshot
    configSnapshot: async () => {
      const raw = await invoke<RawJsonValue>('config_snapshot');
      return mapConfigSnapshot(raw);
    },
    configUpdate: async (snapshot) => {
      const raw = await invoke<RawJsonValue>('config_update', { snapshot });
      return snapshotFromMutation(raw);
    },
    providerCredentialSlotUpsert: async (params) => {
      const raw = await invoke<RawJsonValue>('provider_credential_slot_upsert', { params });
      return snapshotFromMutation(raw);
    },
    providerCredentialSlotRemove: async (providerID, slotID) => {
      const raw = await invoke<RawJsonValue>('provider_credential_slot_remove', { providerId: providerID, slotId: slotID });
      return snapshotFromMutation(raw);
    },
    providerModelVariantUpsert: async (providerID, variant) => {
      const raw = await invoke<RawJsonValue>('provider_model_variant_upsert', { providerId: providerID, variant });
      return snapshotFromMutation(raw);
    },
    providerModelVariantRemove: async (providerID, variantID) => {
      const raw = await invoke<RawJsonValue>('provider_model_variant_remove', { providerId: providerID, variantId: variantID });
      return snapshotFromMutation(raw);
    },
    providerModelAliasUpsert: async (providerID, alias) => {
      const raw = await invoke<RawJsonValue>('provider_model_alias_upsert', { providerId: providerID, alias });
      return snapshotFromMutation(raw);
    },
    providerModelAliasRemove: async (providerID, aliasID) => {
      const raw = await invoke<RawJsonValue>('provider_model_alias_remove', { providerId: providerID, aliasId: aliasID });
      return snapshotFromMutation(raw);
    },
    providerCustomModelUpsert: async (providerID, customModel) => {
      const raw = await invoke<RawJsonValue>('provider_custom_model_upsert', { providerId: providerID, customModel });
      return snapshotFromMutation(raw);
    },
    providerCustomModelRemove: async (providerID, modelID) => {
      const raw = await invoke<RawJsonValue>('provider_custom_model_remove', { providerId: providerID, modelId: modelID });
      return snapshotFromMutation(raw);
    },
    providerModelDisplayNameSet: async (providerID, modelID, displayName) => {
      const raw = await invoke<RawJsonValue>('provider_model_display_name_set', { providerId: providerID, modelId: modelID, displayName });
      return snapshotFromMutation(raw);
    },
    providerModelDisplayNameClear: async (providerID, modelID) => {
      const raw = await invoke<RawJsonValue>('provider_model_display_name_clear', { providerId: providerID, modelId: modelID });
      return snapshotFromMutation(raw);
    },
    proxyRouteLogRecent: async (limit) => {
      const raw = await invoke<RawJsonValue>('proxy_route_log_recent', { limit });
      return mapProxyRouteLog(raw);
    },
    proxyRouteLogClear: async () => {
      const raw = await invoke<RawJsonValue>('proxy_route_log_clear');
      return Boolean(pick(raw, 'cleared'));
    },
    notificationConfigGet: async () => {
      const raw = await invoke<RawJsonValue>('notification_config_get');
      return mapNotificationConfig(raw);
    },
    notificationConfigUpdate: async (config) => {
      const raw = await invoke<RawJsonValue>('notification_config_update', { config });
      return mapNotificationConfig(raw);
    },
    notificationHealth: async () => {
      const raw = await invoke<RawJsonValue>('notification_health');
      return mapNotificationHealth(raw);
    },
    notificationCommand: async (command, args = []) => {
      const raw = await invoke<RawJsonValue>('notification_command', { command, arguments: args });
      return mapNotificationCommand(raw);
    },
    // P07 — derived from daemon.config.get + daemon.health
    dbStatus: async () => {
      const raw = await invoke<RawJsonValue>('db_status');
      return mapDbStatus(raw);
    },
    // P07 — daemon.controller.project.list
    projectList: async () => {
      const raw = await invoke<RawJsonValue>('project_list');
      return mapProjectList(pick(raw, 'result', 'projects') ?? raw);
    },
    // P07 — daemon.memory.analytics
    memoryBoundaries: async () => {
      const raw = await invoke<RawJsonValue>('memory_boundaries');
      return mapMemoryBoundaries(raw);
    },
    // P07 — daemon.memory.recall + daemon.memory.audit_trail
    memoryReviewInbox: async () => {
      const raw = await invoke<RawJsonValue>('memory_review_inbox');
      return mapMemoryReviewInbox(raw);
    },
    // P07 — daemon.memory.forget; daemon has no approve/reject review-row RPC on Linux.
    memoryReviewDecision: async (id, decision) => {
      if (decision === 'rejected') {
        await invoke<RawJsonValue>('memory_forget', { memoryId: id });
      }
    },
    // P07 — daemon.code.index_status + explore + diagnostics + ops_diagnostics
    databaseWorkspaceStatus: async (projectPath) => {
      const raw = await invoke<RawJsonValue>('database_workspace_status', { projectPath });
      return mapDatabaseWorkspaceStatus(raw);
    },
    // P07 — daemon.code.index_project
    databaseIndexProject: async (projectPath) => {
      const raw = await invoke<RawJsonValue>('database_index_project', { projectPath });
      return mapDatabaseIndexAction(raw);
    },
    // P07 — daemon.code.watch_project (poll-only on Linux)
    databaseWatchProject: async (projectPath) => {
      const raw = await invoke<RawJsonValue>('database_watch_project', { projectPath });
      return mapDatabaseIndexAction(raw);
    },
    // P08 — derived from daemon.config.get (cloud/sync subtree)
    accountStatus: async () => {
      const raw = await invoke<RawJsonValue>('account_status');
      return mapAccountStatus(raw);
    },
    // P10 — daemon-owned membership data; fail closed if absent.
    membershipStatus: async () => {
      const raw = await invoke<RawJsonValue>('membership_status');
      return mapMembershipStatus(raw);
    },
    // P10 — daemon-minted URL only; opened externally by membershipStore.
    membershipCheckoutUrl: async () => {
      const raw = await invoke<RawJsonValue>('membership_checkout_url');
      return mapMembershipCheckoutUrl(raw);
    },
    openExternalUrl: (url) => openExternal(url),
    // P10 — daemon-side restore hook; callers re-fetch status afterwards.
    membershipRestore: async () => {
      await invoke<RawJsonValue>('membership_restore');
    },
    // P09 — local version info
    appVersionInfo: async () => {
      const raw = await invoke<RawJsonValue>('app_version_info');
      return mapAppVersionInfo(raw);
    },
    // P09 — redacted diagnostics export → file path
    exportDiagnostics: async () => {
      const raw = await invoke<RawJsonValue>('export_diagnostics');
      return { path: str(pick(raw, 'path')) };
    },
    // P11 — session env for pet tier detection
    sessionEnv: async () => {
      const raw = await invoke<RawJsonValue>('session_env');
      return {
        XDG_SESSION_TYPE: str(pick(raw, 'xdg_session_type', 'XDG_SESSION_TYPE')) || undefined,
        XDG_CURRENT_DESKTOP: str(pick(raw, 'xdg_current_desktop', 'XDG_CURRENT_DESKTOP')) || undefined
      };
    },
    // P12 — daemon media_status / media.control observation
    mediaStatus: async () => {
      try {
        const raw = await invoke<RawJsonValue>('media_status');
        return mapMercuryMediaStatus(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return { capabilityAvailable: false, pairedDevices: [] };
        }
        throw e;
      }
    },
    mediaSessionState: async () => {
      try {
        const raw = await invoke<RawJsonValue>('media_session_state');
        return mapMercurySessionState(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return { phase: 'capability-absent', kind: 'call', capabilityAvailable: false };
        }
        throw e;
      }
    },
    mediaAcceptCall: async (requestId) => {
      try {
        const raw = await invoke<RawJsonValue>('media_accept_call', { requestId });
        return mapMercurySessionState(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return { phase: 'capability-absent', requestId, kind: 'call', capabilityAvailable: false };
        }
        throw e;
      }
    },
    mediaDeclineCall: async (requestId) => {
      try {
        const raw = await invoke<RawJsonValue>('media_decline_call', { requestId });
        return mapMercurySessionState(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return { phase: 'capability-absent', requestId, kind: 'call', capabilityAvailable: false };
        }
        throw e;
      }
    },
    mediaEndCall: async () => {
      try {
        const raw = await invoke<RawJsonValue>('media_end_call');
        return mapMercurySessionState(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return { phase: 'capability-absent', kind: 'call', capabilityAvailable: false };
        }
        throw e;
      }
    },
    mediaCapabilityGet: async () => {
      try {
        const raw = await invoke<RawJsonValue>('media_capability_get');
        return mapMercuryCapability(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return {
            available: false,
            renderer: 'unknown',
            canReceiveCalls: false,
            canViewScreenShare: false,
            reason: e instanceof Error ? e.message : String(e)
          };
        }
        throw e;
      }
    },
    mediaCaptureStartPipeWire: async (sessionId, pwFd, pwNodeId, targetBitrateBps, codec) => {
      const raw = await invoke<RawJsonValue>('media_capture_start_pipewire', {
        sessionId,
        pwFd,
        pwNodeId,
        targetBitrateBps,
        codec
      });
      return mapMercuryCaptureStatus(raw);
    },
    mediaCaptureStartTest: async (sessionId, numBuffers, targetBitrateBps, codec) => {
      const raw = await invoke<RawJsonValue>('media_capture_start_test', {
        sessionId,
        numBuffers,
        targetBitrateBps,
        codec
      });
      return mapMercuryCaptureStatus(raw);
    },
    mediaCaptureStop: async () => {
      const raw = await invoke<RawJsonValue>('media_capture_stop');
      return mapMercuryCaptureStatus(raw);
    },
    mediaCaptureStatus: async () => {
      const raw = await invoke<RawJsonValue>('media_capture_status');
      return mapMercuryCaptureStatus(raw);
    },
    // P13 — daemon-reported smart-display/device integration status.
    integrationsStatus: async () => {
      const raw = await invoke<RawJsonValue>('integrations_status');
      return mapIntegrationsStatus(raw);
    }
  };
}
