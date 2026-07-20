import type { DaemonHealth } from './daemonClient.js';
import type { RuntimeCapabilityManifest } from './runtimeCapabilities.js';
import type { LinuxOnboardingActionRequest, LinuxOnboardingSnapshot } from './onboardingStore.js';
import type { RawJsonValue } from './tauriBridgeRaw.js';


export type UsageSummary = {
  todayTokens: number;
  todayCostUsd: number;
  sevenDay: number[];
  recentEvents: { id: string; title: string; detail: string; at: string }[];
};

// ─────────────────────────── P02: provider catalog ─────────────────────────

export type QuotaBucketState = 'ok' | 'cooling_down' | 'missing_credential' | 'exhausted' | 'unknown';
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
  /** Canonical quota provenance from the daemon/macOS quota oracle. */
  quotaSourceKind?: 'provider' | 'officialAPI' | 'localCLI' | 'localSession' | 'manualEstimate' | 'unavailable';
  quotaSource?: string;
  quotaConfidence?: 'high' | 'medium' | 'low' | 'stale';
  quotaSourceID?: string;
  quotaFetchedAt?: string;
  quotaUpdatedAt?: string;
  quotaStale?: boolean;
  canonicalProviderID?: string;
  providerAliases?: string[];
  /** Optional account presentation metadata shared by quota/provider surfaces. */
  accountStorage?: 'cloud' | 'local' | 'keychain' | 'unknown';
  accountStatus?: 'connected' | 'stale' | 'error';
  planTierBadge?: string;
  /** Redacted credential-slot metadata used to explain account routing. */
  credentialSlots?: ProviderCredentialSlot[];
  /** Daemon preference; quota pressure may still drain to another eligible slot. */
  preferredCredentialSlotID?: string;
  /** Canonical daemon catalog models; empty means no model catalog was proven. */
  models?: ProviderCatalogModel[];
  /** Provider capabilities are daemon-advertised, never inferred from a logo. */
  capabilities?: string[];
  health?: ProviderHealthState;
  provenance?: ProviderCatalogProvenance;
  failover?: ProviderFailoverState;
  catalogAvailable?: boolean;
  catalogError?: string;
};
export type ProviderHealthState = 'healthy' | 'degraded' | 'unavailable' | 'unknown';
export type ProviderCatalogProvenance =
  | 'daemon-catalog'
  | 'daemon-config'
  | 'daemon-catalog+daemon-config'
  | 'fixture';
export type ProviderModelProvenance =
  | 'daemon-catalog'
  | 'daemon-config'
  | 'configured-model'
  | 'custom-model'
  | 'model-alias'
  | 'model-variant'
  | 'fixture';
export type ProviderCatalogModel = {
  id: string;
  label: string;
  aliases: string[];
  canonicalModelID?: string;
  capabilities: string[];
  enabled: boolean;
  health: ProviderHealthState;
  provenance: ProviderModelProvenance;
  detail?: string;
};
export type ProviderFailoverState = {
  mode: string;
  eligible: boolean;
  detail: string;
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
  /**
   * Canonical conversation identity when the daemon supplied one. This is
   * intentionally separate from `id`: usage rows can have a display/fallback
   * id that is not safe to pass to `run.resume`.
   */
  sourceID?: string;
  /**
   * Whether `sourceID` came from a daemon-provided canonical identity. A
   * normalized provider/session fallback remains useful for display/search,
   * but must be resolved against complete indexed history before replay/resume.
   */
  sourceIDVerified?: boolean;
  providerSessionID?: string;
  runID?: string;
  projectName?: string;
};
export type SessionListResult = {
  sessions: SessionEntry[];
  nextCursor: string | null;
  /** True only when the daemon explicitly says this bounded result is complete. */
  complete?: boolean;
};
export type SessionHistoryEntry = SessionEntry & {
  bodyMD: string;
};
export type SessionHistoryResult = {
  sessions: SessionHistoryEntry[];
  nextCursor: string | null;
  /** Derived from the daemon's explicit historyComplete proof and cursor. */
  complete: boolean;
  historyComplete: boolean;
  historyLimit: number;
  totalCount: number;
};
export type SessionReplayResult = {
  kind: string;
  briefingMD?: string;
  briefingTruncated: boolean;
  targetHarness?: string;
  workingDirectory?: string;
  note?: string;
  pid?: number;
  errorCode?: string;
  errorRecovery?: string;
};

// ──────────────────────────── Exact-thread chat ────────────────────────────

export type ChatThreadSummary = {
  id: string;
  title: string;
  preview: string;
  messageCount: number;
  createdAt: string;
  updatedAt: string;
  lastMessageAt?: string;
  backendID?: string;
};

export type PersistedChatMessageRole = 'user' | 'assistant' | 'system';

export type PersistedChatMessage = {
  id: string;
  threadID: string;
  role: PersistedChatMessageRole;
  content: string;
  timestamp: string;
  backendID?: string;
  /** Optional metadata only; Linux never returns attachment bytes or paths. */
  attachments?: ChatAttachmentUploadResult[];
};

export type ChatThreadListResult = { threads: ChatThreadSummary[] };
export type ChatMessageCursor = {
  timestamp: string;
  messageID: string;
};
export type ChatThreadGetResult = {
  thread?: ChatThreadSummary;
  messages: PersistedChatMessage[];
  hasMoreBefore: boolean;
};
export type ChatMessageAppendRequest = {
  threadID: string;
  messageID: string;
  role: PersistedChatMessageRole;
  content: string;
  timestamp: string;
  backendID?: string;
  /** Metadata only; the daemon persists no renderer-side file paths or bytes. */
  attachments?: ChatAttachmentUploadResult[];
};
export type ChatMessageAppendResult = { message: PersistedChatMessage; inserted: boolean };

// ─────────────────────────── P05: insights ────────────────────────────────

export type WeeklyPoint = { label: string; tokens: number; costUsd: number };
export type MixEntry = { id: string; label: string; pct: number };
export type UsageInsightsSource = {
  /** Stable authority identifier, not a renderer-generated citation. */
  id: 'daemon.usage.recent' | 'daemon.usage.insights' | 'fixture.usage.insights';
  kind: 'daemon-method' | 'fixture';
  label: string;
};
export type InsightsQualitativeCapability = {
  state: 'available' | 'degraded' | 'unavailable';
  reason: string;
  method?: string;
  sourceID?: string;
  analysis?: UsageInsightsQualitativeAnalysis;
};
export type UsageInsightsQualitativeCitation = { id: string; label: string };
export type UsageInsightsQualitativeFinding = {
  id: string;
  title: string;
  whyItMatters: string;
  recommendedAction: string;
  evidence: UsageInsightsQualitativeCitation[];
};
export type UsageInsightsQualitativeAnalysis = {
  requestID: string;
  generatedAt: string;
  executiveSummary: string;
  modelDisplayName: string;
  findings: UsageInsightsQualitativeFinding[];
  citations: UsageInsightsQualitativeCitation[];
};
export type UsageInsights = {
  weekly: WeeklyPoint[];
  providerMix: MixEntry[];
  modelMix: MixEntry[];
  cacheHitRatePct: number;
  /** Present when the daemon response carries a known source authority. */
  source?: UsageInsightsSource;
  /** Present when the daemon has produced a bounded local-rules brief. */
  qualitative?: InsightsQualitativeCapability;
};

// ─────────────────────────── P06: missions ────────────────────────────────

export type PendingApproval = {
  id: string;
  missionId: string;
  summary: string;
  requestedAt: string;
  risk: 'standard' | 'high';
};

/**
 * Mission-control snapshots are intentionally richer than the original P06
 * list projection. These fields mirror BurnBarMissionSnapshot in
 * OpenBurnBarCore; optional fields remain optional because older daemons may
 * return a projection without packets/results yet.
 */
export type MissionApprovalSnapshot = {
  approved: boolean;
  approvedAt?: string;
  approvedBy?: string;
  note?: string;
};
export type MissionPacketSnapshot = {
  id: string;
  missionId?: string;
  workerName: string;
  objective: string;
  status: string;
  runId?: string;
  dispatchedAt?: string;
  completedAt?: string;
  metadata: Record<string, unknown>;
};
export type MissionResultSnapshot = {
  id: string;
  missionId?: string;
  packetId?: string;
  runId?: string;
  status: string;
  summary: string;
  detail?: string;
  burnDelta: number;
  createdAt: string;
  evidenceRefs: string[];
  prLinkage?: MissionPRLinkageSnapshot;
  metadata: Record<string, unknown>;
};
export type MissionBurnRecord = {
  id: string;
  label: string;
  amount: number;
  unit: string;
  recordedAt: string;
};
export type MissionTakeoverRecord = {
  id: string;
  projectSlug: string;
  missionId?: string;
  sourceRunId?: string;
  takeoverRunId?: string;
  status: string;
  reason: string;
  createdAt: string;
  updatedAt: string;
  metadata: Record<string, unknown>;
};
export type MissionPRLinkageSnapshot = {
  schemaVersion?: number;
  repository: string;
  prNumberOrId: string;
  url: string;
  state: string;
  mergeCommitSha?: string;
  mergedAt?: string;
  closedAt?: string;
};
export type MissionFreshness = 'fresh' | 'stale' | 'unknown';
export type MissionHealthStatus = 'healthy' | 'degraded' | 'stalled' | 'failed' | 'unknown';
export type MissionHealthSnapshot = {
  status: MissionHealthStatus;
  detail: string;
  checkedAt: string;
  lastActivityAt: string;
  activePacketCount: number;
  failedResultCount: number;
};
export type MissionHistoryEntry = {
  id: string;
  kind: string;
  status: string;
  summary: string;
  occurredAt: string;
  metadata: Record<string, unknown>;
};
export type MissionHealthResult = {
  missionId: string;
  health: MissionHealthSnapshot;
  history: MissionHistoryEntry[];
};
export type MissionRecord = {
  id: string;
  title: string;
  state: string;
  updatedAt: string;
  laneCount: number;
  projectSlug?: string;
  summary?: string;
  recommendation?: string;
  createdAt?: string;
  approval?: MissionApprovalSnapshot;
  packets?: MissionPacketSnapshot[];
  results?: MissionResultSnapshot[];
  burnRecords?: MissionBurnRecord[];
  takeoverHistory?: MissionTakeoverRecord[];
  prLinkage?: MissionPRLinkageSnapshot;
  metadata?: Record<string, unknown>;
  /** Derived locally from updatedAt; the daemon does not expose a health RPC. */
  freshness?: MissionFreshness;
};
export type MissionListResult = {
  missions: MissionRecord[];
  pendingApprovals: PendingApproval[];
};
export type MissionDetail = MissionRecord;
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
  cloudSyncEnabled?: boolean;
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
export type ProjectStatus = 'healthy' | 'needs_attention' | 'stale' | 'onboarding' | 'paused' | 'unknown';
export type ProjectCadence = 'daily' | 'weekly' | 'ad_hoc' | 'unknown';
export type ProjectAutomationMode = 'manual' | 'suggested' | 'scheduled' | 'unknown';
export type ProjectFreshness = 'fresh' | 'aging' | 'stale' | 'provisional' | 'missing' | 'unknown';
export type ProjectIngestionSource = 'manual' | 'app_activity' | 'unknown';

/**
 * The daemon-owned controller project snapshot. Unlike the legacy ProjectEntry
 * shape, this never treats a display title or filesystem path as identity.
 */
export type ProjectRecord = {
  id: string;
  projectSlug: string;
  displayName: string;
  summary: string;
  status: ProjectStatus;
  preferredCadence: ProjectCadence;
  aliases: string[];
  automationMode: ProjectAutomationMode;
  reviewModelID?: string;
  scheduleHourLocal?: number;
  scheduleWeekdayLocal?: number;
  freshness: ProjectFreshness;
  latestDailyReviewAt?: string;
  latestWeeklyReviewAt?: string;
  nextScheduledReviewAt?: string;
  pendingQuestionCount: number;
  openFollowupCount: number;
  activeMissionCount: number;
  activeMissionID?: string;
  needsOperatorAttention: boolean;
  ingestionSource: ProjectIngestionSource;
  metadata: Record<string, unknown>;
};

/** Full snapshot required by daemon.controller.project.upsert. */
export type ProjectUpsertInput = ProjectRecord;

export type ProjectDeleteResult = {
  projectSlug: string;
  deleted: boolean;
};

export type ProjectReassignResult = {
  sourceProjectSlug: string;
  targetProjectSlug: string;
  updatedReferenceCount: number;
};

/** Recent daemon-controller events scoped to one canonical project slug. */
export type ProjectHistoryEvent = {
  id: string;
  projectSlug: string;
  eventType: string;
  summary: string;
  detail?: string;
  recordedAt: string;
  sequence: number;
  isReplay: boolean;
};

/**
 * Compatibility envelope for existing mission filters. Live controller rows
 * carry the canonical record; path is intentionally empty because the
 * controller contract does not claim a filesystem path.
 */
export type ProjectEntry = {
  id: string;
  name: string;
  path: string;
  scope: string;
  projectSlug?: string;
  record?: ProjectRecord;
};
export type MemoryBoundary = { id: string; scope: string; label: string; detail: string };
export type MemoryReviewStatus = 'pending' | 'approved' | 'rejected' | 'forgotten';
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

export type DatabaseSnapshotResult = {
  traceID: string;
  snapshotPath: string;
  byteCount: number;
  sha256: string;
  schemaVersion: number;
  databaseEncrypted: boolean;
  integrityCheck: string;
  createdAt?: string;
  restoredAt?: string;
};
export type DatabaseRecoveryBundleExportRequest = {
  destinationPath: string;
  passphrase: string;
};
export type DatabaseRecoveryBundleExportResult = {
  destinationPath: string;
  byteCount: number;
  formatVersion: number;
};
export type DatabaseRecoveryBundleImportRequest = {
  sourcePath: string;
  passphrase: string;
};
export type DatabaseRecoveryPhase =
  | 'ready'
  | 'database_missing'
  | 'cipher_unavailable'
  | 'database_not_encrypted'
  | 'key_unavailable'
  | 'integrity_failed'
  | 'awaiting_database_verification'
  | 'unavailable';
export type DatabaseRecoveryAction =
  | 'none'
  | 'export_recovery_bundle'
  | 'import_recovery_bundle'
  | 'restore_encrypted_snapshot'
  | 'unlock_secret_store'
  | 'restart_daemon';
export type DatabaseRecoveryStatusResult = {
  phase: DatabaseRecoveryPhase;
  code: string;
  message: string;
  recommendedAction: DatabaseRecoveryAction;
  canExport: boolean;
  canImport: boolean;
  databasePresent: boolean;
  databaseIntegrityVerified: boolean;
  restartRequired: boolean;
};
export type DatabaseRecoveryBundleImportResult = {
  sourcePath: string;
  stored: boolean;
  candidateKeyVerified: boolean;
  databaseIntegrityVerified: boolean;
  phase: DatabaseRecoveryPhase;
  recommendedAction: DatabaseRecoveryAction;
  message: string;
  restartRequired: boolean;
};

export type DatabaseCodeDegradation = {
  code: string;
  message: string;
  staleCandidateCount: number;
  totalCandidateCount: number;
  indexAgeSeconds?: number;
  reindexHint?: string;
};

export type DatabaseCodeTrustSignal = {
  untrustedContentWrapped: boolean;
  sourceTool: string;
  wrappedCount: number;
  warning: string;
};

export type DatabaseCodeSearchHit = {
  chunkID: string;
  filePath: string;
  snippet: string;
  rank?: number;
  rankFeatures?: Record<string, number>;
  blobSHA?: string;
  contentHash?: string;
};

export type DatabaseCodeSearchResult = {
  traceID: string;
  projectID: string;
  status: string;
  hits: DatabaseCodeSearchHit[];
  semanticAvailable: boolean;
  degradation?: DatabaseCodeDegradation;
  trustSignal: DatabaseCodeTrustSignal;
};

export type DatabaseCodeContextPackResult = {
  traceID: string;
  projectID: string;
  status: string;
  context: string;
  hits: DatabaseCodeSearchHit[];
  truncated: boolean;
  semanticAvailable: boolean;
  degradation?: DatabaseCodeDegradation;
  trustSignal: DatabaseCodeTrustSignal;
};

export type DatabaseCodeSearchRequest = {
  query: string;
  projectPath?: string;
  limit?: number;
};

export type DatabaseCodeContextPackRequest = {
  query: string;
  projectPath?: string;
  limit?: number;
  maxBytes?: number;
};

export const DATABASE_CODE_MAX_RESULTS = 50;
export const DATABASE_CODE_DEFAULT_RESULTS = 20;
export const DATABASE_CODE_MAX_CONTEXT_BYTES = 24_000;

// ─────────────────────────── P08: account ─────────────────────────────────

export type AccountStatus = {
  state?: 'signed-out' | 'authorizing' | 'awaiting-device-approval' | 'active' | 'unavailable';
  signedIn: boolean;
  identityLabel?: string;
  trustClass: 'linux-lower-trust';
  syncState: 'local-only' | 'paused' | 'active';
  lastSyncAt?: string;
  authorizationOperationID?: string;
  authorizationExpiresAt?: string;
  deviceApprovalRequired?: boolean;
  installationDeviceID?: string;
  installationSafetyFingerprint?: string;
  detail?: string;
};
export type AccountSignInOperation = {
  operationID: string;
  expiresAt: string;
};

export const ACCOUNT_CLOUD_DATA_DELETION_CONFIRMATION = 'DELETE MY ACCOUNT';
export type AccountCloudDataDeletionResult = {
  ok: boolean;
  cloudDataDeleted: boolean;
  retryRequired: boolean;
  deletedDocuments: number;
  destroyedSecrets: number;
  failedSecretDestroys: number;
  deletedStoragePrefixes: number;
  failedStorageDeletes: number;
  deletedAuthUser: boolean;
  authUserAlreadyMissing: boolean;
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
  packageChannel: 'deb' | 'rpm' | 'arch' | 'appimage' | 'unknown';
  package?: {
    channel: 'deb' | 'rpm' | 'arch' | 'appimage' | 'unknown';
    manager: string;
    evidence: string;
  };
  runtime?: {
    os: string;
    architecture: string;
    kernel?: string;
    sessionType?: string;
    desktop?: string;
    displayServer?: string;
  };
  /** Legacy fixture field. Live update truth comes from updateStatus(). */
  updateCheck?: string;
};
export type LinuxUpdateArtifact = {
  type: 'appimage' | 'arch' | 'deb' | 'rpm' | 'daemon';
  architecture: 'aarch64' | 'x86_64';
  url: string;
  sha256: string;
  size: number;
  signatureUrl: string;
};
export type LinuxUpdateAction = {
  id: 'install' | 'rollback' | 'restart';
  label: string;
  instruction: string;
  command?: string;
  available: boolean;
  requiresConfirmation: boolean;
};
export type LinuxUpdateInstructions = {
  packageManager: 'apt' | 'dnf' | 'pacman' | 'appimage' | 'unknown';
  install: LinuxUpdateAction;
  rollback: LinuxUpdateAction;
  restart: LinuxUpdateAction;
};
export type LinuxUpdateChannelInfo = {
  id: 'deb' | 'rpm' | 'arch' | 'appimage' | 'unknown';
  label: string;
  owner: string;
  installMode: 'package-manager-guided' | 'artifact-replacement-guided' | 'unavailable';
  automaticInstall: boolean;
  rollbackMode: string;
  explanation: string;
};
export type LinuxUpdateCompatibility = {
  state: 'aligned' | 'mismatch' | 'unknown';
  shellVersion: string;
  daemonVersion?: string;
  reason?: string;
};
export type LinuxUpdateStatus = {
  state: 'current' | 'available' | 'unavailable' | 'invalid';
  currentVersion: string;
  latestVersion?: string;
  channel?: 'stable' | 'prerelease' | 'nightly';
  publishedAt?: string;
  notes?: string;
  artifact?: LinuxUpdateArtifact;
  instructions?: LinuxUpdateInstructions;
  packageChannel?: LinuxUpdateChannelInfo['id'];
  channelInfo?: LinuxUpdateChannelInfo;
  signatureState?: 'verified' | 'rejected' | 'unknown';
  feedFreshness?: 'fresh' | 'stale' | 'future' | 'unknown';
  feedAgeSeconds?: number;
  checkedAtUnixSeconds?: number;
  compatibility?: LinuxUpdateCompatibility;
  reason?: string;
};
export type DiagnosticsExportPreview = {
  schemaVersion: 1;
  byteCount: number;
  fileMode: '0600';
  included: string[];
  excluded: string[];
};
export type DiagnosticsExport = { path: string; preview?: DiagnosticsExportPreview };

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
export type NativeNotificationRoute =
  | 'overview'
  | 'chat'
  | 'insights'
  | 'settings'
  | 'activity'
  | 'account'
  | 'updates'
  | 'support';
export type NativeNotificationRequest = {
  id?: string;
  title: string;
  body: string;
  route: NativeNotificationRoute;
  action: 'open' | 'reply';
  urgency?: 'low' | 'normal' | 'critical';
};
export type NativeNotificationCapabilities = {
  available: boolean;
  actions: boolean;
  persistence: boolean;
  body: boolean;
  bodyMarkup: boolean;
  serverCapabilities: string[];
  degradedReason?: string;
};
export type NativeNotificationResult = {
  notificationId: string;
  delivered: boolean;
  actionsAttached: boolean;
  degradedReason?: string;
};
export type NativeNotificationActionEvent = {
  notificationId: string;
  route: NativeNotificationRoute;
  action: 'open' | 'reply';
  payload?: Record<string, unknown>;
};
export type NativeShortcutStatus = {
  available: boolean;
  registered: boolean;
  backend?: 'x11' | 'wayland' | 'unknown';
  shortcuts: string[];
  bindings?: NativeShortcutBindingStatus[];
  degradedReason?: string;
};
export type NativeShortcutBindingStatus = {
  id: string;
  shortcut: string;
  state: 'registered' | 'degraded' | 'unavailable';
  degradedReason?: string;
};
export type LinuxLaunchAtLoginStatus = {
  enabled: boolean;
  userOverride: boolean;
  source: 'user' | 'packaged' | 'unavailable';
  path: string;
  detail?: string;
};

export type PetCompanionStatus = {
  state: 'available' | 'degraded' | 'unavailable';
  compositor: string;
  sessionType?: string;
  desktop?: string;
  overlaySupported: boolean;
  clickThroughSupported: boolean;
  windowContract: string;
  reason: string;
  source: string;
};

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
  /** Shell-local renderer capability; daemon capture may still be available. */
  viewerCapability?: MercuryViewerCapability;
  reason?: string;
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
export type MercuryViewerCapabilityStatus =
  | 'available'
  | 'built_without_gstreamer'
  | 'gstreamer_backend_unavailable'
  | 'gstreamer_vp9_decoder_missing'
  | 'gstreamer_video_sink_missing'
  | 'unknown';
export type MercuryViewerCapability = {
  available: boolean;
  renderer: 'media-gst' | 'stub' | 'unknown';
  featureEnabled: boolean;
  canDecodeVp9: boolean;
  hasVideoSink: boolean;
  status: MercuryViewerCapabilityStatus;
  reason?: string;
  installHint?: string;
};
export type MercuryFileTransferDirection = 'inbound' | 'outbound';
export type MercuryFileTransferPhase =
  | 'pendingAccept'
  | 'downloading'
  | 'sending'
  | 'offered'
  | 'completed'
  | 'declined'
  | 'failed';
export type MercuryFileTransferErrorCode =
  | 'capabilityAbsent'
  | 'invalidRequest'
  | 'transferNotFound'
  | 'localFileMissing'
  | 'noControlRoute'
  | 'publishFailed'
  | 'fetchFailed'
  | 'ioFailed'
  | 'peerRejected';
export type MercuryFileTransferProgress = {
  bytesTransferred: number;
  bytesTotal: number;
  fraction: number;
};
export type MercuryFilePeer = {
  id: string;
  name: string;
  isOnline: boolean;
  lastSeenAt: string;
  capabilities: string[];
};
export type MercuryFileTransfer = {
  transferID: string;
  manifestID: string;
  direction: MercuryFileTransferDirection;
  phase: MercuryFileTransferPhase;
  filename: string;
  mime: string;
  size: number;
  peer?: MercuryFilePeer;
  progress: MercuryFileTransferProgress;
  localPath?: string;
  errorCode?: MercuryFileTransferErrorCode;
  detail?: string;
  createdAt: string;
  updatedAt: string;
  completedAt?: string;
};
export type MercuryFileOfferListResponse = {
  capabilityAvailable: boolean;
  downloadDirectory?: string;
  transfers: MercuryFileTransfer[];
  detail?: string;
};
export type MercuryFileTransferActionRequest = {
  transferID?: string;
  manifestID?: string;
};
export type MercuryFileTransferSendRequest = {
  path: string;
  peerID?: string;
};
export type MercuryFileTransferActionResponse = {
  accepted: boolean;
  transfer?: MercuryFileTransfer;
  errorCode?: MercuryFileTransferErrorCode;
  detail?: string;
};
export type ComputerUsePanicSource =
  | 'hotkey'
  | 'phone_gesture'
  | 'mac_lock'
  | 'remote_config'
  | 'accessibility_revoked'
  | 'stalled'
  | 'revoked';
export type ComputerUsePanicHaltResult = {
  sessionId: string;
  endedAt: string;
  auditHeadHashHex: string;
  source: ComputerUsePanicSource;
  raw?: RawJsonValue;
};

export type ComputerUseSessionAuthorityState =
  | 'available'
  | 'waiting_phone'
  | 'waiting_local_owner'
  | 'authorized'
  | 'expired'
  | 'rejected'
  | 'unavailable';

export type ComputerUseSessionAuthorityStatus = {
  state: ComputerUseSessionAuthorityState;
  expiresAt?: number;
  detail?: string;
  sessionId?: string;
};

/**
 * Defaults from BurnBarComputerUseContracts.swift. The renderer-facing Tauri
 * boundary is lower-camel (`clientId`, `runId`, `callId`); the Rust command
 * translates these to the Swift Codable `clientID`/`runID`/`callID` wire keys
 * before calling the daemon. Keeping that distinction explicit prevents the
 * webview from accidentally sending Swift keys to a serde command.
 */
export const COMPUTER_USE_SESSION_DEFAULTS = {
  scopeRuleIds: [] as string[],
  phoneViewerNodeId: null as string | null,
  macHostNodeId: null as string | null,
  actionCap: 50,
  sessionTimeoutSeconds: 1_800
} as const;

export type ComputerUseSessionStartRequest = {
  mode: 'browser';
  trustMode: 'manual' | 'step' | 'trusted';
  scopeRuleIds: string[];
  phoneViewerNodeId: string | null;
  macHostNodeId: string | null;
  actionCap: number;
  sessionTimeoutSeconds: number;
  clientId: 'linux-shell';
  runId: string;
  runCallId: string;
  runGeneration: number;
  desktopOwnerAuthorizationRequest: {
    method: 'linux_desktop_owner';
  };
};

export type ComputerUseBrowserTool =
  | 'browser_goto'
  | 'browser_screenshot'
  | 'browser_click'
  | 'browser_fill';

export type ComputerUseBrowserActionArguments = {
  selector?: string;
  text?: string;
  url?: string;
  key?: string;
  value?: string;
  positionX?: number;
  positionY?: number;
  timeoutMillis?: number;
};

/** Tauri command shape; Rust emits Swift's uppercase-ID Codable keys. */
export type ComputerUseInvokeRequest = {
  sessionId: string;
  invocation: {
    callId: string;
    runId: string;
    tool: ComputerUseBrowserTool;
    arguments: ComputerUseBrowserActionArguments;
    requestedBy: 'linux-shell';
    /** Foundation reference-date seconds; Rust fills this only for legacy callers. */
    requestedAt: number;
  };
};

export type ComputerUseInvokeResponseStatus =
  | 'executed'
  | 'denied'
  | 'awaiting_approval'
  | 'error';

export type ComputerUseInvokeResponse = {
  sessionId: string;
  callID: string;
  status: ComputerUseInvokeResponseStatus;
  approvalId?: string;
  denyReason?: string;
  auditEntryIndex?: number;
  auditHeadHashHex?: string;
  result?: RawJsonValue;
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

/** Closed operation set for the existing Linux SmartHub/device CLI contract. */
export type SmartHubOperation =
  | 'discover'
  | 'status'
  | 'test'
  | 'cast'
  | 'cast_status'
  | 'homeassistant_status'
  | 'device'
  | 'pixel_clock_control'
  | 'parity';
export type SmartHubCommandOptions = {
  requestId?: string;
};
export type SmartHubDiscoveryResult = {
  adapter: string;
  serviceType: string;
  instances: string[];
  rawTranscript: string;
  /** `ok` is a completed scan; other values explain a bounded failure. */
  status?: string;
  blocker?: string;
};
export type SmartHubStatusResult = {
  adapter: string;
  status: string;
  blocker?: string;
  details: Record<string, string>;
};
export type SmartHubCommandResult =
  | { operation: 'discover'; payload: SmartHubDiscoveryResult[] }
  | {
      operation: 'status' | 'test' | 'cast' | 'cast_status' | 'homeassistant_status' | 'device' | 'pixel_clock_control';
      payload: SmartHubStatusResult;
    }
  | { operation: 'parity'; payload: IntegrationsStatus };

// ─────────────────────────── P29: text expansion ──────────────────────────
// These wire types mirror OpenBurnBarCore's daemon-owned snapshot contracts.
// Linux only accepts the in-app surface; no global keyboard hook is installed.
export type TextExpansionMode = 'static' | 'llm_rewrite';
export type TextExpansionSurface = 'in_app_thread' | 'mac_global' | 'ios_keyboard' | 'android_ime';
export type TextExpansionScope = {
  surfaces: TextExpansionSurface[];
  bundleIdentifiers: string[];
  threadIDs: string[];
};
export type TextExpansionWireSnippet = {
  id: string;
  title: string;
  trigger: string;
  body: string;
  mode: TextExpansionMode;
  isEnabled: boolean;
  scope: TextExpansionScope;
  revision: number;
  createdAt: string;
  updatedAt: string;
  deletedAt?: string | null;
  syncedAt?: string | null;
  sourceDeviceID?: string | null;
};
export type TextExpansionNativeStatus = {
  status: 'available' | 'degraded' | 'blocked' | string;
  backend?: string | null;
  backendPath?: string | null;
  sessionType: 'wayland' | 'x11' | 'unknown' | string;
  registration: string;
  supportsExternalExpansion: boolean;
  secureFieldPolicy: string;
  noGlobalCapture: boolean;
  detail: string;
  checkedAt: string;
};
export type TextExpansionSnapshot = {
  schemaVersion: number;
  exportedAt: string;
  snippets: TextExpansionWireSnippet[];
  consent?: TextExpansionConsent | null;
  nativeStatus?: TextExpansionNativeStatus | null;
};
export type TextExpansionConsent = {
  inAppOnly: boolean;
  acknowledgedAt: string;
  declinedGlobalCapture: boolean;
};
export type TextExpansionEngineRuntimeStatus = {
  state: string;
  engineID?: string | null;
  executablePath?: string | null;
  registration: string;
  supportsExternalExpansion: boolean;
  detail: string;
  checkedAt: string;
};
export type TextExpansionEngineStartRequest = {
  consentAcknowledged: boolean;
  timeoutMillis?: number;
};
export type TextExpansionEngineStopRequest = {
  timeoutMillis?: number;
};
export type TextExpansionSecureFieldContext = {
  inspectable: boolean;
  isSecureField?: boolean | null;
  applicationID?: string | null;
  role?: string | null;
  inputPurpose?: string | null;
};
export type TextExpansionEngineExpandRequest = {
  trigger: string;
  context: TextExpansionSecureFieldContext;
  timeoutMillis?: number;
  requestID?: string;
};
export type TextExpansionEngineExpandResponse = {
  expanded: boolean;
  replacement?: string | null;
};

// ─────────────────────────── P40: local privacy ───────────────────────────
// The daemon exposes only allowlisted local stores. Absolute paths and store
// contents never cross the Tauri boundary.
export type LinuxPrivacyStoreID = 'proxy_route_log' | 'text_expansion_store';
export type LinuxPrivacyStoreState = 'absent' | 'ready' | 'blocked';
export type LinuxPrivacyStoreInventory = {
  store: LinuxPrivacyStoreID;
  state: LinuxPrivacyStoreState;
  bytes: number;
  reason: string;
};
export type LinuxPrivacyInventory = {
  stores: LinuxPrivacyStoreInventory[];
  generatedAt: string;
};
export type LinuxPrivacyDeletionPreview = {
  token: string;
  stores: LinuxPrivacyStoreID[];
  entries: LinuxPrivacyStoreInventory[];
  expiresAt: string;
  confirmationPhrase: string;
};
export type LinuxPrivacyDeletionRequest = {
  token: string;
  stores: LinuxPrivacyStoreID[];
  confirmation: string;
};
export type LinuxPrivacyDeletionResult = {
  stores: LinuxPrivacyStoreID[];
  deleted: LinuxPrivacyStoreID[];
  alreadyAbsent: LinuxPrivacyStoreID[];
  bytesRemoved: number;
  idempotent: boolean;
};
export type LinuxPrivacyExportRequest = {
  stores: LinuxPrivacyStoreID[];
  destinationPath: string;
  passphrase: string;
};
export type LinuxPrivacyExportResult = {
  stores: LinuxPrivacyStoreID[];
  destinationPath: string;
  byteCount: number;
  formatVersion: number;
};
export type LinuxPrivacyRetentionPolicyState = 'defaults' | 'configured' | 'blocked';
export type LinuxPrivacyRetentionRule = {
  store: LinuxPrivacyStoreID;
  maxAgeSeconds: number;
  maxBytes: number;
};
export type LinuxPrivacyRetentionStoreStatus = {
  store: LinuxPrivacyStoreID;
  state: LinuxPrivacyStoreState;
  bytes: number;
  ageSeconds?: number;
  maxAgeSeconds: number;
  maxBytes: number;
  wouldPurge: boolean;
  reason: string;
};
export type LinuxPrivacyRetentionStatus = {
  policyState: LinuxPrivacyRetentionPolicyState;
  rules: LinuxPrivacyRetentionRule[];
  stores: LinuxPrivacyRetentionStoreStatus[];
  evaluatedAt: string;
};
export type LinuxPrivacyRetentionApplyRequest = {
  rules: LinuxPrivacyRetentionRule[];
  confirmation: string;
};
export type LinuxPrivacyRetentionApplyResult = {
  status: LinuxPrivacyRetentionStatus;
  removedBytes: number;
  removedEntries: number;
};

export type GatewayProxyMessage = {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string;
  /** Opaque daemon-owned refs; raw file bytes never enter the gateway request. */
  attachments?: GatewayAttachmentReference[];
};

export type GatewayAttachmentReference = {
  attachmentId: string;
};

export const CHAT_ATTACHMENT_MAX_BYTES = 10 * 1024 * 1024;
export type ChatAttachmentUploadRequest = {
  fileName: string;
  mimeType: string;
  contentBase64: string;
};
export type ChatAttachmentUploadResult = {
  attachmentId: string;
  fileName: string;
  mimeType: string;
  byteSize: number;
  sha256: string;
};

export type GatewayAttachmentCapabilityState = 'supported' | 'unsupported' | 'unknown';
export type GatewayAttachmentCapability = {
  mimeType: string;
  state: GatewayAttachmentCapabilityState;
  reason: string;
  maxBytes?: number;
};

export type GatewayProxyRequest = {
  requestId: string;
  model: string;
  messages: GatewayProxyMessage[];
};

export type DaemonSubscriptionTopic = 'data' | 'health' | 'run';
export type DaemonSubscriptionStartRequest = {
  topic: DaemonSubscriptionTopic;
  run_id?: string;
  requested_subscription_id?: string;
  client_id?: string;
};
export type DaemonSubscriptionResumeRequest = {
  subscription_id: string;
  topic: DaemonSubscriptionTopic;
  after_seq: number;
  run_id?: string;
  client_id?: string;
};
export type DaemonSubscriptionStopRequest = {
  subscription_id: string;
  client_id?: string;
};
export type DaemonSubscriptionEvent = {
  seq: number;
  kind: string;
  snapshot: Record<string, string>;
  terminal: boolean;
};
export type DaemonSubscriptionResponse = {
  subscriptionId: string;
  topic: DaemonSubscriptionTopic;
  seq: number;
  cursor: string;
  firstSnapshot: boolean;
  events: DaemonSubscriptionEvent[];
  degradedFallback: boolean;
  degradationReason?: string;
  backpressure: string;
  disconnectDetected: boolean;
  recoveredAfterRestart: boolean;
  terminalStateDelivered: boolean;
};
export type DaemonSubscriptionStopResponse = {
  subscriptionId: string;
  stopped: boolean;
  lastSeq: number;
};

// ─────────────────────────── Bridge contract ──────────────────────────────

export interface LinuxShellBridge {
  daemonHealth(): Promise<DaemonHealth>;
  runtimeCapabilities(): Promise<RuntimeCapabilityManifest>;
  gatewayProbe(): Promise<boolean>;
  /** Optional on older packaged shells; binary/PDF sends fail closed when absent. */
  gatewayAttachmentCapability?(model: string, mimeType: string): Promise<GatewayAttachmentCapability>;
  chatAttachmentUpload(request: ChatAttachmentUploadRequest): Promise<ChatAttachmentUploadResult>;
  gatewayChatStream(request: GatewayProxyRequest, onChunk: (chunk: string) => void): Promise<void>;
  gatewayChatCancel(requestId: string): Promise<void>;
  openDashboard(): Promise<void>;
  /** Consumed only by startup bootstrap; never drains later instance messages. */
  initialDeepLinkRoute?(): Promise<string | null>;
  /** Drains routes forwarded by later launches after the renderer listener is ready. */
  forwardedDeepLinkRoute?(): Promise<string | null>;
  /** Drains native notification actions received before the renderer listener was ready. */
  initialNotificationActions?(): Promise<NativeNotificationActionEvent[]>;
  quitApp(): Promise<void>;
  trayDegraded(): Promise<boolean>;
  measurePerfOperation(
    name: string
  ): Promise<{ name: string; ms: number; source: string; ok: boolean; detail?: string }>;
  onboardingSnapshot(): Promise<LinuxOnboardingSnapshot>;
  onboardingAction(request: LinuxOnboardingActionRequest): Promise<LinuxOnboardingSnapshot>;
  onboardingReset(): Promise<LinuxOnboardingSnapshot>;
  subscriptionStart(request: DaemonSubscriptionStartRequest): Promise<DaemonSubscriptionResponse>;
  subscriptionResume(request: DaemonSubscriptionResumeRequest): Promise<DaemonSubscriptionResponse>;
  subscriptionStop(request: DaemonSubscriptionStopRequest): Promise<DaemonSubscriptionStopResponse>;

  // P01–P11 lane extensions — each maps the raw daemon `result` JSON to a typed shape.
  usageSummary(): Promise<UsageSummary>;
  providerCatalog(): Promise<ProviderCatalog>;
  sessionList(): Promise<SessionListResult>;
  sessionSearch(query: string): Promise<SessionListResult>;
  /** Optional on older packaged shells; backed by an explicit full-history RPC. */
  sessionHistory?(): Promise<SessionHistoryResult>;
  /** Optional on older packaged shells; backed by persisted conversation rows. */
  sessionReplay?(sessionID: string): Promise<SessionReplayResult>;
  /** Optional on older packaged shells; launches native or explicit handoff resume. */
  sessionResume?(sessionID: string): Promise<SessionReplayResult>;
  chatThreadList(query?: string, limit?: number): Promise<ChatThreadListResult>;
  chatThreadGet(
    threadID: string,
    maxMessages?: number,
    before?: ChatMessageCursor
  ): Promise<ChatThreadGetResult>;
  chatMessageAppend(request: ChatMessageAppendRequest): Promise<ChatMessageAppendResult>;
  usageInsights(): Promise<UsageInsights>;
  missionList(): Promise<MissionListResult>;
  missionGet(id: string): Promise<MissionDetail | null>;
  missionHealth?(id: string): Promise<MissionHealthResult>;
  missionApprovalDecision(id: string, decision: ApprovalDecision): Promise<void>;
  missionCancel(id: string, note?: string): Promise<MissionDetail | null>;
  missionCreate(input: MissionCreateInput): Promise<MissionListResult['missions'][number] | null>;
  configSnapshot(): Promise<ConfigSnapshot>;
  dbStatus(): Promise<DbStatus>;
  projectList(): Promise<ProjectEntry[]>;
  projectGet?(projectSlug: string): Promise<ProjectRecord | null>;
  projectUpsert?(project: ProjectUpsertInput): Promise<ProjectRecord | null>;
  projectDelete?(projectSlug: string): Promise<ProjectDeleteResult>;
  projectReassign?(sourceProjectSlug: string, targetProjectSlug: string): Promise<ProjectReassignResult>;
  /** Optional on older packaged shells; backed by daemon.controller.summary. */
  projectHistory?(projectSlug: string): Promise<ProjectHistoryEvent[]>;
  memoryBoundaries(): Promise<MemoryBoundary[]>;
  memoryReviewInbox(): Promise<MemoryReviewInbox>;
  memoryReviewDecision(id: string, decision: Exclude<MemoryReviewStatus, 'pending' | 'forgotten'>): Promise<void>;
  databaseWorkspaceStatus(projectPath?: string): Promise<DatabaseWorkspaceStatus>;
  databaseIndexProject(projectPath?: string): Promise<DatabaseIndexActionResult>;
  databaseWatchProject(projectPath?: string): Promise<DatabaseIndexActionResult>;
  /** Optional on older packaged shells; callers must surface unavailable state. */
  databaseSnapshot?(destinationPath: string, maxBytes?: number): Promise<DatabaseSnapshotResult>;
  /** Optional on older packaged shells; restores only validated encrypted snapshots. */
  databaseRestore?(snapshotPath: string, maxBytes?: number): Promise<DatabaseSnapshotResult>;
  /** Optional on older packaged shells; callers must fail closed when absent. */
  databaseRecoveryBundleStatus?(): Promise<DatabaseRecoveryStatusResult>;
  databaseRecoveryBundleExport?(
    request: DatabaseRecoveryBundleExportRequest
  ): Promise<DatabaseRecoveryBundleExportResult>;
  databaseRecoveryBundleImport?(
    request: DatabaseRecoveryBundleImportRequest
  ): Promise<DatabaseRecoveryBundleImportResult>;
  /** Optional on older packaged shells; callers must fail closed when absent. */
  databaseCodeSearch?(request: DatabaseCodeSearchRequest): Promise<DatabaseCodeSearchResult>;
  /** Optional on older packaged shells; callers must fail closed when absent. */
  databaseCodeContextPack?(request: DatabaseCodeContextPackRequest): Promise<DatabaseCodeContextPackResult>;
  accountStatus(): Promise<AccountStatus>;
  accountBeginSignIn(): Promise<AccountSignInOperation>;
  accountCancelSignIn(operationID: string): Promise<AccountStatus>;
  accountRotateIdentity(): Promise<AccountStatus>;
  accountSignOut(): Promise<AccountStatus>;
  /** Optional on older packaged shells; daemon-owned and fail-closed. */
  accountDeleteCloudData?(confirmation: string): Promise<AccountCloudDataDeletionResult>;
  membershipStatus?(): Promise<MembershipStatus>;
  membershipCheckoutUrl?(): Promise<string>;
  openExternalUrl?(url: string): Promise<void>;
  openUpdateUrl?(url: string): Promise<void>;
  membershipRestore?(): Promise<void>;
  appVersionInfo(): Promise<AppVersionInfo>;
  updateStatus?(): Promise<LinuxUpdateStatus>;
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
  linuxPrivacyInventory?(): Promise<LinuxPrivacyInventory>;
  linuxPrivacyDeletionPreview?(stores: LinuxPrivacyStoreID[]): Promise<LinuxPrivacyDeletionPreview>;
  linuxPrivacyDeletionExecute?(request: LinuxPrivacyDeletionRequest): Promise<LinuxPrivacyDeletionResult>;
  linuxPrivacyExport?(request: LinuxPrivacyExportRequest): Promise<LinuxPrivacyExportResult>;
  linuxPrivacyRetentionStatus?(): Promise<LinuxPrivacyRetentionStatus>;
  linuxPrivacyRetentionApply?(request: LinuxPrivacyRetentionApplyRequest): Promise<LinuxPrivacyRetentionApplyResult>;
  notificationConfigGet?(): Promise<NotificationConfig>;
  notificationConfigUpdate?(config: NotificationConfig): Promise<NotificationConfig>;
  notificationHealth?(): Promise<NotificationHealth>;
  notificationCommand?(command: string, args?: string[]): Promise<NotificationCommandResult>;
  nativeNotificationCapabilities?(): Promise<NativeNotificationCapabilities>;
  nativeNotificationShow?(request: NativeNotificationRequest): Promise<NativeNotificationResult>;
  nativeShortcutStatus?(): Promise<NativeShortcutStatus>;
  /** Optional on older packaged shells; writes only the fixed XDG desktop entry. */
  launchAtLoginStatus?(): Promise<LinuxLaunchAtLoginStatus>;
  launchAtLoginSet?(enabled: boolean): Promise<LinuxLaunchAtLoginStatus>;
  /** Optional on older packaged shells; native X11-only companion contract. */
  petCompanionStatus?(): Promise<PetCompanionStatus>;
  textExpansionList?(): Promise<TextExpansionSnapshot>;
  textExpansionUpsert?(snippet: TextExpansionWireSnippet): Promise<TextExpansionWireSnippet>;
  textExpansionDelete?(id: string): Promise<TextExpansionSnapshot>;
  textExpansionConsentUpdate?(consent: Omit<TextExpansionConsent, 'acknowledgedAt'>): Promise<TextExpansionConsent>;
  textExpansionEngineStatus?(): Promise<TextExpansionEngineRuntimeStatus>;
  textExpansionEngineStart?(request: TextExpansionEngineStartRequest): Promise<TextExpansionEngineRuntimeStatus>;
  textExpansionEngineStop?(request?: TextExpansionEngineStopRequest): Promise<TextExpansionEngineRuntimeStatus>;
  textExpansionEngineExpand?(request: TextExpansionEngineExpandRequest): Promise<TextExpansionEngineExpandResponse>;
  toolApprovalRespond?(
    approvalId: string,
    decision: 'approve' | 'reject' | 'cancel',
    note?: string
  ): Promise<void>;
  memorySetStatus?(
    action: 'approve' | 'quarantine' | 'reject' | 'audit' | 'remember' | 'forget',
    payload: Record<string, unknown>
  ): Promise<unknown>;
  computerUseSessionAuthorityStatus?(): Promise<ComputerUseSessionAuthorityStatus>;
  computerUseSessionStart?(
    params: ComputerUseSessionStartRequest
  ): Promise<ComputerUseSessionAuthorityStatus>;
  computerUseInvoke?(params: ComputerUseInvokeRequest): Promise<ComputerUseInvokeResponse>;
  computerUseApprovalPending?(params?: Record<string, unknown>): Promise<unknown>;
  computerUseApprovalRespond?(params: Record<string, unknown>): Promise<unknown>;
  computerUseAuditExport?(params?: Record<string, unknown>): Promise<unknown>;
  sessionEnv(): Promise<SessionEnv>;
  mediaStatus(): Promise<MercuryMediaStatus>;
  mediaSessionState(): Promise<MercuryMediaSessionState>;
  mediaAcceptCall(requestId: string): Promise<MercuryMediaSessionState>;
  mediaDeclineCall(requestId: string): Promise<MercuryMediaSessionState>;
  mediaEndCall(): Promise<MercuryMediaSessionState>;
  mediaCapabilityGet(): Promise<MercuryMediaCapability>;
  mediaFileOfferList(): Promise<MercuryFileOfferListResponse>;
  mediaFileAccept(request: MercuryFileTransferActionRequest): Promise<MercuryFileTransferActionResponse>;
  mediaFileDecline(
    request: MercuryFileTransferActionRequest & { reason?: string }
  ): Promise<MercuryFileTransferActionResponse>;
  mediaFileSend(request: MercuryFileTransferSendRequest): Promise<MercuryFileTransferActionResponse>;
  computerUsePanicHalt(params?: {
    sessionId?: string;
    source?: ComputerUsePanicSource;
  }): Promise<ComputerUsePanicHaltResult>;
  integrationsStatus(): Promise<IntegrationsStatus>;
  smartHubCommand?(operation: SmartHubOperation, options?: SmartHubCommandOptions): Promise<SmartHubCommandResult>;
  smartHubCancel?(requestId: string): Promise<void>;
}
