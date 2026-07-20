import type {
  ConfigSnapshot,
  ProviderCredentialSlot,
  ModelVariant,
  ModelAlias,
  ModelDisplayOverride,
  CustomModel,
  ProviderSettings,
  DbStatus,
  ProjectRecord,
  ProjectDeleteResult,
  ProjectReassignResult,
  ProjectHistoryEvent,
  ProjectEntry,
  MemoryBoundary,
  MemoryReviewStatus,
  MemoryReviewItem,
  MemoryReviewInbox,
  DatabaseWorkspaceFile,
  DatabaseWorkspaceDiagnostic,
  DatabaseWorkspaceStatus,
  DatabaseIndexActionResult,
  DatabaseSnapshotResult,
  DatabaseRecoveryBundleExportResult,
  DatabaseRecoveryPhase,
  DatabaseRecoveryAction,
  DatabaseRecoveryStatusResult,
  DatabaseRecoveryBundleImportResult,
  DatabaseCodeDegradation,
  DatabaseCodeTrustSignal,
  DatabaseCodeSearchHit,
  DatabaseCodeSearchResult,
  DatabaseCodeContextPackResult,
  AccountStatus,
  AccountSignInOperation,
  AccountCloudDataDeletionResult,
  MembershipTier,
  MembershipStatus,
  AppVersionInfo,
  LinuxUpdateArtifact,
  LinuxUpdateAction,
  LinuxUpdateInstructions,
  LinuxUpdateChannelInfo,
  LinuxUpdateCompatibility,
  LinuxUpdateStatus,
  DiagnosticsExportPreview,
  DiagnosticsExport,
  IntegrationKind,
  IntegrationState,
  IntegrationStatus,
  IntegrationsStatus,
  SmartHubOperation,
  SmartHubDiscoveryResult,
  SmartHubStatusResult,
  SmartHubCommandResult
} from './tauriBridgeTypes.js';
import {
  DATABASE_CODE_MAX_RESULTS
} from './tauriBridgeTypes.js';
import type { RawJsonValue } from './tauriBridgeRaw.js';
import {
  num,
  str,
  arr,
  obj,
  pick,
  requireObject,
  requireBoolean
} from './tauriBridgeRaw.js';
import { ENTITLEMENT_DOC_IDS, evaluateEntitlement } from '@openburnbar/entitlements';

function normalizeChannel(s: string): AppVersionInfo['packageChannel'] {
  const lower = s.toLowerCase();
  if (lower.includes('deb')) return 'deb';
  if (lower.includes('rpm')) return 'rpm';
  if (lower === 'arch' || lower.includes('pacman')) return 'arch';
  if (lower.includes('appimage') || lower.includes('app-image')) return 'appimage';
  return 'unknown';
}

export function mapConfigSnapshot(raw: RawJsonValue): ConfigSnapshot {
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
    cloudSyncEnabled: Boolean(pick(snap, 'cloudSyncEnabled', 'cloud_sync_enabled')),
    providers: arr(pick(snap, 'providers')).map(mapProviderSettings),
    routerMode: str(pick(snap, 'routerMode'), 'provider_family_failover')
  };
}

export function mapProviderSettings(raw: RawJsonValue, i = 0): ProviderSettings {
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

export function mapCredentialSlot(raw: RawJsonValue, i = 0): ProviderCredentialSlot {
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

export function mapModelVariant(raw: RawJsonValue, i = 0): ModelVariant {
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

export function mapModelAlias(raw: RawJsonValue, i = 0): ModelAlias {
  return {
    aliasID: str(pick(raw, 'aliasID', 'aliasId'), `alias-${i}`),
    baseModelID: str(pick(raw, 'baseModelID', 'baseModelId')),
    displayName: str(pick(raw, 'displayName')),
    hidesBaseModel: Boolean(pick(raw, 'hidesBaseModel')),
    createdAt: str(pick(raw, 'createdAt')) || undefined,
    updatedAt: str(pick(raw, 'updatedAt')) || undefined
  };
}

export function mapModelDisplayOverride(raw: RawJsonValue): ModelDisplayOverride {
  return {
    modelID: str(pick(raw, 'modelID', 'modelId')),
    displayName: str(pick(raw, 'displayName')),
    createdAt: str(pick(raw, 'createdAt')) || undefined,
    updatedAt: str(pick(raw, 'updatedAt')) || undefined
  };
}

export function mapCustomModel(raw: RawJsonValue): CustomModel {
  return {
    modelID: str(pick(raw, 'modelID', 'modelId')),
    displayName: str(pick(raw, 'displayName')),
    createdAt: str(pick(raw, 'createdAt')) || undefined,
    updatedAt: str(pick(raw, 'updatedAt')) || undefined
  };
}

export function mapDbStatus(raw: RawJsonValue): DbStatus {
  // Derived from daemon.config.get + daemon.health — no dedicated db RPC exists.
  return {
    sqlcipherOk: Boolean(pick(raw, 'sqlcipherOk', 'sqlcipher_ok', 'encrypted')),
    migrationVersion: num(pick(raw, 'migrationVersion', 'migration_version', 'schemaVersion')),
    sizeBytes: num(pick(raw, 'sizeBytes', 'size_bytes', 'dbSize')),
    walMode: Boolean(pick(raw, 'walMode', 'wal_mode', 'walEnabled'))
  };
}

export function projectEnum<T extends string>(
  raw: RawJsonValue,
  allowed: readonly T[],
  fallback: T | 'unknown'
): T | 'unknown' {
  const value = str(raw);
  return (allowed as readonly string[]).includes(value) ? (value as T) : fallback;
}

export function optionalProjectNumber(raw: RawJsonValue): number | undefined {
  if (raw === undefined || raw === null || raw === '') return undefined;
  const value = num(raw, Number.NaN);
  return Number.isFinite(value) ? value : undefined;
}

export function unwrapProjectResponse(raw: RawJsonValue): RawJsonValue {
  return pick(raw, 'result') ?? raw;
}

export function mapProjectRecord(raw: RawJsonValue, index = 0): ProjectRecord | null {
  const response = unwrapProjectResponse(raw);
  const project = pick(response, 'project');
  const source = project === null || project === undefined ? response : project;
  if (!source || typeof source !== 'object' || Array.isArray(source)) return null;

  // The slug is the daemon's stable association key. If an older daemon omits
  // the separate id, using the slug remains deterministic; display names and
  // paths are deliberately never used as identity fallbacks.
  const projectSlug = str(pick(source, 'projectSlug', 'project_slug', 'slug'));
  const displayName = str(pick(source, 'displayName', 'display_name', 'name', 'title'));
  if (!projectSlug || !displayName) return null;

  return {
    id: str(pick(source, 'id', 'projectID', 'projectId'), projectSlug || `project-${index}`),
    projectSlug,
    displayName,
    summary: str(pick(source, 'summary', 'description')),
    status: projectEnum(
      pick(source, 'status'),
      ['healthy', 'needs_attention', 'stale', 'onboarding', 'paused'] as const,
      'unknown'
    ),
    preferredCadence: projectEnum(pick(source, 'preferredCadence', 'preferred_cadence'), ['daily', 'weekly', 'ad_hoc'] as const, 'unknown'),
    aliases: arr(pick(source, 'aliases')).map((alias) => str(alias)).filter(Boolean),
    automationMode: projectEnum(pick(source, 'automationMode', 'automation_mode'), ['manual', 'suggested', 'scheduled'] as const, 'unknown'),
    reviewModelID: str(pick(source, 'reviewModelID', 'reviewModelId', 'review_model_id')) || undefined,
    scheduleHourLocal: optionalProjectNumber(pick(source, 'scheduleHourLocal', 'schedule_hour_local')),
    scheduleWeekdayLocal: optionalProjectNumber(pick(source, 'scheduleWeekdayLocal', 'schedule_weekday_local')),
    freshness: projectEnum(pick(source, 'freshness'), ['fresh', 'aging', 'stale', 'provisional', 'missing'] as const, 'unknown'),
    latestDailyReviewAt: str(pick(source, 'latestDailyReviewAt', 'latest_daily_review_at')) || undefined,
    latestWeeklyReviewAt: str(pick(source, 'latestWeeklyReviewAt', 'latest_weekly_review_at')) || undefined,
    nextScheduledReviewAt: str(pick(source, 'nextScheduledReviewAt', 'next_scheduled_review_at')) || undefined,
    pendingQuestionCount: num(pick(source, 'pendingQuestionCount', 'pending_question_count')),
    openFollowupCount: num(pick(source, 'openFollowupCount', 'open_followup_count')),
    activeMissionCount: num(pick(source, 'activeMissionCount', 'active_mission_count')),
    activeMissionID: str(pick(source, 'activeMissionID', 'activeMissionId', 'active_mission_id')) || undefined,
    needsOperatorAttention: Boolean(pick(source, 'needsOperatorAttention', 'needs_operator_attention')),
    ingestionSource: projectEnum(pick(source, 'ingestionSource', 'ingestion_source'), ['manual', 'app_activity'] as const, 'unknown'),
    metadata: obj(pick(source, 'metadata'))
  };
}

export function mapProjectDeleteResult(raw: RawJsonValue): ProjectDeleteResult {
  const response = unwrapProjectResponse(raw);
  const projectSlug = str(pick(response, 'projectSlug', 'project_slug'));
  if (!projectSlug) throw new Error('The daemon returned an invalid project deletion result.');
  return {
    projectSlug,
    deleted: Boolean(pick(response, 'deleted'))
  };
}

export function mapProjectReassignResult(raw: RawJsonValue): ProjectReassignResult {
  const response = unwrapProjectResponse(raw);
  const sourceProjectSlug = str(pick(response, 'sourceProjectSlug', 'source_project_slug'));
  const targetProjectSlug = str(pick(response, 'targetProjectSlug', 'target_project_slug'));
  if (!sourceProjectSlug || !targetProjectSlug) {
    throw new Error('The daemon returned an invalid project reassignment result.');
  }
  return {
    sourceProjectSlug,
    targetProjectSlug,
    updatedReferenceCount: num(pick(response, 'updatedReferenceCount', 'updated_reference_count'))
  };
}

export function mapProjectHistory(raw: RawJsonValue, projectSlug: string): ProjectHistoryEvent[] {
  const response = unwrapProjectResponse(raw);
  const summary = pick(response, 'summary') ?? response;
  const events = arr(pick(summary, 'recentEvents', 'recent_events'));
  return events
    .map((event): ProjectHistoryEvent | null => {
      const id = str(pick(event, 'id', 'eventID', 'eventId'));
      const eventProjectSlug = str(pick(event, 'projectSlug', 'project_slug'), projectSlug);
      const eventType = str(pick(event, 'eventType', 'event_type'));
      const summaryText = str(pick(event, 'summary'));
      const recordedAt = str(pick(event, 'recordedAt', 'recorded_at'));
      if (!id || !eventProjectSlug || !eventType || !summaryText || !recordedAt) return null;
      if (eventProjectSlug !== projectSlug) return null;
      return {
        id,
        projectSlug: eventProjectSlug,
        eventType,
        summary: summaryText,
        detail: str(pick(event, 'detail')) || undefined,
        recordedAt,
        sequence: num(pick(event, 'sequence')),
        isReplay: Boolean(pick(event, 'isReplay', 'is_replay'))
      };
    })
    .filter((event): event is ProjectHistoryEvent => event !== null)
    .sort((lhs, rhs) => rhs.sequence - lhs.sequence);
}

export function mapProjectList(raw: RawJsonValue): ProjectEntry[] {
  const response = unwrapProjectResponse(raw);
  const projects = Array.isArray(response) ? response : arr(pick(response, 'projects', 'items'));
  return projects
    .map((project, index) => mapProjectRecord(project, index))
    .filter((project): project is ProjectRecord => project !== null)
    .map((record): ProjectEntry => ({
      id: record.id,
      name: record.displayName,
      // The controller project contract has no filesystem path. Do not infer
      // one from a display name or session title.
      path: '',
      scope: 'controller',
      projectSlug: record.projectSlug,
      record
    }));
}

export function mapMemoryBoundaries(raw: RawJsonValue): MemoryBoundary[] {
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

export function rpcReportResult(raw: RawJsonValue): RawJsonValue {
  return pick(raw, 'ok') ? pick(raw, 'result') : undefined;
}

export function rpcReportError(raw: RawJsonValue): string | undefined {
  return pick(raw, 'ok') ? undefined : str(pick(raw, 'error')) || 'RPC failed';
}

export function mapMemoryReviewInbox(raw: RawJsonValue): MemoryReviewInbox {
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
    const daemonStatus = str(pick(hit, 'reviewStatus', 'review_status'));
    const status: MemoryReviewStatus = daemonStatus === 'quarantined'
      ? 'pending'
      : daemonStatus === 'rejected' || daemonStatus === 'forgotten'
        ? daemonStatus
        : 'approved';
    return {
      id,
      body: str(pick(hit, 'bodyRedacted', 'snippet', 'text', 'body'), '(Memory contents unavailable)'),
      kind: str(pick(hit, 'kind'), 'memory'),
      confidence: Math.max(0, Math.min(1, num(pick(hit, 'confidence'), 1))),
      sourceLabel: sourcePath || projectID || 'Daemon memory recall',
      status,
      canApprove: status === 'pending',
      auditHash: lastAuditBySubject.get(id)
    };
  });
  return {
    items,
    auditEvents,
    degradedReason: degradedReasons.join(' · ') || undefined
  };
}

export function mapDatabaseWorkspaceStatus(raw: RawJsonValue): DatabaseWorkspaceStatus {
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

export function mapDatabaseIndexAction(raw: RawJsonValue): DatabaseIndexActionResult {
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

export function mapDatabaseSnapshot(raw: RawJsonValue, restored: boolean): DatabaseSnapshotResult {
  const source = pick(raw, 'result') ?? raw;
  return {
    traceID: str(pick(source, 'traceID', 'traceId', 'trace_id')),
    snapshotPath: str(pick(source, restored ? 'restoredPath' : 'snapshotPath', 'path')),
    byteCount: num(pick(source, 'byteCount', 'bytes')),
    sha256: str(pick(source, 'sha256', 'sha256Hex')),
    schemaVersion: num(pick(source, 'schemaVersion')),
    databaseEncrypted: Boolean(pick(source, 'databaseEncrypted', 'encrypted')),
    integrityCheck: str(pick(source, 'integrityCheck'), 'unavailable'),
    createdAt: str(pick(source, 'createdAt')) || undefined,
    restoredAt: str(pick(source, 'restoredAt')) || undefined
  };
}

export function mapDatabaseRecoveryBundleExport(raw: RawJsonValue): DatabaseRecoveryBundleExportResult {
  return {
    destinationPath: str(pick(raw, 'destinationPath', 'destination_path'), ''),
    byteCount: Math.max(0, num(pick(raw, 'byteCount', 'byte_count'))),
    formatVersion: Math.max(0, num(pick(raw, 'formatVersion', 'format_version'), 1))
  };
}

export const DATABASE_RECOVERY_PHASES: readonly DatabaseRecoveryPhase[] = [
  'ready',
  'database_missing',
  'cipher_unavailable',
  'database_not_encrypted',
  'key_unavailable',
  'integrity_failed',
  'awaiting_database_verification',
  'unavailable'
];
export const DATABASE_RECOVERY_ACTIONS: readonly DatabaseRecoveryAction[] = [
  'none',
  'export_recovery_bundle',
  'import_recovery_bundle',
  'restore_encrypted_snapshot',
  'unlock_secret_store',
  'restart_daemon'
];

export function boundedRecoveryPhase(value: RawJsonValue): DatabaseRecoveryPhase {
  const phase = str(value);
  return (DATABASE_RECOVERY_PHASES as readonly string[]).includes(phase)
    ? phase as DatabaseRecoveryPhase
    : 'unavailable';
}

export function boundedRecoveryAction(value: RawJsonValue): DatabaseRecoveryAction {
  const action = str(value);
  return (DATABASE_RECOVERY_ACTIONS as readonly string[]).includes(action)
    ? action as DatabaseRecoveryAction
    : 'none';
}

export function mapDatabaseRecoveryStatus(raw: RawJsonValue): DatabaseRecoveryStatusResult {
  return {
    phase: boundedRecoveryPhase(pick(raw, 'phase')),
    code: str(pick(raw, 'code'), 'recovery_status_unavailable'),
    message: str(pick(raw, 'message'), 'Database recovery status is unavailable.'),
    recommendedAction: boundedRecoveryAction(pick(raw, 'recommendedAction', 'recommended_action')),
    canExport: Boolean(pick(raw, 'canExport', 'can_export')),
    canImport: Boolean(pick(raw, 'canImport', 'can_import')),
    databasePresent: Boolean(pick(raw, 'databasePresent', 'database_present')),
    databaseIntegrityVerified: Boolean(pick(raw, 'databaseIntegrityVerified', 'database_integrity_verified')),
    restartRequired: Boolean(pick(raw, 'restartRequired', 'restart_required'))
  };
}

export function mapDatabaseRecoveryBundleImport(raw: RawJsonValue): DatabaseRecoveryBundleImportResult {
  return {
    sourcePath: str(pick(raw, 'sourcePath', 'source_path'), ''),
    stored: Boolean(pick(raw, 'stored')),
    candidateKeyVerified: Boolean(pick(raw, 'candidateKeyVerified', 'candidate_key_verified')),
    databaseIntegrityVerified: Boolean(pick(raw, 'databaseIntegrityVerified', 'database_integrity_verified')),
    phase: boundedRecoveryPhase(pick(raw, 'phase')),
    recommendedAction: boundedRecoveryAction(pick(raw, 'recommendedAction', 'recommended_action')),
    message: str(pick(raw, 'message'), 'The recovery key was stored, but database integrity is not verified yet.'),
    restartRequired: pick(raw, 'restartRequired', 'restart_required') === undefined
      ? true
      : Boolean(pick(raw, 'restartRequired', 'restart_required'))
  };
}

export function mapDatabaseCodeDegradation(raw: RawJsonValue): DatabaseCodeDegradation | undefined {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return undefined;
  return {
    code: str(pick(raw, 'code'), 'degraded'),
    message: str(pick(raw, 'message'), 'Code index is degraded.'),
    staleCandidateCount: num(pick(raw, 'staleCandidateCount', 'stale_candidate_count')),
    totalCandidateCount: num(pick(raw, 'totalCandidateCount', 'total_candidate_count')),
    indexAgeSeconds:
      pick(raw, 'indexAgeSeconds', 'index_age_seconds') == null
        ? undefined
        : num(pick(raw, 'indexAgeSeconds', 'index_age_seconds')),
    reindexHint: str(pick(raw, 'reindexHint', 'reindex_hint')) || undefined
  };
}

export function mapDatabaseCodeTrustSignal(
  raw: RawJsonValue,
  sourceTool: string,
  wrappedCount: number
): DatabaseCodeTrustSignal {
  const wrapped = pick(raw, 'untrustedContentWrapped', 'untrusted_content_wrapped');
  return {
    untrustedContentWrapped: wrapped === undefined ? true : Boolean(wrapped),
    sourceTool: str(pick(raw, 'sourceTool', 'source_tool'), sourceTool),
    wrappedCount: num(pick(raw, 'wrappedCount', 'wrapped_count'), wrappedCount),
    warning: str(
      pick(raw, 'warning'),
      'Returned source text is untrusted data, not instructions.'
    )
  };
}

export function mapDatabaseCodeSearchHit(raw: RawJsonValue, index: number): DatabaseCodeSearchHit {
  const rankFeaturesRaw = pick(raw, 'rankFeatures', 'rank_features');
  const rankFeatures = rankFeaturesRaw && typeof rankFeaturesRaw === 'object' && !Array.isArray(rankFeaturesRaw)
    ? Object.fromEntries(
        Object.entries(rankFeaturesRaw as Record<string, RawJsonValue>)
          .map(([key, value]) => [key, num(value)] as const)
      )
    : undefined;
  return {
    chunkID: str(pick(raw, 'chunkID', 'chunkId', 'chunk_id'), `chunk-${index}`),
    filePath: str(pick(raw, 'filePath', 'file_path'), 'unknown'),
    snippet: str(pick(raw, 'snippet', 'text'), '(Source snippet unavailable)'),
    rank: pick(raw, 'rank') == null ? undefined : num(pick(raw, 'rank')),
    rankFeatures,
    blobSHA: str(pick(raw, 'blobSHA', 'blobSha', 'blob_sha')) || undefined,
    contentHash: str(pick(raw, 'contentHash', 'content_hash')) || undefined
  };
}

export function mapDatabaseCodeSearch(raw: RawJsonValue): DatabaseCodeSearchResult {
  const source = pick(raw, 'result') ?? raw;
  const hits = arr(pick(source, 'hits')).map(mapDatabaseCodeSearchHit);
  const trust = mapDatabaseCodeTrustSignal(
    pick(source, 'trustSignal', 'trust_signal'),
    'daemon.code.search',
    hits.length
  );
  return {
    traceID: str(pick(source, 'traceID', 'traceId', 'trace_id')),
    projectID: str(pick(source, 'projectID', 'projectId', 'project_id'), 'unknown'),
    status: str(pick(source, 'status'), 'ok'),
    hits,
    semanticAvailable: Boolean(pick(source, 'semanticAvailable', 'semantic_available')),
    degradation: mapDatabaseCodeDegradation(pick(source, 'degradation')),
    trustSignal: trust
  };
}

export function mapDatabaseCodeContextPack(raw: RawJsonValue): DatabaseCodeContextPackResult {
  const source = pick(raw, 'result') ?? raw;
  const hits = arr(pick(source, 'hits')).map(mapDatabaseCodeSearchHit);
  const trust = mapDatabaseCodeTrustSignal(
    pick(source, 'trustSignal', 'trust_signal'),
    'daemon.code.context_pack',
    hits.length
  );
  return {
    traceID: str(pick(source, 'traceID', 'traceId', 'trace_id')),
    projectID: str(pick(source, 'projectID', 'projectId', 'project_id'), 'unknown'),
    status: str(pick(source, 'status'), 'ok'),
    context: str(pick(source, 'context')),
    hits,
    truncated: Boolean(pick(source, 'truncated')),
    semanticAvailable: Boolean(pick(source, 'semanticAvailable', 'semantic_available')),
    degradation: mapDatabaseCodeDegradation(pick(source, 'degradation')),
    trustSignal: trust
  };
}

export function clampDatabaseCodeLimit(limit: number | undefined, fallback: number): number {
  const value = Number.isFinite(limit) ? Math.trunc(limit as number) : fallback;
  return Math.max(1, Math.min(DATABASE_CODE_MAX_RESULTS, value));
}

export function normalizeDatabaseCodeQuery(query: string): string {
  const normalized = query.trim();
  if (!normalized) throw new Error('Code search query must not be empty.');
  return normalized.slice(0, 512);
}

export function mapAccountStatus(raw: RawJsonValue): AccountStatus {
  const status = pick(raw, 'status') ?? raw;
  const rawSignedIn = Boolean(pick(status, 'signedIn', 'signed_in', 'authenticated'));
  // The daemon's Linux auth authority deliberately collapses refreshing,
  // locked, configuration-required, and error phases into an unavailable
  // public state. Keep those failures visible instead of silently treating an
  // unknown/new phase as signed out (which could offer the wrong destructive
  // controls or hide a recoverable cloud session).
  const rawState = str(pick(status, 'state'), rawSignedIn ? 'active' : 'signed_out')
    .trim()
    .toLowerCase()
    .replace(/-/g, '_');
  const state: NonNullable<AccountStatus['state']> = rawState === 'authorizing'
    ? 'authorizing'
    : rawState === 'awaiting_device_approval' || rawState === 'awaitingdeviceapproval'
      ? 'awaiting-device-approval'
      : rawState === 'active' || rawState === 'ready'
        ? 'active'
        : rawState === 'signed_out' || rawState === 'signedout'
          ? 'signed-out'
          : 'unavailable';
  // Transitional and unavailable phases must not carry forward an old
  // authenticated identity into renderer controls. The daemon may include
  // signedIn/email while explaining a stale or rejected session; that is
  // diagnostic input, not proof that cloud actions are safe to present.
  const signedIn = rawSignedIn && (state === 'active' || state === 'awaiting-device-approval');
  const syncStateRaw = str(pick(status, 'syncState', 'sync_state'), signedIn ? 'active' : 'local-only');
  const syncState: AccountStatus['syncState'] = !signedIn
    ? 'local-only'
    : syncStateRaw === 'active' || syncStateRaw === 'cloud-ready'
      ? 'active'
      : syncStateRaw === 'paused'
        ? 'paused'
        : 'local-only';
  return {
    state,
    signedIn,
    identityLabel: signedIn ? str(pick(status, 'identityLabel', 'email', 'label')) || undefined : undefined,
    trustClass: 'linux-lower-trust',
    syncState,
    lastSyncAt: str(pick(status, 'lastSyncAt', 'last_sync_at')) || undefined,
    authorizationOperationID: str(pick(status, 'authorizationOperationID', 'authorization_operation_id')) || undefined,
    authorizationExpiresAt: str(pick(status, 'authorizationExpiresAt', 'authorization_expires_at')) || undefined,
    deviceApprovalRequired: Boolean(pick(status, 'deviceApprovalRequired', 'device_approval_required')),
    installationDeviceID: str(pick(status, 'installationDeviceID', 'installation_device_id')) || undefined,
    installationSafetyFingerprint:
      str(pick(status, 'installationSafetyFingerprint', 'installation_safety_fingerprint')) || undefined,
    detail: str(pick(status, 'detail')) || undefined
  };
}

export function mapAccountCloudDataDeletionResult(raw: RawJsonValue): AccountCloudDataDeletionResult {
  const value = obj(pick(raw, 'result') ?? raw);
  const count = (key: string): number => {
    const result = Math.trunc(num(pick(value, key)));
    if (result < 0 || result > 100_000_000) {
      throw new Error('Native account erasure returned an invalid count.');
    }
    return result;
  };
  const result: AccountCloudDataDeletionResult = {
    ok: requireBoolean(pick(value, 'ok'), 'account erasure.ok'),
    cloudDataDeleted: requireBoolean(
      pick(value, 'cloudDataDeleted', 'cloud_data_deleted'),
      'account erasure.cloudDataDeleted'
    ),
    retryRequired: requireBoolean(
      pick(value, 'retryRequired', 'retry_required'),
      'account erasure.retryRequired'
    ),
    deletedDocuments: count('deletedDocuments'),
    destroyedSecrets: count('destroyedSecrets'),
    failedSecretDestroys: count('failedSecretDestroys'),
    deletedStoragePrefixes: count('deletedStoragePrefixes'),
    failedStorageDeletes: count('failedStorageDeletes'),
    deletedAuthUser: requireBoolean(pick(value, 'deletedAuthUser'), 'account erasure.deletedAuthUser'),
    authUserAlreadyMissing: requireBoolean(
      pick(value, 'authUserAlreadyMissing'),
      'account erasure.authUserAlreadyMissing'
    )
  };
  if (!result.ok || !result.cloudDataDeleted) {
    throw new Error('Native account erasure did not complete.');
  }
  return result;
}

export function mapAccountSignInOperation(raw: RawJsonValue): AccountSignInOperation {
  const operationID = str(pick(raw, 'operationID', 'operationId'));
  const expiresAt = str(pick(raw, 'expiresAt'));
  if (!operationID || !expiresAt || !Number.isFinite(Date.parse(expiresAt))) {
    throw new Error('Daemon returned an invalid sign-in operation.');
  }
  return { operationID, expiresAt };
}

export function mapMembershipStatus(raw: RawJsonValue): MembershipStatus {
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

export function normalizeMembershipState(value: string): MembershipStatus['state'] | undefined {
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

export function mapMembershipCheckoutUrl(raw: RawJsonValue): string {
  const value = str(pick(raw, 'url', 'checkoutUrl', 'checkout_url'));
  if (!value) throw new Error('Daemon did not return a Stripe checkout URL.');
  return value;
}

export function isSafeDiagnosticsPath(path: string): boolean {
  if (!path.startsWith('/') || path.includes('\\') || path.length > 4096) return false;
  if ([...path].some((character) => character.charCodeAt(0) < 0x20 || character.charCodeAt(0) === 0x7f)) {
    return false;
  }
  const segments = path.split('/');
  const interiorSegments = segments.slice(1, -1);
  if (interiorSegments.some((segment) => segment.length === 0 || segment === '.' || segment === '..')) return false;
  const filename = segments.at(-1) ?? '';
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.json$/.test(filename);
}

export function isSafeDiagnosticsPreview(preview: DiagnosticsExportPreview): boolean {
  const validEntry = (entry: string): boolean =>
    entry.length > 0 && entry.length <= 256 && ![...entry].some((character) => character.charCodeAt(0) < 0x20 || character.charCodeAt(0) === 0x7f);
  return (
    preview.schemaVersion === 1 &&
    Number.isSafeInteger(preview.byteCount) &&
    preview.byteCount >= 0 &&
    preview.byteCount <= 10 * 1024 * 1024 &&
    preview.fileMode === '0600' &&
    preview.included.length <= 32 &&
    preview.excluded.length <= 32 &&
    preview.included.every(validEntry) &&
    preview.excluded.every(validEntry)
  );
}

export function mapDiagnosticsPreview(raw: RawJsonValue): DiagnosticsExportPreview {
  const preview = obj(raw);
  if (num(pick(preview, 'schemaVersion', 'schema_version')) !== 1) {
    throw new Error('Native diagnostics preview returned an unsupported schema.');
  }
  const byteCount = num(pick(preview, 'byteCount', 'byte_count'), -1);
  const fileMode = str(pick(preview, 'fileMode', 'file_mode'));
  const included = arr(pick(preview, 'included')).map((entry) => str(entry));
  const excluded = arr(pick(preview, 'excluded')).map((entry) => str(entry));
  const candidate = { schemaVersion: 1 as const, byteCount, fileMode: fileMode as '0600', included, excluded };
  if (!isSafeDiagnosticsPreview(candidate)) {
    throw new Error('Native diagnostics preview returned invalid privacy metadata.');
  }
  return candidate;
}

export function mapDiagnosticsExport(raw: RawJsonValue): DiagnosticsExport {
  const path = str(pick(raw, 'path')).trim();
  if (!isSafeDiagnosticsPath(path)) {
    throw new Error('Native diagnostics export returned an unsafe path.');
  }
  const previewRaw = pick(raw, 'preview');
  return {
    path,
    preview: previewRaw === undefined ? undefined : mapDiagnosticsPreview(previewRaw)
  };
}

export function mapAppVersionInfo(raw: RawJsonValue): AppVersionInfo {
  const packageRaw = obj(pick(raw, 'package'));
  const runtimeRaw = obj(pick(raw, 'runtime'));
  const packageChannel = normalizeChannel(
    str(pick(packageRaw, 'channel'), str(pick(raw, 'packageChannel', 'package_channel'), 'unknown'))
  );
  const packageInfo = Object.keys(packageRaw).length === 0
    ? undefined
    : {
        channel: packageChannel,
        manager: str(pick(packageRaw, 'manager'), 'unknown'),
        evidence: str(pick(packageRaw, 'evidence'), 'unknown')
      };
  const runtime = Object.keys(runtimeRaw).length === 0
    ? undefined
    : {
        os: str(pick(runtimeRaw, 'os'), 'unknown'),
        architecture: str(pick(runtimeRaw, 'architecture'), 'unknown'),
        kernel: str(pick(runtimeRaw, 'kernel')) || undefined,
        sessionType: str(pick(runtimeRaw, 'sessionType', 'session_type')) || undefined,
        desktop: str(pick(runtimeRaw, 'desktop')) || undefined,
        displayServer: str(pick(runtimeRaw, 'displayServer', 'display_server')) || undefined
      };
  return {
    shellVersion: str(pick(raw, 'shellVersion', 'shell_version')),
    daemonVersion: str(pick(raw, 'daemonVersion', 'daemon_version')),
    packageChannel,
    package: packageInfo,
    runtime
  };
}

export function decodeLinuxUpdateStatus(raw: RawJsonValue): LinuxUpdateStatus {
  const state = str(pick(raw, 'state'));
  if (!['current', 'available', 'unavailable', 'invalid'].includes(state)) {
    throw new Error('Native update check returned an invalid state.');
  }
  const artifactRaw = obj(pick(raw, 'artifact'));
  const artifactType = str(pick(artifactRaw, 'type'));
  const architecture = str(pick(artifactRaw, 'architecture'));
  const artifact = Object.keys(artifactRaw).length === 0
    ? undefined
    : {
        type: artifactType as LinuxUpdateArtifact['type'],
        architecture: architecture as LinuxUpdateArtifact['architecture'],
        url: str(pick(artifactRaw, 'url')),
        sha256: str(pick(artifactRaw, 'sha256')),
        size: num(pick(artifactRaw, 'size')),
        signatureUrl: str(pick(artifactRaw, 'signatureUrl', 'signature_url'))
      };
  if (
    artifact &&
    (!['appimage', 'arch', 'deb', 'rpm', 'daemon'].includes(artifact.type) ||
      !['aarch64', 'x86_64'].includes(artifact.architecture) ||
      !artifact.url ||
      !/^[a-f0-9]{64}$/.test(artifact.sha256) ||
      artifact.size <= 0 ||
      !artifact.signatureUrl)
  ) {
    throw new Error('Native update check returned invalid artifact metadata.');
  }
  const instructionsRaw = obj(pick(raw, 'instructions'));
  const packageManager = str(pick(instructionsRaw, 'packageManager', 'package_manager'));
  const parseAction = (key: 'install' | 'rollback' | 'restart'): LinuxUpdateAction | undefined => {
    const actionRaw = obj(pick(instructionsRaw, key));
    if (Object.keys(actionRaw).length === 0) return undefined;
    const id = str(pick(actionRaw, 'id'));
    const action: LinuxUpdateAction = {
      id: id as LinuxUpdateAction['id'],
      label: str(pick(actionRaw, 'label')),
      instruction: str(pick(actionRaw, 'instruction')),
      command: str(pick(actionRaw, 'command')) || undefined,
      available: Boolean(pick(actionRaw, 'available')),
      requiresConfirmation: Boolean(pick(actionRaw, 'requiresConfirmation', 'requires_confirmation'))
    };
    if (!['install', 'rollback', 'restart'].includes(action.id)
      || action.id !== key || !action.label || !action.instruction) {
      throw new Error('Native update check returned invalid package action metadata.');
    }
    if (action.command && /(?:[;&|`$<>\n\r]|\$\()/u.test(action.command)) {
      throw new Error('Native update check returned unsafe package action metadata.');
    }
    return action;
  };
  const parsedInstructions = {
    packageManager: packageManager as LinuxUpdateInstructions['packageManager'],
    install: parseAction('install'),
    rollback: parseAction('rollback'),
    restart: parseAction('restart')
  };
  const hasInstructions = ['apt', 'dnf', 'pacman', 'appimage', 'unknown'].includes(packageManager)
    && parsedInstructions.install
    && parsedInstructions.rollback
    && parsedInstructions.restart;
  if (Object.keys(instructionsRaw).length > 0 && !hasInstructions) {
    throw new Error('Native update check returned incomplete package instructions.');
  }
  const channelInfoRaw = obj(pick(raw, 'channelInfo', 'channel_info'));
  const channelInfoId = str(pick(channelInfoRaw, 'id'));
  const channelInfo = Object.keys(channelInfoRaw).length === 0
    ? undefined
    : {
        id: channelInfoId as LinuxUpdateChannelInfo['id'],
        label: str(pick(channelInfoRaw, 'label')),
        owner: str(pick(channelInfoRaw, 'owner')),
        installMode: str(pick(channelInfoRaw, 'installMode', 'install_mode')) as LinuxUpdateChannelInfo['installMode'],
        automaticInstall: Boolean(pick(channelInfoRaw, 'automaticInstall', 'automatic_install')),
        rollbackMode: str(pick(channelInfoRaw, 'rollbackMode', 'rollback_mode')),
        explanation: str(pick(channelInfoRaw, 'explanation'))
      };
  if (channelInfo && (
    !['deb', 'rpm', 'arch', 'appimage', 'unknown'].includes(channelInfo.id)
    || !channelInfo.label
    || !channelInfo.owner
    || !['package-manager-guided', 'artifact-replacement-guided', 'unavailable'].includes(channelInfo.installMode)
    || !channelInfo.rollbackMode
    || !channelInfo.explanation
  )) {
    throw new Error('Native update check returned invalid package channel metadata.');
  }
  const signatureStateRaw = str(pick(raw, 'signatureState', 'signature_state'));
  if (signatureStateRaw && !['verified', 'rejected', 'unknown'].includes(signatureStateRaw)) {
    throw new Error('Native update check returned invalid signature state.');
  }
  const feedFreshnessRaw = str(pick(raw, 'feedFreshness', 'feed_freshness'));
  if (feedFreshnessRaw && !['fresh', 'stale', 'future', 'unknown'].includes(feedFreshnessRaw)) {
    throw new Error('Native update check returned invalid feed freshness.');
  }
  const compatibilityRaw = obj(pick(raw, 'compatibility'));
  const compatibilityState = str(pick(compatibilityRaw, 'state'));
  const compatibility = Object.keys(compatibilityRaw).length === 0
    ? undefined
    : {
        state: compatibilityState as LinuxUpdateCompatibility['state'],
        shellVersion: str(pick(compatibilityRaw, 'shellVersion', 'shell_version')),
        daemonVersion: str(pick(compatibilityRaw, 'daemonVersion', 'daemon_version')) || undefined,
        reason: str(pick(compatibilityRaw, 'reason')) || undefined
      };
  if (compatibility && (
    !['aligned', 'mismatch', 'unknown'].includes(compatibility.state)
    || !compatibility.shellVersion
  )) {
    throw new Error('Native update check returned invalid shell/daemon compatibility.');
  }
  const channel = str(pick(raw, 'channel'));
  const packageChannelRaw = str(pick(raw, 'packageChannel', 'package_channel'));
  return {
    state: state as LinuxUpdateStatus['state'],
    currentVersion: str(pick(raw, 'currentVersion', 'current_version')),
    latestVersion: str(pick(raw, 'latestVersion', 'latest_version')) || undefined,
    channel: ['stable', 'prerelease', 'nightly'].includes(channel)
      ? channel as LinuxUpdateStatus['channel']
      : undefined,
    publishedAt: str(pick(raw, 'publishedAt', 'published_at')) || undefined,
    notes: str(pick(raw, 'notes')) || undefined,
    artifact,
    instructions: hasInstructions
      ? parsedInstructions as LinuxUpdateInstructions
      : undefined,
    packageChannel: ['deb', 'rpm', 'arch', 'appimage', 'unknown'].includes(packageChannelRaw)
      ? packageChannelRaw as LinuxUpdateChannelInfo['id']
      : undefined,
    channelInfo,
    signatureState: signatureStateRaw
      ? signatureStateRaw as LinuxUpdateStatus['signatureState']
      : undefined,
    feedFreshness: feedFreshnessRaw
      ? feedFreshnessRaw as LinuxUpdateStatus['feedFreshness']
      : undefined,
    feedAgeSeconds: num(pick(raw, 'feedAgeSeconds', 'feed_age_seconds'), -1) >= 0
      ? num(pick(raw, 'feedAgeSeconds', 'feed_age_seconds'))
      : undefined,
    checkedAtUnixSeconds: num(pick(raw, 'checkedAtUnixSeconds', 'checked_at_unix_seconds'), -1) >= 0
      ? num(pick(raw, 'checkedAtUnixSeconds', 'checked_at_unix_seconds'))
      : undefined,
    compatibility,
    reason: str(pick(raw, 'reason')) || undefined
  };
}

export function normalizeIntegrationKind(value: string): IntegrationKind {
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

export function normalizeIntegrationState(value: string): IntegrationState {
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

export function normalizeSmartHubOperation(value: RawJsonValue): SmartHubOperation {
  if (
    value === 'discover' ||
    value === 'status' ||
    value === 'test' ||
    value === 'cast' ||
    value === 'cast_status' ||
    value === 'homeassistant_status' ||
    value === 'device' ||
    value === 'pixel_clock_control' ||
    value === 'parity'
  ) {
    return value;
  }
  throw new Error('SmartHub operation is not allowlisted.');
}

export const SMART_HUB_MAX_ITEMS = 128;
export const SMART_HUB_MAX_FIELDS = 128;
export const SMART_HUB_MAX_TEXT_CHARS = 32_768;
export const SMART_HUB_MAX_INSTANCE_CHARS = 256;
export const SMART_HUB_MAX_RAW_TRANSCRIPT_CHARS = 32_768;

export function boundedSmartHubText(
  raw: RawJsonValue,
  label: string,
  max = SMART_HUB_MAX_TEXT_CHARS,
  allowEmpty = false
): string {
  if (typeof raw !== 'string' || (!allowEmpty && raw.length === 0)) {
    throw new Error(`${label} must be a${allowEmpty ? 'n' : ' non-empty'} string.`);
  }
  const value = raw;
  if (value.length > max) throw new Error(`${label} exceeds the SmartHub payload limit.`);
  if ([...value].some((character) => {
    const code = character.codePointAt(0) ?? 0;
    return code < 0x20 && code !== 0x09 && code !== 0x0a && code !== 0x0d;
  })) {
    throw new Error(`${label} contains an unsupported control character.`);
  }
  return value;
}

export function boundedSmartHubArray(raw: RawJsonValue, label: string): RawJsonValue[] {
  if (!Array.isArray(raw)) throw new Error(`${label} must be an array.`);
  if (raw.length > SMART_HUB_MAX_ITEMS) throw new Error(`${label} exceeds the item limit.`);
  return raw;
}

export function validateSmartHubFieldKeys(source: Record<string, RawJsonValue>, label: string): void {
  const entries = Object.entries(source);
  if (entries.length > SMART_HUB_MAX_FIELDS) throw new Error(`${label} has too many fields.`);
  for (const [key, value] of entries) {
    boundedSmartHubText(key, `${label} field name`, 256);
    if (typeof value === 'string') boundedSmartHubText(value, `${label} field ${key}`, SMART_HUB_MAX_TEXT_CHARS, true);
  }
}

export function mapSmartHubStatus(raw: RawJsonValue): SmartHubStatusResult {
  const source = requireObject(raw, 'SmartHub status payload');
  validateSmartHubFieldKeys(source, 'SmartHub status payload');
  const details: Record<string, string> = {};
  for (const [key, value] of Object.entries(source)) {
    if (typeof value !== 'string') {
      throw new Error(`SmartHub status field ${key} must be a string.`);
    }
    details[key] = boundedSmartHubText(value, `SmartHub status field ${key}`, SMART_HUB_MAX_TEXT_CHARS, true);
  }
  return {
    adapter: boundedSmartHubText(source.adapter, 'SmartHub status adapter'),
    status: boundedSmartHubText(source.status, 'SmartHub status state'),
    blocker: typeof source.blocker === 'string' && source.blocker.length > 0
      ? boundedSmartHubText(source.blocker, 'SmartHub status blocker')
      : undefined,
    details
  };
}

export function mapSmartHubParity(raw: RawJsonValue): IntegrationsStatus {
  const rows = boundedSmartHubArray(raw, 'SmartHub parity payload');
  rows.forEach((item, index) => {
    const row = requireObject(item, `SmartHub parity result ${index}`);
    validateSmartHubFieldKeys(row, `SmartHub parity result ${index}`);
    for (const [key, value] of Object.entries(row)) {
      if (value !== null && typeof value !== 'string') {
        throw new Error(`SmartHub parity result ${index} field ${key} must be a string.`);
      }
      if (typeof value === 'string') boundedSmartHubText(value, `SmartHub parity result ${index} field ${key}`, SMART_HUB_MAX_TEXT_CHARS, true);
    }
  });
  return mapIntegrationsStatus({ integrations: rows });
}

export function mapSmartHubCommand(raw: RawJsonValue): SmartHubCommandResult {
  const source = requireObject(raw, 'SmartHub command response');
  const operation = normalizeSmartHubOperation(source.operation);
  const payload = source.payload;
  if (payload === undefined) throw new Error('SmartHub command payload is missing.');
  if (operation === 'discover') {
    const rows = boundedSmartHubArray(payload, 'SmartHub discovery payload').map((item, index): SmartHubDiscoveryResult => {
      const row = requireObject(item, `SmartHub discovery result ${index}`);
      validateSmartHubFieldKeys(row, `SmartHub discovery result ${index}`);
      const instances = boundedSmartHubArray(row.instances, `SmartHub discovery result ${index} instances`).map((instance, instanceIndex) =>
        boundedSmartHubText(instance, `SmartHub discovery result ${index} instance ${instanceIndex}`, SMART_HUB_MAX_INSTANCE_CHARS)
      );
      return {
        adapter: boundedSmartHubText(row.adapter, `SmartHub discovery result ${index} adapter`),
        serviceType: boundedSmartHubText(row.serviceType, `SmartHub discovery result ${index} serviceType`, 256),
        instances,
        rawTranscript: boundedSmartHubText(row.rawTranscript, `SmartHub discovery result ${index} rawTranscript`, SMART_HUB_MAX_RAW_TRANSCRIPT_CHARS, true),
        status: row.status === undefined
          ? undefined
          : boundedSmartHubText(row.status, `SmartHub discovery result ${index} status`, 64),
        blocker: row.blocker === undefined || row.blocker === null
          ? undefined
          : boundedSmartHubText(row.blocker, `SmartHub discovery result ${index} blocker`, SMART_HUB_MAX_TEXT_CHARS, true) || undefined
      };
    });
    return { operation, payload: rows };
  }
  if (operation === 'parity') {
    return { operation, payload: mapSmartHubParity(payload) };
  }
  return { operation, payload: mapSmartHubStatus(payload) };
}

export function decodeSmartHubCommandResponse(raw: RawJsonValue): SmartHubCommandResult {
  return mapSmartHubCommand(raw);
}

export function mapIntegrationsStatus(raw: RawJsonValue): IntegrationsStatus {
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
