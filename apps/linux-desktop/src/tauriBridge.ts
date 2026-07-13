import { Channel, invoke } from '@tauri-apps/api/core';
import type { DaemonHealth } from './daemonClient.js';
import {
  decodeRuntimeCapabilityManifest,
  type RuntimeCapabilityManifest
} from './runtimeCapabilities.js';
import { ENTITLEMENT_DOC_IDS, evaluateEntitlement } from '@openburnbar/entitlements';
import {
  decodeLinuxOnboardingSnapshot,
  type LinuxOnboardingActionRequest,
  type LinuxOnboardingSnapshot
} from './onboardingStore.js';

// ─────────────────────────── P01: usage summary ───────────────────────────

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
  id: 'daemon.usage.recent' | 'fixture.usage.insights';
  kind: 'daemon-method' | 'fixture';
  label: string;
};
export type InsightsQualitativeCapability = {
  state: 'available' | 'degraded' | 'unavailable';
  reason: string;
  method?: string;
};
export type UsageInsights = {
  weekly: WeeklyPoint[];
  providerMix: MixEntry[];
  modelMix: MixEntry[];
  cacheHitRatePct: number;
  /** Present when the daemon response carries a known source authority. */
  source?: UsageInsightsSource;
  /** Linux currently has no qualitative-analysis RPC; keep that posture typed. */
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
  packageChannel: 'deb' | 'rpm' | 'appimage' | 'unknown';
  package?: {
    channel: 'deb' | 'rpm' | 'appimage' | 'unknown';
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
  type: 'appimage' | 'deb' | 'rpm' | 'daemon';
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
  packageManager: 'apt' | 'dnf' | 'appimage' | 'unknown';
  install: LinuxUpdateAction;
  rollback: LinuxUpdateAction;
  restart: LinuxUpdateAction;
};
export type LinuxUpdateChannelInfo = {
  id: 'deb' | 'rpm' | 'appimage' | 'unknown';
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
  shortcuts: string[];
  degradedReason?: string;
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
  chatAttachmentUpload(request: ChatAttachmentUploadRequest): Promise<ChatAttachmentUploadResult>;
  gatewayChatStream(request: GatewayProxyRequest, onChunk: (chunk: string) => void): Promise<void>;
  gatewayChatCancel(requestId: string): Promise<void>;
  openDashboard(): Promise<void>;
  initialDeepLinkRoute?(): Promise<string | null>;
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
  memoryBoundaries(): Promise<MemoryBoundary[]>;
  memoryReviewInbox(): Promise<MemoryReviewInbox>;
  memoryReviewDecision(id: string, decision: Exclude<MemoryReviewStatus, 'pending'>): Promise<void>;
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
  notificationConfigGet?(): Promise<NotificationConfig>;
  notificationConfigUpdate?(config: NotificationConfig): Promise<NotificationConfig>;
  notificationHealth?(): Promise<NotificationHealth>;
  notificationCommand?(command: string, args?: string[]): Promise<NotificationCommandResult>;
  nativeNotificationCapabilities?(): Promise<NativeNotificationCapabilities>;
  nativeNotificationShow?(request: NativeNotificationRequest): Promise<NativeNotificationResult>;
  nativeShortcutStatus?(): Promise<NativeShortcutStatus>;
  textExpansionList?(): Promise<TextExpansionSnapshot>;
  textExpansionUpsert?(snippet: TextExpansionWireSnippet): Promise<TextExpansionWireSnippet>;
  textExpansionDelete?(id: string): Promise<TextExpansionSnapshot>;
  textExpansionConsentUpdate?(consent: Omit<TextExpansionConsent, 'acknowledgedAt'>): Promise<TextExpansionConsent>;
  toolApprovalRespond?(
    approvalId: string,
    decision: 'approve' | 'reject' | 'cancel',
    note?: string
  ): Promise<void>;
  memorySetStatus?(
    action: 'approve' | 'reject' | 'audit' | 'remember' | 'forget',
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

function obj(v: RawJsonValue): Record<string, RawJsonValue> {
  return v && typeof v === 'object' && !Array.isArray(v)
    ? v as Record<string, RawJsonValue>
    : {};
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

function requireObject(v: RawJsonValue, label: string): Record<string, RawJsonValue> {
  if (!v || typeof v !== 'object' || Array.isArray(v)) {
    throw new Error(`${label} must be an object.`);
  }
  return v as Record<string, RawJsonValue>;
}

function requireString(v: RawJsonValue, label: string): string {
  if (typeof v !== 'string' || v.length === 0) {
    throw new Error(`${label} must be a non-empty string.`);
  }
  return v;
}

function requireBoolean(v: RawJsonValue, label: string): boolean {
  if (typeof v !== 'boolean') throw new Error(`${label} must be a boolean.`);
  return v;
}

function optionalBoolean(v: RawJsonValue, label: string, fallback = false): boolean {
  if (v === undefined || v === null) return fallback;
  return requireBoolean(v, label);
}

function requireSequence(v: RawJsonValue, label: string): number {
  if (typeof v !== 'number' || !Number.isSafeInteger(v) || v < 0) {
    throw new Error(`${label} must be a non-negative safe integer.`);
  }
  return v;
}

function decodeSubscriptionTopic(v: RawJsonValue): DaemonSubscriptionTopic {
  if (v === 'data' || v === 'health' || v === 'run') return v;
  throw new Error('subscription.topic is unsupported.');
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

const PROVIDER_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/;
const MODEL_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$/;

function normalizedCatalogID(value: RawJsonValue, pattern: RegExp): string | null {
  const candidate = str(value).trim();
  if (!candidate || candidate.includes('\u0000') || /[\u0000-\u001f\u007f]/.test(candidate)) return null;
  return pattern.test(candidate) ? candidate : null;
}

function normalizedModelID(value: RawJsonValue): string | null {
  return normalizedCatalogID(value, MODEL_ID_PATTERN);
}

function modelIdentityMatches(
  model: Pick<ProviderCatalogModel, 'id' | 'aliases' | 'canonicalModelID'>,
  requested: string
): boolean {
  const normalized = requested.trim().toLowerCase();
  return [model.id, model.canonicalModelID ?? '', ...model.aliases]
    .some((value) => value.trim().toLowerCase() === normalized);
}

function normalizeProviderHealth(raw: string): ProviderHealthState {
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

function providerHealth(
  provider: RawJsonValue | undefined,
  catalogProvider: RawJsonValue | undefined
): ProviderHealthState {
  const configured = provider !== undefined;
  const enabledValue = pick(provider, 'isEnabled', 'enabled');
  if (configured && enabledValue !== undefined && !Boolean(enabledValue)) return 'unavailable';
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

function catalogModelCapabilities(raw: RawJsonValue): string[] {
  return arr(pick(raw, 'capabilities', 'features', 'capabilityClassIDs', 'capabilityClassIds'))
    .map((value) => str(value).trim())
    .filter(Boolean)
    .slice(0, 32);
}

function mapCatalogModel(
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

function failoverState(snapshot: RawJsonValue, provider: RawJsonValue | undefined, health: ProviderHealthState): ProviderFailoverState {
  const mode = str(pick(snapshot, 'routerMode'), 'providerFamilyFailover').trim() || 'providerFamilyFailover';
  const enabled = provider !== undefined && Boolean(pick(provider, 'isEnabled', 'enabled'));
  if (!enabled) return { mode, eligible: false, detail: 'Provider is disabled or not configured in the daemon.' };
  if (health === 'healthy') return { mode, eligible: true, detail: 'Verified credential route is eligible for provider-family failover.' };
  if (health === 'degraded') return { mode, eligible: false, detail: 'Provider is configured, but the daemon has not verified a healthy route.' };
  if (health === 'unavailable') return { mode, eligible: false, detail: 'No verified credential route is available.' };
  return { mode, eligible: false, detail: 'Route health is not available yet.' };
}

function mapQuotaBuckets(raw: RawJsonValue): QuotaBucket[] {
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
    const accountLabel = str(pick(provider, 'accountLabel', 'account')).trim() || str(pick(slots[0], 'label', 'name')).trim() || (provider ? 'Not configured' : 'Catalog only');
    const capabilities = arr(pick(catalogProvider, 'capabilities', 'features')).map((value) => str(value).trim()).filter(Boolean).slice(0, 32);
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

function normalizeQuotaState(s: string): QuotaBucketState {
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

const SESSION_LIST_RESULT_LIMIT = 500;
const SESSION_ID_MAX_CHARS = 512;

function safeSessionIdentity(value: RawJsonValue): string | undefined {
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
function stableProviderPrefix(provider: string): string | undefined {
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

type ResolvedSessionIdentity = Pick<SessionEntry, 'sourceID' | 'providerSessionID' | 'runID' | 'projectName'>;

function resolveSessionIdentity(raw: RawJsonValue, provider: string): ResolvedSessionIdentity {
  const sourceID = safeSessionIdentity(
    pick(raw, 'sourceID', 'sourceId', 'source_id', 'conversationID', 'conversationId', 'conversation_id')
  );
  const rawID = safeSessionIdentity(pick(raw, 'id'));
  const providerSessionID = safeSessionIdentity(pick(raw, 'sessionID', 'sessionId', 'session_id'));
  const normalizedProviderSessionID = providerSessionID?.includes(':')
    ? providerSessionID
    : stableProviderPrefix(provider) && providerSessionID
      ? `${stableProviderPrefix(provider)}:${providerSessionID}`
      : undefined;
  const resolvedSourceID = sourceID ?? (rawID?.includes(':') ? rawID : normalizedProviderSessionID);
  return {
    sourceID: resolvedSourceID,
    providerSessionID,
    runID: safeSessionIdentity(pick(raw, 'runID', 'runId', 'run_id')),
    projectName: safeSessionIdentity(pick(raw, 'projectName', 'project', 'workspaceName', 'workspace'))
  };
}

function mapSessionList(raw: RawJsonValue): SessionListResult {
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

const SESSION_BRIEFING_MAX_BYTES = 65_536;

function mapSessionReplay(raw: RawJsonValue): SessionReplayResult {
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

const CHAT_THREAD_RESULT_LIMIT = 100;
const CHAT_MESSAGE_RESULT_LIMIT = 500;
const CHAT_ID_LIMIT = 256;
const CHAT_TITLE_LIMIT = 512;
const CHAT_PREVIEW_LIMIT = 4_096;
const CHAT_CONTENT_LIMIT = 262_144;
const CHAT_BACKEND_ID_LIMIT = 64;

function requireBoundedString(
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

function optionalBoundedString(value: RawJsonValue, label: string, maxBytes: number): string | undefined {
  if (value === undefined || value === null) return undefined;
  return requireBoundedString(value, label, maxBytes);
}

function requireTimestamp(value: RawJsonValue, label: string): string {
  const timestamp = requireBoundedString(value, label, 64);
  if (
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/.test(timestamp) ||
    !Number.isFinite(Date.parse(timestamp))
  ) {
    throw new Error(`${label} must be a canonical ISO-8601 timestamp.`);
  }
  return timestamp;
}

function requireCount(value: RawJsonValue, label: string): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${label} must be a non-negative safe integer.`);
  }
  return value;
}

function decodePersistedChatRole(value: RawJsonValue, label: string): PersistedChatMessageRole {
  if (value === 'user' || value === 'assistant' || value === 'system') return value;
  throw new Error(`${label} is unsupported.`);
}

function decodeChatThreadSummary(raw: RawJsonValue, label: string): ChatThreadSummary {
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

function decodePersistedChatMessage(raw: RawJsonValue, label: string): PersistedChatMessage {
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

function decodeChatAttachmentMetadata(
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
  if (!['text/plain', 'text/markdown', 'text/csv', 'application/json', 'application/pdf'].includes(mimeType)) {
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

function assertAppendEcho(request: ChatMessageAppendRequest, result: ChatMessageAppendResult): void {
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

function mapUsageInsights(raw: RawJsonValue): UsageInsights {
  // Derived from daemon.usage.recent — the bridge aggregates events client-side.
  const events = arr(pick(raw, 'usage', 'events', 'recent'));
  const weekly = buildWeeklyBuckets(events);
  const providerMix = buildMix(events, (e) => str(pick(e, 'providerId', 'provider'), 'unknown'));
  const modelMix = buildMix(events, (e) => str(pick(e, 'modelId', 'model'), 'unknown'));
  return {
    weekly,
    providerMix,
    modelMix,
    cacheHitRatePct: computeCacheHitRatePct(events),
    source: {
      id: 'daemon.usage.recent',
      kind: 'daemon-method',
      label: 'live daemon usage insights'
    },
    qualitative: {
      state: 'unavailable',
      reason: 'The Linux daemon exposes usage aggregates only; no qualitative-analysis RPC is registered.',
      method: 'daemon.usage.recent'
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

function missionFreshness(updatedAt: string): MissionFreshness {
  const timestamp = Date.parse(updatedAt);
  if (!updatedAt || Number.isNaN(timestamp)) return 'unknown';
  const ageMs = Math.max(0, Date.now() - timestamp);
  return ageMs <= 5 * 60_000 ? 'fresh' : 'stale';
}

function mapMissionApproval(raw: RawJsonValue): MissionApprovalSnapshot | undefined {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return undefined;
  return {
    approved: pick(raw, 'approved') === true,
    approvedAt: str(pick(raw, 'approvedAt', 'approved_at')) || undefined,
    approvedBy: str(pick(raw, 'approvedBy', 'approved_by')) || undefined,
    note: str(pick(raw, 'note')) || undefined
  };
}

function mapMissionPacket(raw: RawJsonValue, index: number): MissionPacketSnapshot {
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

function mapMissionPRLinkage(raw: RawJsonValue): MissionPRLinkageSnapshot | undefined {
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

function mapMissionResult(raw: RawJsonValue, index: number): MissionResultSnapshot {
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

function mapMissionBurnRecord(raw: RawJsonValue, index: number): MissionBurnRecord {
  return {
    id: str(pick(raw, 'id', 'recordId', 'recordID'), `burn-${index}`),
    label: str(pick(raw, 'label', 'name'), 'Burn record'),
    amount: num(pick(raw, 'amount')),
    unit: str(pick(raw, 'unit'), 'unknown'),
    recordedAt: str(pick(raw, 'recordedAt', 'recorded_at'), '')
  };
}

function mapMissionTakeover(raw: RawJsonValue, index: number): MissionTakeoverRecord {
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

function mapMissionMutation(raw: RawJsonValue): MissionListResult['missions'][number] | null {
  return mapMissionDetail(raw);
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
    cloudSyncEnabled: Boolean(pick(snap, 'cloudSyncEnabled', 'cloud_sync_enabled')),
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

function projectEnum<T extends string>(
  raw: RawJsonValue,
  allowed: readonly T[],
  fallback: T | 'unknown'
): T | 'unknown' {
  const value = str(raw);
  return (allowed as readonly string[]).includes(value) ? (value as T) : fallback;
}

function optionalProjectNumber(raw: RawJsonValue): number | undefined {
  if (raw === undefined || raw === null || raw === '') return undefined;
  const value = num(raw, Number.NaN);
  return Number.isFinite(value) ? value : undefined;
}

function unwrapProjectResponse(raw: RawJsonValue): RawJsonValue {
  return pick(raw, 'result') ?? raw;
}

function mapProjectRecord(raw: RawJsonValue, index = 0): ProjectRecord | null {
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

function mapProjectDeleteResult(raw: RawJsonValue): ProjectDeleteResult {
  const response = unwrapProjectResponse(raw);
  const projectSlug = str(pick(response, 'projectSlug', 'project_slug'));
  if (!projectSlug) throw new Error('The daemon returned an invalid project deletion result.');
  return {
    projectSlug,
    deleted: Boolean(pick(response, 'deleted'))
  };
}

function mapProjectReassignResult(raw: RawJsonValue): ProjectReassignResult {
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

function mapProjectList(raw: RawJsonValue): ProjectEntry[] {
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

function mapDatabaseSnapshot(raw: RawJsonValue, restored: boolean): DatabaseSnapshotResult {
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

function mapDatabaseRecoveryBundleExport(raw: RawJsonValue): DatabaseRecoveryBundleExportResult {
  return {
    destinationPath: str(pick(raw, 'destinationPath', 'destination_path'), ''),
    byteCount: Math.max(0, num(pick(raw, 'byteCount', 'byte_count'))),
    formatVersion: Math.max(0, num(pick(raw, 'formatVersion', 'format_version'), 1))
  };
}

const DATABASE_RECOVERY_PHASES: readonly DatabaseRecoveryPhase[] = [
  'ready',
  'database_missing',
  'cipher_unavailable',
  'database_not_encrypted',
  'key_unavailable',
  'integrity_failed',
  'awaiting_database_verification',
  'unavailable'
];
const DATABASE_RECOVERY_ACTIONS: readonly DatabaseRecoveryAction[] = [
  'none',
  'export_recovery_bundle',
  'import_recovery_bundle',
  'restore_encrypted_snapshot',
  'unlock_secret_store',
  'restart_daemon'
];

function boundedRecoveryPhase(value: RawJsonValue): DatabaseRecoveryPhase {
  const phase = str(value);
  return (DATABASE_RECOVERY_PHASES as readonly string[]).includes(phase)
    ? phase as DatabaseRecoveryPhase
    : 'unavailable';
}

function boundedRecoveryAction(value: RawJsonValue): DatabaseRecoveryAction {
  const action = str(value);
  return (DATABASE_RECOVERY_ACTIONS as readonly string[]).includes(action)
    ? action as DatabaseRecoveryAction
    : 'none';
}

function mapDatabaseRecoveryStatus(raw: RawJsonValue): DatabaseRecoveryStatusResult {
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

function mapDatabaseRecoveryBundleImport(raw: RawJsonValue): DatabaseRecoveryBundleImportResult {
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

function mapDatabaseCodeDegradation(raw: RawJsonValue): DatabaseCodeDegradation | undefined {
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

function mapDatabaseCodeTrustSignal(
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

function mapDatabaseCodeSearchHit(raw: RawJsonValue, index: number): DatabaseCodeSearchHit {
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

function mapDatabaseCodeSearch(raw: RawJsonValue): DatabaseCodeSearchResult {
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

function mapDatabaseCodeContextPack(raw: RawJsonValue): DatabaseCodeContextPackResult {
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

function clampDatabaseCodeLimit(limit: number | undefined, fallback: number): number {
  const value = Number.isFinite(limit) ? Math.trunc(limit as number) : fallback;
  return Math.max(1, Math.min(DATABASE_CODE_MAX_RESULTS, value));
}

function normalizeDatabaseCodeQuery(query: string): string {
  const normalized = query.trim();
  if (!normalized) throw new Error('Code search query must not be empty.');
  return normalized.slice(0, 512);
}

function mapAccountStatus(raw: RawJsonValue): AccountStatus {
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

function mapAccountSignInOperation(raw: RawJsonValue): AccountSignInOperation {
  const operationID = str(pick(raw, 'operationID', 'operationId'));
  const expiresAt = str(pick(raw, 'expiresAt'));
  if (!operationID || !expiresAt || !Number.isFinite(Date.parse(expiresAt))) {
    throw new Error('Daemon returned an invalid sign-in operation.');
  }
  return { operationID, expiresAt };
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

export function isSafeDiagnosticsPath(path: string): boolean {
  if (!path.startsWith('/') || path.includes('\\') || path.length > 4096) return false;
  if ([...path].some((character) => character.charCodeAt(0) < 0x20 || character.charCodeAt(0) === 0x7f)) {
    return false;
  }
  const segments = path.split('/');
  const interiorSegments = segments.slice(1, -1);
  if (interiorSegments.some((segment) => segment.length === 0 || segment === '.' || segment === '..')) return false;
  const filename = segments.at(-1) ?? '';
  return /^(?:diagnostics-[A-Za-z0-9._-]+|openburnbar-diagnostics-[A-Za-z0-9._-]+)\.json$/.test(filename);
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

function mapDiagnosticsPreview(raw: RawJsonValue): DiagnosticsExportPreview {
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

function mapDiagnosticsExport(raw: RawJsonValue): DiagnosticsExport {
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

function mapAppVersionInfo(raw: RawJsonValue): AppVersionInfo {
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
    (!['appimage', 'deb', 'rpm', 'daemon'].includes(artifact.type) ||
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
  const hasInstructions = ['apt', 'dnf', 'appimage', 'unknown'].includes(packageManager)
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
    !['deb', 'rpm', 'appimage', 'unknown'].includes(channelInfo.id)
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
    packageChannel: ['deb', 'rpm', 'appimage', 'unknown'].includes(packageChannelRaw)
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

function normalizeSmartHubOperation(value: RawJsonValue): SmartHubOperation {
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

const SMART_HUB_MAX_ITEMS = 128;
const SMART_HUB_MAX_FIELDS = 128;
const SMART_HUB_MAX_TEXT_CHARS = 32_768;
const SMART_HUB_MAX_INSTANCE_CHARS = 256;
const SMART_HUB_MAX_RAW_TRANSCRIPT_CHARS = 32_768;

function boundedSmartHubText(
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

function boundedSmartHubArray(raw: RawJsonValue, label: string): RawJsonValue[] {
  if (!Array.isArray(raw)) throw new Error(`${label} must be an array.`);
  if (raw.length > SMART_HUB_MAX_ITEMS) throw new Error(`${label} exceeds the item limit.`);
  return raw;
}

function validateSmartHubFieldKeys(source: Record<string, RawJsonValue>, label: string): void {
  const entries = Object.entries(source);
  if (entries.length > SMART_HUB_MAX_FIELDS) throw new Error(`${label} has too many fields.`);
  for (const [key, value] of entries) {
    boundedSmartHubText(key, `${label} field name`, 256);
    if (typeof value === 'string') boundedSmartHubText(value, `${label} field ${key}`, SMART_HUB_MAX_TEXT_CHARS, true);
  }
}

function mapSmartHubStatus(raw: RawJsonValue): SmartHubStatusResult {
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

function mapSmartHubParity(raw: RawJsonValue): IntegrationsStatus {
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

function mapSmartHubCommand(raw: RawJsonValue): SmartHubCommandResult {
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
        rawTranscript: boundedSmartHubText(row.rawTranscript, `SmartHub discovery result ${index} rawTranscript`, SMART_HUB_MAX_RAW_TRANSCRIPT_CHARS, true)
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

const TEXT_EXPANSION_SURFACES = new Set<TextExpansionSurface>([
  'in_app_thread',
  'mac_global',
  'ios_keyboard',
  'android_ime'
]);

function mapTextExpansionScope(raw: RawJsonValue): TextExpansionScope {
  const scope = obj(raw);
  const surfaces = arr(pick(scope, 'surfaces'))
    .map((value) => str(value))
    .filter((value): value is TextExpansionSurface => TEXT_EXPANSION_SURFACES.has(value as TextExpansionSurface));
  return {
    surfaces,
    bundleIdentifiers: arr(pick(scope, 'bundleIdentifiers', 'bundle_identifiers')).map((value) => str(value)).filter(Boolean),
    threadIDs: arr(pick(scope, 'threadIDs', 'thread_ids')).map((value) => str(value)).filter(Boolean)
  };
}

function mapTextExpansionSnippet(raw: RawJsonValue): TextExpansionWireSnippet {
  const value = obj(raw);
  const mode = str(pick(value, 'mode'), 'static');
  if (!['static', 'llm_rewrite'].includes(mode)) {
    throw new Error('Native text expansion returned an unsupported mode.');
  }
  const id = str(pick(value, 'id'));
  const title = str(pick(value, 'title'));
  const trigger = str(pick(value, 'trigger'));
  const body = str(pick(value, 'body'));
  const createdAt = str(pick(value, 'createdAt', 'created_at'));
  const updatedAt = str(pick(value, 'updatedAt', 'updated_at'));
  const scope = mapTextExpansionScope(pick(value, 'scope'));
  if (!id || !title || !trigger || !createdAt || !updatedAt || scope.surfaces.length !== 1 || scope.surfaces[0] !== 'in_app_thread') {
    throw new Error('Native text expansion returned an invalid snippet.');
  }
  return {
    id,
    title,
    trigger,
    body,
    mode: mode as TextExpansionMode,
    isEnabled: Boolean(pick(value, 'isEnabled', 'is_enabled')),
    scope: { surfaces: ['in_app_thread'], bundleIdentifiers: [], threadIDs: [] },
    revision: Math.max(1, Math.trunc(num(pick(value, 'revision'), 1))),
    createdAt,
    updatedAt,
    deletedAt: str(pick(value, 'deletedAt', 'deleted_at')) || null,
    syncedAt: str(pick(value, 'syncedAt', 'synced_at')) || null,
    sourceDeviceID: str(pick(value, 'sourceDeviceID', 'source_device_id')) || null
  };
}

function mapTextExpansionSnapshot(raw: RawJsonValue): TextExpansionSnapshot {
  const value = obj(pick(raw, 'snapshot') ?? raw);
  const schemaVersion = Math.trunc(num(pick(value, 'schemaVersion', 'schema_version')));
  if (schemaVersion !== 1) {
    throw new Error('Native text expansion returned an unsupported schema.');
  }
  const snippets = arr(pick(value, 'snippets')).map(mapTextExpansionSnippet);
  const rawConsent = pick(value, 'consent');
  const consentValue = rawConsent === undefined || rawConsent === null ? null : obj(rawConsent);
  const consent = consentValue
    ? {
        inAppOnly: Boolean(pick(consentValue, 'inAppOnly', 'in_app_only')),
        acknowledgedAt: requireTimestamp(pick(consentValue, 'acknowledgedAt', 'acknowledged_at'), 'text expansion consent.acknowledgedAt'),
        declinedGlobalCapture: Boolean(pick(consentValue, 'declinedGlobalCapture', 'declined_global_capture'))
      }
    : null;
  const rawNativeStatus = pick(value, 'nativeStatus', 'native_status');
  const nativeStatusValue = rawNativeStatus === undefined || rawNativeStatus === null ? null : obj(rawNativeStatus);
  const nativeStatus = nativeStatusValue
    ? {
        status: str(pick(nativeStatusValue, 'status'), 'blocked'),
        backend: str(pick(nativeStatusValue, 'backend')) || null,
        backendPath: str(pick(nativeStatusValue, 'backendPath', 'backend_path')) || null,
        sessionType: str(pick(nativeStatusValue, 'sessionType', 'session_type'), 'unknown'),
        registration: str(pick(nativeStatusValue, 'registration'), 'engine_not_registered'),
        supportsExternalExpansion: Boolean(pick(nativeStatusValue, 'supportsExternalExpansion', 'supports_external_expansion')),
        secureFieldPolicy: str(
          pick(nativeStatusValue, 'secureFieldPolicy', 'secure_field_policy'),
          'deny-unless-inspectable-and-explicitly-nonsecure'
        ),
        noGlobalCapture: pick(nativeStatusValue, 'noGlobalCapture', 'no_global_capture') !== false,
        detail: str(pick(nativeStatusValue, 'detail'), 'Native text expansion status is unavailable.'),
        checkedAt: str(pick(nativeStatusValue, 'checkedAt', 'checked_at'), new Date().toISOString())
      }
    : null;
  return {
    schemaVersion,
    exportedAt: str(pick(value, 'exportedAt', 'exported_at'), new Date().toISOString()),
    snippets,
    consent,
    nativeStatus
  };
}

function mapTextExpansionConsent(raw: RawJsonValue): TextExpansionConsent {
  const value = obj(pick(raw, 'consent') ?? raw);
  return {
    inAppOnly: Boolean(pick(value, 'inAppOnly', 'in_app_only')),
    acknowledgedAt: requireTimestamp(pick(value, 'acknowledgedAt', 'acknowledged_at'), 'text expansion consent.acknowledgedAt'),
    declinedGlobalCapture: Boolean(pick(value, 'declinedGlobalCapture', 'declined_global_capture'))
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

const NATIVE_NOTIFICATION_ROUTES: readonly NativeNotificationRoute[] = [
  'overview', 'chat', 'insights', 'settings', 'activity', 'account', 'updates', 'support'
];

export function decodeNativeNotificationCapabilities(raw: RawJsonValue): NativeNotificationCapabilities {
  const value = requireObject(raw, 'native notification capabilities');
  const serverCapabilities = arr(pick(value, 'serverCapabilities', 'server_capabilities'))
    .map((entry) => requireString(entry, 'native notification capability'));
  const degradedReason = str(pick(value, 'degradedReason', 'degraded_reason')) || undefined;
  return {
    available: requireBoolean(pick(value, 'available'), 'native notification availability'),
    actions: requireBoolean(pick(value, 'actions'), 'native notification actions capability'),
    persistence: requireBoolean(pick(value, 'persistence'), 'native notification persistence capability'),
    body: requireBoolean(pick(value, 'body'), 'native notification body capability'),
    bodyMarkup: requireBoolean(pick(value, 'bodyMarkup', 'body_markup'), 'native notification body-markup capability'),
    serverCapabilities,
    degradedReason
  };
}

export function decodeNativeNotificationResult(raw: RawJsonValue): NativeNotificationResult {
  const value = requireObject(raw, 'native notification result');
  return {
    notificationId: requireString(pick(value, 'notificationId', 'notification_id'), 'native notification id'),
    delivered: requireBoolean(pick(value, 'delivered'), 'native notification delivery'),
    actionsAttached: requireBoolean(pick(value, 'actionsAttached', 'actions_attached'), 'native notification actions attached'),
    degradedReason: str(pick(value, 'degradedReason', 'degraded_reason')) || undefined
  };
}

export function decodeNativeNotificationActionEvent(raw: RawJsonValue): NativeNotificationActionEvent {
  const value = requireObject(raw, 'native notification action');
  const route = requireString(pick(value, 'route'), 'native notification action route');
  if (!NATIVE_NOTIFICATION_ROUTES.includes(route as NativeNotificationRoute)) {
    throw new Error(`native notification action route is unsupported: ${route}`);
  }
  const action = requireString(pick(value, 'action'), 'native notification action id');
  if (action !== 'open' && action !== 'reply') {
    throw new Error(`native notification action id is unsupported: ${action}`);
  }
  const rawPayload = pick(value, 'payload');
  const payload = rawPayload === undefined
    ? undefined
    : requireObject(rawPayload, 'native notification action payload');
  return {
    notificationId: requireString(pick(value, 'notificationId', 'notification_id'), 'native notification action notificationId'),
    route: route as NativeNotificationRoute,
    action: action as 'open' | 'reply',
    ...(payload ? { payload } : {})
  };
}

export function decodeNativeShortcutStatus(raw: RawJsonValue): NativeShortcutStatus {
  const value = requireObject(raw, 'native shortcut status');
  return {
    available: requireBoolean(pick(value, 'available'), 'native shortcut availability'),
    registered: requireBoolean(pick(value, 'registered'), 'native shortcut registration'),
    shortcuts: arr(pick(value, 'shortcuts')).map((shortcut) => requireString(shortcut, 'native shortcut')),
    degradedReason: str(pick(value, 'degradedReason', 'degraded_reason')) || undefined
  };
}

function normalizeChannel(s: string): AppVersionInfo['packageChannel'] {
  const lower = s.toLowerCase();
  if (lower.includes('deb')) return 'deb';
  if (lower.includes('rpm')) return 'rpm';
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
  const capability = pick(raw, 'capability');
  const availableRaw =
    pick(capability, 'available', 'capabilityAvailable', 'capability_available') ??
    pick(raw, 'capabilityAvailable', 'capability_available', 'available');
  const sessionRaw = pick(raw, 'activeSession', 'active_session', 'session');
  const sessionPeer = pick(sessionRaw, 'peer');
  const declaredDevices = arr(pick(raw, 'pairedDevices', 'paired_devices', 'devices', 'peers'));
  const deviceRows = declaredDevices.length > 0
    ? declaredDevices
    : sessionPeer && typeof sessionPeer === 'object' && !Array.isArray(sessionPeer)
      ? [sessionPeer]
      : [];
  const pairedDevices = deviceRows.map(
    (d, i): MercuryPairedDevice => ({
      id: str(pick(d, 'id', 'deviceID', 'deviceId', 'device_id', 'connectionID', 'connectionId'), `device-${i}`),
      name: str(pick(d, 'name', 'displayName', 'display_name', 'label'), `Device ${i + 1}`),
      platform: normalizeMercuryPlatform(str(pick(d, 'platform', 'kind', 'os'), 'unknown')),
      isOnline: Boolean(pick(d, 'isOnline', 'is_online', 'online')),
      lastSeenAt: str(pick(d, 'lastSeenAt', 'last_seen_at', 'updatedAt'), new Date(0).toISOString()),
      capabilities: arr(pick(d, 'capabilities', 'features')).map((capability) => str(capability)).filter(Boolean)
    })
  );
  const sessionPhase = str(pick(sessionRaw, 'phase', 'state', 'status')).toLowerCase();
  const activeSession =
    sessionRaw && typeof sessionRaw === 'object' && sessionPhase !== '' && sessionPhase !== 'idle'
      ? {
          kind: normalizeMercuryKind(str(pick(sessionRaw, 'kind', 'type'), 'screen-share')),
          state: normalizeMercuryState(str(pick(sessionRaw, 'state', 'phase', 'status'), 'staged')),
          peer: str(
            pick(sessionPeer, 'displayName', 'display_name', 'name') ??
              pick(sessionRaw, 'peerName', 'peer_name', 'deviceName'),
            'Paired device'
          ),
          requestId: str(pick(sessionRaw, 'requestID', 'requestId', 'request_id')) || undefined,
          startedAt: str(pick(sessionRaw, 'startedAt', 'started_at')) || undefined
        }
      : undefined;
  return {
    capabilityAvailable: absent ? false : availableRaw === true,
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
  const peer = pick(source, 'peer');
  const absent = Boolean(pick(raw, 'capabilityAbsent', 'capability_absent'));
  const availableRaw = pick(raw, 'capabilityAvailable', 'capability_available', 'available');
  const phaseRaw = str(
    pick(raw, 'phase', 'state', 'status') ?? pick(source, 'phase', 'state', 'status'),
    absent ? 'capability-absent' : 'idle'
  );
  const phase = absent ? 'capability-absent' : normalizeMercuryCallPhase(phaseRaw);
  return {
    phase,
    requestId:
      str(
        pick(raw, 'requestID', 'requestId', 'request_id') ??
          pick(source, 'requestID', 'requestId', 'request_id')
      ) || undefined,
    peerName:
      str(
        pick(raw, 'peerName', 'peer_name', 'deviceName') ??
          pick(source, 'peerName', 'peer_name', 'deviceName') ??
          pick(peer, 'displayName', 'display_name', 'name')
      ) ||
      undefined,
    peerId:
      str(
        pick(raw, 'peerID', 'peerId', 'peer_id', 'deviceID', 'deviceId') ??
          pick(source, 'peerID', 'peerId', 'peer_id', 'deviceID', 'deviceId') ??
          pick(peer, 'connectionID', 'connectionId', 'id')
      ) || undefined,
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
  const renderer = rendererRaw === 'media-gst' || /MediaCapture/i.test(rendererRaw)
    ? 'media-gst'
    : rendererRaw === 'stub'
      ? 'stub'
      : 'unknown';
  const capabilities = arr(pick(raw, 'capabilities', 'features')).map((capability) => str(capability)).filter(Boolean);
  const available = absent ? false : availableRaw === true;
  return {
    available,
    renderer,
    canReceiveCalls:
      Boolean(pick(raw, 'canReceiveCalls', 'can_receive_calls')) || capabilities.includes('call.receive') || available,
    canViewScreenShare:
      Boolean(pick(raw, 'canViewScreenShare', 'can_view_screen_share')) ||
      capabilities.includes('mirror.viewer') ||
      (available && Boolean(pick(raw, 'supportsDaemonToShellFrames', 'supports_daemon_to_shell_frames'))),
    reason: str(pick(raw, 'reason', 'detail', 'error')) || undefined
  };
}

function normalizeFileDirection(raw: string): MercuryFileTransferDirection {
  return raw.toLowerCase().includes('out') ? 'outbound' : 'inbound';
}

function normalizeFilePhase(raw: string): MercuryFileTransferPhase {
  const compact = raw.replace(/[_\-\s]/g, '').toLowerCase();
  if (compact.includes('pending') || compact.includes('offer') && !compact.includes('offered')) return 'pendingAccept';
  if (compact.includes('download') || compact.includes('fetch')) return 'downloading';
  if (compact.includes('send') || compact.includes('publish')) return 'sending';
  if (compact.includes('offered') || compact.includes('advertised')) return 'offered';
  if (compact.includes('complete') || compact.includes('done') || compact.includes('success')) return 'completed';
  if (compact.includes('decline') || compact.includes('reject')) return 'declined';
  if (compact.includes('fail') || compact.includes('error')) return 'failed';
  return 'pendingAccept';
}

function normalizeFileErrorCode(raw: RawJsonValue): MercuryFileTransferErrorCode | undefined {
  const compact = str(raw).replace(/[_\-\s]/g, '').toLowerCase();
  const codes: MercuryFileTransferErrorCode[] = [
    'capabilityAbsent',
    'invalidRequest',
    'transferNotFound',
    'localFileMissing',
    'noControlRoute',
    'publishFailed',
    'fetchFailed',
    'ioFailed',
    'peerRejected'
  ];
  return codes.find((code) => code.toLowerCase() === compact);
}

function mapMercuryFilePeer(raw: RawJsonValue): MercuryFilePeer | undefined {
  if (!raw || typeof raw !== 'object') return undefined;
  return {
    id: str(pick(raw, 'connectionID', 'connectionId', 'peerID', 'peerId', 'id'), 'peer'),
    name: str(pick(raw, 'displayName', 'display_name', 'name', 'peerName', 'peer_name'), 'Paired device'),
    isOnline: Boolean(pick(raw, 'isOnline', 'is_online', 'online')),
    lastSeenAt: str(pick(raw, 'lastSeenAt', 'last_seen_at', 'updatedAt'), new Date(0).toISOString()),
    capabilities: arr(pick(raw, 'capabilities', 'features')).map((capability) => str(capability)).filter(Boolean)
  };
}

function mapMercuryFileProgress(raw: RawJsonValue, size: number): MercuryFileTransferProgress {
  const bytesTransferred = num(pick(raw, 'bytesTransferred', 'bytes_transferred'));
  const bytesTotal = num(pick(raw, 'bytesTotal', 'bytes_total'), size);
  const fractionRaw = pick(raw, 'fraction');
  const fallbackFraction = bytesTotal > 0 ? bytesTransferred / bytesTotal : 0;
  return {
    bytesTransferred,
    bytesTotal,
    fraction: Math.max(0, Math.min(1, num(fractionRaw, fallbackFraction)))
  };
}

function mapMercuryFileTransfer(raw: RawJsonValue, index = 0): MercuryFileTransfer {
  const size = num(pick(raw, 'size', 'byteCount', 'bytesTotal', 'bytes_total'));
  const progressRaw = pick(raw, 'progress') ?? {};
  const now = new Date().toISOString();
  return {
    transferID: str(pick(raw, 'transferID', 'transferId', 'transfer_id'), `transfer-${index}`),
    manifestID: str(pick(raw, 'manifestID', 'manifestId', 'manifest_id'), `manifest-${index}`),
    direction: normalizeFileDirection(str(pick(raw, 'direction'), 'inbound')),
    phase: normalizeFilePhase(str(pick(raw, 'phase', 'state', 'status'), 'pendingAccept')),
    filename: str(pick(raw, 'filename', 'fileName', 'name'), 'untitled'),
    mime: str(pick(raw, 'mime', 'contentType', 'content_type'), 'application/octet-stream'),
    size,
    peer: mapMercuryFilePeer(pick(raw, 'peer')),
    progress: mapMercuryFileProgress(progressRaw, size),
    localPath: str(pick(raw, 'localPath', 'local_path', 'path')) || undefined,
    errorCode: normalizeFileErrorCode(pick(raw, 'errorCode', 'error_code')),
    detail: str(pick(raw, 'detail', 'reason', 'error')) || undefined,
    createdAt: str(pick(raw, 'createdAt', 'created_at'), now),
    updatedAt: str(pick(raw, 'updatedAt', 'updated_at'), now),
    completedAt: str(pick(raw, 'completedAt', 'completed_at')) || undefined
  };
}

function mapMercuryFileOfferList(raw: RawJsonValue): MercuryFileOfferListResponse {
  const source = pick(raw, 'result') ?? raw;
  const absent = Boolean(pick(source, 'capabilityAbsent', 'capability_absent'));
  const availableRaw = pick(source, 'capabilityAvailable', 'capability_available', 'available');
  return {
    capabilityAvailable: absent ? false : availableRaw === undefined ? true : Boolean(availableRaw),
    downloadDirectory: str(pick(source, 'downloadDirectory', 'download_directory')) || undefined,
    transfers: arr(pick(source, 'transfers', 'offers', 'files')).map((transfer, index) =>
      mapMercuryFileTransfer(transfer, index)
    ),
    detail: str(pick(source, 'detail', 'reason', 'error')) || undefined
  };
}

function mapMercuryFileAction(raw: RawJsonValue): MercuryFileTransferActionResponse {
  const source = pick(raw, 'result') ?? raw;
  const transferRaw = pick(source, 'transfer', 'fileTransfer', 'file_transfer');
  return {
    accepted: Boolean(pick(source, 'accepted', 'ok')),
    transfer: transferRaw && typeof transferRaw === 'object' ? mapMercuryFileTransfer(transferRaw) : undefined,
    errorCode: normalizeFileErrorCode(pick(source, 'errorCode', 'error_code')),
    detail: str(pick(source, 'detail', 'reason', 'error')) || undefined
  };
}

function mapComputerUsePanicHalt(
  raw: RawJsonValue,
  source: ComputerUsePanicSource
): ComputerUsePanicHaltResult {
  return {
    sessionId: str(pick(raw, 'sessionId', 'session_id'), '*'),
    endedAt: str(pick(raw, 'endedAt', 'ended_at'), new Date().toISOString()),
    auditHeadHashHex: str(pick(raw, 'auditHeadHashHex', 'audit_head_hash_hex')),
    source,
    raw
  };
}

const COMPUTER_USE_INVOKE_STATUSES: readonly ComputerUseInvokeResponseStatus[] = [
  'executed',
  'denied',
  'awaiting_approval',
  'error'
];

/** Decode the daemon's Swift Codable response without hiding a malformed result. */
export function decodeComputerUseInvokeResponse(raw: RawJsonValue): ComputerUseInvokeResponse {
  const direct = obj(raw);
  const source = typeof direct.status === 'string'
    ? direct
    : requireObject(pick(raw, 'result'), 'computer-use invoke response');
  const status = requireString(source.status, 'computer-use invoke status');
  if (!COMPUTER_USE_INVOKE_STATUSES.includes(status as ComputerUseInvokeResponseStatus)) {
    throw new Error(`computer-use invoke returned unsupported status: ${status}`);
  }
  const sessionId = requireString(
    pick(source, 'sessionId', 'sessionID', 'session_id'),
    'computer-use invoke sessionId'
  );
  const callID = requireString(
    pick(source, 'callID', 'callId', 'call_id'),
    'computer-use invoke callID'
  );
  const auditEntryIndexRaw = pick(source, 'auditEntryIndex', 'audit_entry_index');
  const auditEntryIndex = typeof auditEntryIndexRaw === 'number'
    && Number.isSafeInteger(auditEntryIndexRaw)
    && auditEntryIndexRaw >= 0
    ? auditEntryIndexRaw
    : undefined;
  const optionalString = (...keys: string[]): string | undefined => {
    const value = pick(source, ...keys);
    return typeof value === 'string' && value.length > 0 ? value : undefined;
  };
  return {
    sessionId,
    callID,
    status: status as ComputerUseInvokeResponseStatus,
    approvalId: optionalString('approvalId', 'approvalID', 'approval_id'),
    denyReason: optionalString('denyReason', 'deny_reason', 'reason'),
    auditEntryIndex,
    auditHeadHashHex: optionalString('auditHeadHashHex', 'audit_head_hash_hex'),
    result: source.result
  };
}

// ─────────────────────────── Bridge loader ────────────────────────────────

export async function loadShellBridge(): Promise<LinuxShellBridge | null> {
  if (!('__TAURI_INTERNALS__' in window)) {
    return null;
  }
  return {
    daemonHealth: () => invoke<DaemonHealth>('daemon_health'),
    runtimeCapabilities: async () =>
      decodeRuntimeCapabilityManifest(await invoke<RawJsonValue>('runtime_capabilities')),
    gatewayProbe: () => invoke<boolean>('gateway_probe'),
    chatAttachmentUpload: async (request) =>
      decodeChatAttachmentUpload(await invoke<RawJsonValue>('chat_attachment_upload', { request })),
    gatewayChatStream: (request, onChunk) => {
      const onEvent = new Channel<string>();
      onEvent.onmessage = onChunk;
      return invoke<void>('gateway_chat_stream', { request, onEvent });
    },
    gatewayChatCancel: (requestId) => invoke<void>('gateway_chat_cancel', { requestId }),
    openDashboard: () => invoke<void>('open_dashboard'),
    initialDeepLinkRoute: () => invoke<string | null>('initial_deep_link_route'),
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
    onboardingSnapshot: async () =>
      decodeLinuxOnboardingSnapshot(await invoke<RawJsonValue>('onboarding_snapshot')),
    onboardingAction: async (request) =>
      decodeLinuxOnboardingSnapshot(
        await invoke<RawJsonValue>('onboarding_action', { request })
      ),
    onboardingReset: async () =>
      decodeLinuxOnboardingSnapshot(await invoke<RawJsonValue>('onboarding_reset')),
    subscriptionStart: async (request) =>
      decodeDaemonSubscriptionResponse(
        await invoke<RawJsonValue>('subscription_start', { request })
      ),
    subscriptionResume: async (request) =>
      decodeDaemonSubscriptionResponse(
        await invoke<RawJsonValue>('subscription_resume', { request })
      ),
    subscriptionStop: async (request) =>
      decodeDaemonSubscriptionStopResponse(
        await invoke<RawJsonValue>('subscription_stop', { request })
      ),

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
    sessionReplay: async (sessionID) =>
      mapSessionReplay(await invoke<RawJsonValue>('session_replay', { sessionId: sessionID })),
    sessionResume: async (sessionID) =>
      mapSessionReplay(await invoke<RawJsonValue>('session_resume', { sessionId: sessionID })),
    // Exact persisted chat authority; unlike P03, these never derive chat from usage rows.
    chatThreadList: async (query, limit = 100) => {
      const raw = await invoke<RawJsonValue>('chat_thread_list', { query: query || null, limit });
      return decodeChatThreadList(raw);
    },
    chatThreadGet: async (threadID, maxMessages = 500, before) => {
      const args: {
        threadId: string;
        maxMessages: number;
        beforeTimestamp?: string;
        beforeMessageId?: string;
      } = { threadId: threadID, maxMessages };
      if (before) {
        args.beforeTimestamp = before.timestamp;
        args.beforeMessageId = before.messageID;
      }
      const raw = await invoke<RawJsonValue>('chat_thread_get', args);
      return decodeChatThreadGet(raw);
    },
    chatMessageAppend: async (request) => {
      const raw = await invoke<RawJsonValue>('chat_message_append', { request });
      const result = decodeChatMessageAppend(raw);
      assertAppendEcho(request, result);
      return result;
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
    // Canonical daemon.mission.get — detail fields are returned by the
    // snapshot itself; there is no separate history/evidence RPC to invent.
    missionGet: async (id) => {
      const raw = await invoke<RawJsonValue>('mission_get', { missionId: id });
      return mapMissionDetail(raw);
    },
    // P06 — daemon.mission.approve / daemon.mission.cancel
    missionApprovalDecision: async (id, decision) => {
      await invoke<void>('mission_approval_decision', { id, decision });
    },
    // Canonical daemon.mission.cancel for an explicit cancellation action.
    missionCancel: async (id, note) => {
      const raw = await invoke<RawJsonValue>('mission_cancel', { missionId: id, note });
      return mapMissionDetail(raw);
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
    nativeNotificationCapabilities: async () =>
      decodeNativeNotificationCapabilities(await invoke<RawJsonValue>('native_notification_capabilities')),
    nativeNotificationShow: async (request) =>
      decodeNativeNotificationResult(await invoke<RawJsonValue>('native_notification_show', { request })),
    nativeShortcutStatus: async () =>
      decodeNativeShortcutStatus(await invoke<RawJsonValue>('native_shortcut_status')),
    // P29 — authenticated daemon-owned encrypted text-expansion storage.
    textExpansionList: async () => {
      const raw = await invoke<RawJsonValue>('text_expansion_list');
      return mapTextExpansionSnapshot(raw);
    },
    textExpansionUpsert: async (snippet) => {
      const raw = await invoke<RawJsonValue>('text_expansion_upsert', { snippet });
      return mapTextExpansionSnippet(raw);
    },
    textExpansionDelete: async (id) => {
      const raw = await invoke<RawJsonValue>('text_expansion_delete', { id });
      return mapTextExpansionSnapshot(raw);
    },
    textExpansionConsentUpdate: async (consent) => {
      const raw = await invoke<RawJsonValue>('text_expansion_consent_update', { consent });
      return mapTextExpansionConsent(raw);
    },
    // P07 — derived from daemon.config.get + daemon.health
    dbStatus: async () => {
      const raw = await invoke<RawJsonValue>('db_status');
      return mapDbStatus(raw);
    },
    // P07 — daemon.controller.project.list
    projectList: async () => {
      const raw = await invoke<RawJsonValue>('project_list');
      return mapProjectList(raw);
    },
    // P19 — daemon.controller.project.get
    projectGet: async (projectSlug) => {
      const raw = await invoke<RawJsonValue>('project_get', { projectSlug });
      return mapProjectRecord(raw);
    },
    // P19 — daemon.controller.project.upsert
    projectUpsert: async (project) => {
      const raw = await invoke<RawJsonValue>('project_upsert', { project });
      return mapProjectRecord(raw);
    },
    // P19 — daemon.controller.project.delete
    projectDelete: async (projectSlug) => {
      const raw = await invoke<RawJsonValue>('project_delete', { projectSlug });
      return mapProjectDeleteResult(raw);
    },
    // P19 — daemon.controller.project.reassign
    projectReassign: async (sourceProjectSlug, targetProjectSlug) => {
      const raw = await invoke<RawJsonValue>('project_reassign', { sourceProjectSlug, targetProjectSlug });
      return mapProjectReassignResult(raw);
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
    // P07 — reject maps to forget. Approval requires the real memory body and
    // must use memorySetStatus; never invent an approved placeholder here.
    memoryReviewDecision: async (id, decision) => {
      if (decision === 'rejected') {
        await invoke<RawJsonValue>('memory_set_status', {
          action: 'reject',
          payload: { memoryID: id }
        });
        return;
      }
      if (decision === 'approved') {
        throw new Error(
          'memoryReviewDecision cannot approve without body text; use memorySetStatus({ text }) from the store.'
        );
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
    // P07 — bounded encrypted project-code database snapshot/recovery.
    databaseSnapshot: async (destinationPath, maxBytes) => {
      const raw = await invoke<RawJsonValue>('database_snapshot', {
        destinationPath,
        maxBytes: maxBytes == null ? undefined : Math.max(1, Math.min(512 * 1_024 * 1_024, Math.trunc(maxBytes)))
      });
      return mapDatabaseSnapshot(raw, false);
    },
    databaseRestore: async (snapshotPath, maxBytes) => {
      const raw = await invoke<RawJsonValue>('database_restore', {
        snapshotPath,
        maxBytes: maxBytes == null ? undefined : Math.max(1, Math.min(512 * 1_024 * 1_024, Math.trunc(maxBytes)))
      });
      return mapDatabaseSnapshot(raw, true);
    },
    // P22 — read-only recovery posture. The daemon decides whether key
    // custody, database presence, and integrity verification are each proven.
    databaseRecoveryBundleStatus: async () => {
      const raw = await invoke<RawJsonValue>('database_recovery_bundle_status');
      return mapDatabaseRecoveryStatus(raw);
    },
    // P22 — daemon-owned passphrase recovery bundle. Passphrases stay in the
    // native invoke/RPC call and are never persisted in Zustand or web storage.
    databaseRecoveryBundleExport: async (request) => {
      const raw = await invoke<RawJsonValue>('database_recovery_bundle_export', {
        destinationPath: request.destinationPath,
        passphrase: request.passphrase
      });
      return mapDatabaseRecoveryBundleExport(raw);
    },
    databaseRecoveryBundleImport: async (request) => {
      const raw = await invoke<RawJsonValue>('database_recovery_bundle_import', {
        sourcePath: request.sourcePath,
        passphrase: request.passphrase
      });
      return mapDatabaseRecoveryBundleImport(raw);
    },
    // P22 — daemon.code.search / daemon.code.context_pack. The daemon owns
    // index availability and trust wrapping; the shell only clamps bounded
    // reads and maps the typed response.
    databaseCodeSearch: async (request) => {
      const raw = await invoke<RawJsonValue>('database_code_search', {
        query: normalizeDatabaseCodeQuery(request.query),
        projectPath: request.projectPath,
        limit: clampDatabaseCodeLimit(request.limit, DATABASE_CODE_DEFAULT_RESULTS)
      });
      return mapDatabaseCodeSearch(raw);
    },
    databaseCodeContextPack: async (request) => {
      const raw = await invoke<RawJsonValue>('database_code_context_pack', {
        query: normalizeDatabaseCodeQuery(request.query),
        projectPath: request.projectPath,
        limit: clampDatabaseCodeLimit(request.limit, 10),
        maxBytes: Math.max(1_024, Math.min(DATABASE_CODE_MAX_CONTEXT_BYTES, Math.trunc(request.maxBytes ?? DATABASE_CODE_MAX_CONTEXT_BYTES)))
      });
      return mapDatabaseCodeContextPack(raw);
    },
    // P08 — daemon-owned browser PKCE and lower-trust Linux identity.
    accountStatus: async () => {
      const raw = await invoke<RawJsonValue>('account_status');
      return mapAccountStatus(raw);
    },
    accountBeginSignIn: async () => {
      const raw = await invoke<RawJsonValue>('account_begin_sign_in');
      return mapAccountSignInOperation(raw);
    },
    accountCancelSignIn: async (operationID) => {
      const raw = await invoke<RawJsonValue>('account_cancel_sign_in', { operationId: operationID });
      return mapAccountStatus(raw);
    },
    accountRotateIdentity: async () => {
      const raw = await invoke<RawJsonValue>('account_rotate_identity');
      return mapAccountStatus(raw);
    },
    accountSignOut: async () => {
      const raw = await invoke<RawJsonValue>('account_sign_out');
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
    openExternalUrl: (url) => invoke<void>('open_external_url', { url }),
    openUpdateUrl: (url) => invoke<void>('open_update_url', { url }),
    // P10 — daemon-side restore hook; callers re-fetch status afterwards.
    membershipRestore: async () => {
      await invoke<RawJsonValue>('membership_restore');
    },
    // P09 — local version info
    appVersionInfo: async () => {
      const raw = await invoke<RawJsonValue>('app_version_info');
      return mapAppVersionInfo(raw);
    },
    updateStatus: async () => {
      const raw = await invoke<RawJsonValue>('update_status');
      return decodeLinuxUpdateStatus(raw);
    },
    // P09 — redacted diagnostics export → file path
    exportDiagnostics: async () => {
      const raw = await invoke<RawJsonValue>('export_diagnostics');
      return mapDiagnosticsExport(raw);
    },
    // P11 — session env for pet tier detection
    sessionEnv: async () => {
      const raw = await invoke<RawJsonValue>('session_env');
      return {
        XDG_SESSION_TYPE: str(pick(raw, 'xdg_session_type', 'XDG_SESSION_TYPE')) || undefined,
        XDG_CURRENT_DESKTOP: str(pick(raw, 'xdg_current_desktop', 'XDG_CURRENT_DESKTOP')) || undefined
      };
    },
    // P12 — explicit capability-absent until a real BurnBarRPCMethod media contract exists.
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
    mediaFileOfferList: async () => {
      try {
        const raw = await invoke<RawJsonValue>('media_file_offer_list');
        return mapMercuryFileOfferList(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return {
            capabilityAvailable: false,
            transfers: [],
            detail: e instanceof Error ? e.message : String(e)
          };
        }
        throw e;
      }
    },
    mediaFileAccept: async ({ transferID, manifestID }) => {
      try {
        const raw = await invoke<RawJsonValue>('media_file_accept', { transferId: transferID, manifestId: manifestID });
        return mapMercuryFileAction(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return {
            accepted: false,
            errorCode: 'capabilityAbsent',
            detail: e instanceof Error ? e.message : String(e)
          };
        }
        throw e;
      }
    },
    mediaFileDecline: async ({ transferID, manifestID, reason }) => {
      try {
        const raw = await invoke<RawJsonValue>('media_file_decline', {
          transferId: transferID,
          manifestId: manifestID,
          reason
        });
        return mapMercuryFileAction(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return {
            accepted: false,
            errorCode: 'capabilityAbsent',
            detail: e instanceof Error ? e.message : String(e)
          };
        }
        throw e;
      }
    },
    mediaFileSend: async ({ path, peerID }) => {
      try {
        const raw = await invoke<RawJsonValue>('media_file_send', { path, peerId: peerID });
        return mapMercuryFileAction(raw);
      } catch (e) {
        if (isCapabilityAbsentError(e)) {
          return {
            accepted: false,
            errorCode: 'capabilityAbsent',
            detail: e instanceof Error ? e.message : String(e)
          };
        }
        throw e;
      }
    },
    toolApprovalRespond: async (approvalId, decision, note) => {
      await invoke<RawJsonValue>('tool_approval_respond', {
        approvalId,
        decision,
        note: note ?? null
      });
    },
    memorySetStatus: (action, payload) =>
      invoke<RawJsonValue>('memory_set_status', { action, payload }),
    computerUseSessionAuthorityStatus: () =>
      invoke<ComputerUseSessionAuthorityStatus>('computer_use_session_authority_status'),
    computerUseSessionStart: (params) =>
      invoke<ComputerUseSessionAuthorityStatus>('computer_use_session_start', { params }),
    computerUseInvoke: async (params) =>
      decodeComputerUseInvokeResponse(await invoke<RawJsonValue>('computer_use_invoke', { params })),
    computerUseApprovalPending: (params) =>
      invoke<RawJsonValue>('computer_use_approval_pending', { params: params ?? null }),
    computerUseApprovalRespond: (params) =>
      invoke<RawJsonValue>('computer_use_approval_respond', { params }),
    computerUseAuditExport: (params) =>
      invoke<RawJsonValue>('computer_use_audit_export', { params: params ?? null }),
    computerUsePanicHalt: async (params) => {
      const sessionId = params?.sessionId ?? '*';
      const source = params?.source ?? 'hotkey';
      const raw = await invoke<RawJsonValue>('computer_use_panic_halt', { sessionId, source });
      return mapComputerUsePanicHalt(raw, source);
    },
    // P13 — daemon-reported smart-display/device integration status.
    integrationsStatus: async () => {
      const raw = await invoke<RawJsonValue>('integrations_status');
      return mapIntegrationsStatus(raw);
    },
    // P28 — fixed-argv SmartHub/device CLI operations; never a generic shell.
    smartHubCommand: async (operation, options) => {
      const payload = options?.requestId ? { operation, requestId: options.requestId } : { operation };
      const raw = await invoke<RawJsonValue>('smarthub_command', payload);
      return decodeSmartHubCommandResponse(raw);
    },
    smartHubCancel: async (requestId) => {
      await invoke<void>('smarthub_cancel', { requestId });
    }
  };
}
