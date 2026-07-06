import { invoke } from '@tauri-apps/api/core';
import type { DaemonHealth } from './daemonClient.js';

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

// ─────────────────────────── P08: account ─────────────────────────────────

export type AccountStatus = {
  signedIn: boolean;
  identityLabel?: string;
  trustClass: 'linux-lower-trust';
  syncState: 'local-only' | 'paused' | 'active';
  lastSyncAt?: string;
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

// ─────────────────────────── Bridge contract ──────────────────────────────

export interface LinuxShellBridge {
  daemonHealth(): Promise<DaemonHealth>;
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
  configSnapshot(): Promise<ConfigSnapshot>;
  dbStatus(): Promise<DbStatus>;
  projectList(): Promise<ProjectEntry[]>;
  memoryBoundaries(): Promise<MemoryBoundary[]>;
  accountStatus(): Promise<AccountStatus>;
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
  return { weekly, providerMix, modelMix, cacheHitRatePct: 0 };
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
  const items = arr(pick(raw, 'boundaries', 'scopes', 'analytics'));
  return items.map(
    (m, i): MemoryBoundary => ({
      id: str(pick(m, 'id', 'scopeId'), `mem-${i}`),
      scope: str(pick(m, 'scope', 'projectSlug'), 'workspace'),
      label: str(pick(m, 'label', 'name'), `Memory scope ${i + 1}`),
      detail: str(pick(m, 'detail', 'description', 'policy'), 'Recall boundary active')
    })
  );
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

function mapAppVersionInfo(raw: RawJsonValue): AppVersionInfo {
  return {
    shellVersion: str(pick(raw, 'shellVersion', 'shell_version')),
    daemonVersion: str(pick(raw, 'daemonVersion', 'daemon_version')),
    packageChannel: normalizeChannel(str(pick(raw, 'packageChannel', 'package_channel'), 'unknown')),
    updateCheck: 'unavailable-in-shell'
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

// ─────────────────────────── Bridge loader ────────────────────────────────

export async function loadShellBridge(): Promise<LinuxShellBridge | null> {
  if (!('__TAURI_INTERNALS__' in window)) {
    return null;
  }
  return {
    daemonHealth: () => invoke<DaemonHealth>('daemon_health'),
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
    // P08 — derived from daemon.config.get (cloud/sync subtree)
    accountStatus: async () => {
      const raw = await invoke<RawJsonValue>('account_status');
      return mapAccountStatus(raw);
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
    }
  };
}
