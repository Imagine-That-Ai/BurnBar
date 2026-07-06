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

// ─────────────────────────── P09: version / diagnostics ───────────────────

export type AppVersionInfo = {
  shellVersion: string;
  daemonVersion: string;
  packageChannel: 'deb' | 'appimage' | 'unknown';
  updateCheck: string;
};
export type DiagnosticsExport = { path: string };

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
  appVersionInfo(): Promise<AppVersionInfo>;
  exportDiagnostics(): Promise<DiagnosticsExport>;
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
    privacyOptIn: Boolean(pick(snap, 'privacyOptIn', 'privacy_opt_in'))
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

function mapAppVersionInfo(raw: RawJsonValue): AppVersionInfo {
  return {
    shellVersion: str(pick(raw, 'shellVersion', 'shell_version')),
    daemonVersion: str(pick(raw, 'daemonVersion', 'daemon_version')),
    packageChannel: normalizeChannel(str(pick(raw, 'packageChannel', 'package_channel'), 'unknown')),
    updateCheck: 'unavailable-in-shell'
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
