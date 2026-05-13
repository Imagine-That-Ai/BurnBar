/**
 * @fileoverview Shared TypeScript types for OpenBurnBar Cloud Functions v2.
 *
 * All Firestore document shapes, provider enums, and runtime types are
 * centralized here to keep the rest of the codebase strongly typed and
 * self-documenting.
 */

// ---------------------------------------------------------------------------
// Provider identity
// ---------------------------------------------------------------------------

/** Stable lowercase catalog/provider key used by provider accounts. */
export type ProviderID = string;

/** Supported provider kinds. */
export const SUPPORTED_PROVIDERS = [
  "openai",
  "minimax",
  "zai",
  "factory",
  "cursor",
  "claude-code",
  "codex",
] as const;

export type Provider = (typeof SUPPORTED_PROVIDERS)[number];

/** Providers that support backend quota refresh. */
export const BACKEND_REFRESH_PROVIDERS: readonly Provider[] = [
  "openai",
  "minimax",
  "zai",
  "factory",
  "cursor",
];

/** Providers that are treated as local-only (no backend refresh). */
export const LOCAL_ONLY_PROVIDERS: readonly Provider[] = ["claude-code", "codex"];

// ---------------------------------------------------------------------------
// Credential kinds
// ---------------------------------------------------------------------------

export type CredentialKind = "token" | "bearer" | "session" | "cookie" | "plan";

export type ProviderAccountStatus =
  | "connected"
  | "disconnected"
  | "stale"
  | "error"
  | "disabled"
  | "deleted";

export type ProviderAccountStorageScope =
  | "cloud_refreshable"
  | "local_only"
  | "device_keychain"
  | "server_private";

export type ProviderAccountRefreshState =
  | "connected"
  | "refreshing"
  | "stale"
  | "error"
  | "disabled"
  | "local_only";

export interface ProviderAccountCredentialDescriptor {
  credentialKind: CredentialKind;
  storageScope: ProviderAccountStorageScope;
  redactedLabel: string;
}

// ---------------------------------------------------------------------------
// Firestore: provider_accounts/{accountID}
// ---------------------------------------------------------------------------

export interface ProviderAccountDoc {
  /** Stable account ID unique within a user namespace. */
  id: string;

  /** Canonical provider key from the catalog/cloud contract. */
  providerID: ProviderID;

  /** User-visible account label, e.g. "Work" or "Personal". */
  label: string;

  /** Optional non-secret identity hint such as email/org/team name. */
  identityHint?: string;

  status: ProviderAccountStatus;
  credentialKind: CredentialKind;
  storageScope: ProviderAccountStorageScope;

  /** Redacted display label only. Raw secrets and secret refs are forbidden. */
  redactedLabel: string;

  /** Device that owns a local-only credential/session, if any. */
  sourceDeviceID?: string;

  /** Optional switcher/browser/CLI profile linkage. Not a credential. */
  linkedSwitcherProfileID?: string;

  isDefault: boolean;
  sortKey: number;
  lastValidatedAt?: string;
  lastRefreshAt?: string;
  lastErrorCode?: string;
  schemaVersion: number;
  createdAt: string;
  updatedAt: string;
}

// ---------------------------------------------------------------------------
// Firestore: provider_account_device_links/{accountID}_{deviceID}
// ---------------------------------------------------------------------------

export type DeviceLinkCapability = "owner" | "use" | "add";
export type DeviceLinkStatus = "active" | "revoked";

export interface ProviderAccountDeviceLinkDoc {
  id: string;
  accountID: string;
  deviceID: string;
  deviceDisplayName: string;
  capability: DeviceLinkCapability;
  status: DeviceLinkStatus;
  lastObservedAt: string;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}

// ---------------------------------------------------------------------------
// Firestore: runtime_connection_preferences/{deviceID}_{runtimeKind}
// ---------------------------------------------------------------------------

export type RuntimeConnectionPreferenceKind = "hermes" | "piAgent";

export interface RuntimeConnectionPreferenceDoc {
  id: string;
  deviceID: string;
  runtimeKind: RuntimeConnectionPreferenceKind;
  selectedConnectionID: string;
  selectedInstanceID?: string;
  selectedModelID?: string;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}

// ---------------------------------------------------------------------------
// Firestore: provider_account_secret_refs/{uid}_{accountID} (server-private)
// ---------------------------------------------------------------------------

export interface ProviderAccountSecretRefDoc {
  uid: string;
  providerID: ProviderID;
  accountID: string;
  secretVersionName: string;
  createdAt: string;
  updatedAt: string;
}

// ---------------------------------------------------------------------------
// Firestore: provider_connections/{provider}
// ---------------------------------------------------------------------------

export interface ProviderConnectionDoc {
  /** Provider key (e.g. "minimax"). */
  provider: Provider;

  /** Connection lifecycle status. */
  status: "connected" | "disconnected" | "error" | "stale";

  /** ISO 8601 timestamp of last successful validation. */
  lastValidatedAt?: string;

  /** ISO 8601 timestamp of last quota refresh. */
  lastRefreshAt?: string;

  /** Last known error code from a refresh or validation attempt. */
  lastErrorCode?: string;

  /** Kind of credential stored in the vault. */
  credentialKind: CredentialKind;

  /** Redacted human-readable label (e.g. "minimax_***abcd"). */
  redactedLabel: string;

  /** Schema version for forward-compatible migrations. */
  schemaVersion: number;

  /** Optional warning message shown to the user (e.g. session TTL). */
  warningMessage?: string;
}

// ---------------------------------------------------------------------------
// Firestore: hermes_connections / hermes_pairings
// ---------------------------------------------------------------------------

export type HermesConnectionMode = "local" | "directURL" | "relayLink";

export type HermesConnectionStatus =
  | "pending"
  | "online"
  | "offline"
  | "unauthorized"
  | "revoked"
  | "degraded";

export interface HermesConnectionDoc {
  id: string;
  displayName: string;
  mode: HermesConnectionMode;
  status: HermesConnectionStatus;
  profileName?: string;
  endpointURL?: string;
  advertisedModel?: string;
  relayPublicKey?: string;
  relayKeyVersion?: number;
  relayEncryption?: string;
  capabilities: string[];
  lastSeenAt?: string;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}

export interface HermesPairingDoc {
  id: string;
  status: "pending" | "completed" | "expired" | "revoked";
  codeHash: string;
  failedAttempts?: number;
  requestedByDeviceId?: string;
  requestedByPlatform?: "ios" | "ipados" | "macos" | "web";
  displayName?: string;
  connectionId?: string;
  expiresAt: string;
  expireAt?: import("firebase-admin/firestore").Timestamp;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}

export interface HermesConnectionAuditEventDoc {
  id: string;
  eventType:
    | "pairing_created"
    | "pairing_completed"
    | "pairing_failed"
    | "connection_created"
    | "connection_revoked"
    | "connection_status_updated";
  connectionId?: string;
  pairingId?: string;
  actorDeviceId?: string;
  observedAt: string;
  detail?: Record<string, unknown>;
  schemaVersion: number;
  expireAt?: import("firebase-admin/firestore").Timestamp;
}

export type HermesRelayOperation =
  | "chatCompletions"
  | "models"
  | "sessions"
  | "sessionDetail"
  | "profiles"
  | "jobs";

export type HermesRelayRequestStatus =
  | "pending"
  | "claimed"
  | "streaming"
  | "completed"
  | "failed"
  | "cancelled"
  | "expired";

export interface HermesRelayRequestDoc {
  id: string;
  connectionId: string;
  operation: HermesRelayOperation;
  status: HermesRelayRequestStatus;
  method: "GET" | "POST";
  path?: string;
  sessionId?: string;
  body?: string;
  payloadCiphertext?: string;
  wrappedKey?: string;
  relayEncryption?: string;
  relayKeyVersion?: number;
  error?: string;
  chunkCount: number;
  claimedAt?: string;
  claimedBy?: string;
  completedAt?: string;
  createdAt: string;
  updatedAt: string;
  expiresAt: string;
  expireAt?: import("firebase-admin/firestore").Timestamp;
  schemaVersion: number;
}

export interface HermesRelayChunkDoc {
  id: string;
  requestId: string;
  sequence: number;
  kind: "sse" | "data" | "error";
  data?: string;
  text?: string;
  error?: string;
  ciphertext?: string;
  createdAt: string;
  updatedAt?: string;
  schemaVersion: number;
}

// ---------------------------------------------------------------------------
// Firestore: pi_agent_connections / pi_agent_pairings
// ---------------------------------------------------------------------------

export type PiAgentConnectionMode = "local" | "directURL" | "relayLink";

export type PiAgentConnectionStatus =
  | "pending"
  | "online"
  | "offline"
  | "unauthorized"
  | "revoked"
  | "degraded";

export interface PiAgentInstanceDoc {
  id: string;
  displayName: string;
  endpointURL?: string;
  status: PiAgentConnectionStatus;
  modelName?: string;
  capabilities: string[];
  lastSeenAt?: string;
  schemaVersion: number;
}

export interface PiAgentRuntimeModelDoc {
  id: string;
  providerID: string;
  providerName: string;
  modelID: string;
  displayName: string;
  instanceID?: string;
  schemaVersion: number;
}

export interface PiAgentSessionDoc {
  id: string;
  title?: string;
  preview?: string;
  source?: string;
  model?: string;
  instanceID?: string;
  startedAt?: string;
  lastActiveAt?: string;
  endedAt?: string;
  isActive: boolean;
  messageCount: number;
  toolCallCount: number;
  inputTokens: number;
  outputTokens: number;
  schemaVersion: number;
}

export interface PiAgentConnectionDoc {
  id: string;
  displayName: string;
  mode: PiAgentConnectionMode;
  status: PiAgentConnectionStatus;
  endpointURL?: string;
  advertisedModel?: string;
  selectedInstanceID?: string;
  redisURL?: string;
  relayPublicKey?: string;
  relayKeyVersion?: number;
  relayEncryption?: string;
  realtimeRelayURL?: string;
  realtimeRelayStatus?: string;
  realtimeRelayLastSeenAt?: string;
  realtimeRelayProtocolVersion?: number;
  capabilities: string[];
  instances?: PiAgentInstanceDoc[];
  models?: PiAgentRuntimeModelDoc[];
  lastSeenAt?: string;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}

export interface PiAgentPairingDoc {
  id: string;
  status: "pending" | "completed" | "expired" | "revoked";
  codeHash: string;
  failedAttempts?: number;
  requestedByDeviceId?: string;
  requestedByPlatform?: "ios" | "ipados" | "android" | "macos" | "web";
  displayName?: string;
  connectionId?: string;
  expiresAt: string;
  expireAt?: import("firebase-admin/firestore").Timestamp;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}

export interface PiAgentConnectionAuditEventDoc {
  id: string;
  eventType:
    | "pairing_created"
    | "pairing_completed"
    | "pairing_failed"
    | "connection_created"
    | "connection_revoked"
    | "connection_status_updated";
  connectionId?: string;
  pairingId?: string;
  actorDeviceId?: string;
  observedAt: string;
  detail?: Record<string, unknown>;
  schemaVersion: number;
  expireAt?: import("firebase-admin/firestore").Timestamp;
}

export type PiAgentRelayOperation =
  | "chatCompletions"
  | "models"
  | "sessions"
  | "sessionDetail";

export type PiAgentRelayRequestStatus =
  | "pending"
  | "claimed"
  | "streaming"
  | "completed"
  | "failed"
  | "cancelled"
  | "expired";

export interface PiAgentRelayRequestDoc {
  id: string;
  connectionId: string;
  operation: PiAgentRelayOperation;
  status: PiAgentRelayRequestStatus;
  method: "GET" | "POST";
  payloadCiphertext: string;
  wrappedKey: string;
  relayEncryption: string;
  relayKeyVersion: number;
  error?: string;
  chunkCount: number;
  claimedAt?: string;
  claimedBy?: string;
  completedAt?: string;
  createdAt: string;
  updatedAt: string;
  expiresAt: string;
  expireAt?: import("firebase-admin/firestore").Timestamp;
  schemaVersion: number;
}

export interface PiAgentRelayChunkDoc {
  id: string;
  requestId: string;
  sequence: number;
  kind: "sse" | "data" | "error";
  ciphertext: string;
  createdAt: string;
  updatedAt?: string;
  schemaVersion: number;
}

// ---------------------------------------------------------------------------
// Firestore: quota_snapshots/{provider}_{sourceId}
// ---------------------------------------------------------------------------

export interface QuotaBucket {
  /** Bucket name from the provider (e.g. "tokens", "requests", "fast-calls"). */
  name: string;

  /** Used amount (same unit as limit). */
  used: number;

  /** Granted limit, or -1 if unlimited/unknown. */
  limit: number;

  /** Remaining computed as max(0, limit - used) when limit >= 0. */
  remaining: number;

  /** Window descriptor (e.g. "daily", "monthly", "lifetime"). */
  window?: string;

  /**
   * When this bucket refills. Mac writes a Firestore `Timestamp`; legacy
   * docs may still carry an ISO 8601 string at `meta.resetsAt` (handled by
   * each client's compat path). Server-side adapters that don't compute a
   * reset moment leave this undefined.
   */
  resetsAt?: import("firebase-admin/firestore").Timestamp | string;

  /** Bucket-specific metadata from the provider. */
  meta?: Record<string, unknown>;
}

export interface QuotaSnapshotDoc {
  /** Kind of source (always "provider" today; reserved for future expansion). */
  sourceKind: "provider";

  /** Source identifier (e.g. "default" or a plan ID). */
  sourceId: string;

  /** Provider key. */
  provider: Provider;

  /** Canonical provider catalog/cloud key. Defaults to provider for legacy docs. */
  providerID?: ProviderID;

  /** Provider account this snapshot belongs to. Missing means legacy/provider-level. */
  accountID?: string;

  /** Denormalized account label at fetch time for stable display/history. */
  accountLabel?: string;

  /** Storage scope of the account that produced this snapshot. */
  accountStorageScope?: ProviderAccountStorageScope;

  /** ISO 8601 timestamp when this snapshot was fetched. */
  fetchedAt: string;

  /** Human-readable source label. */
  source: string;

  /** Confidence level: "high" | "medium" | "low" | "stale". */
  confidence: "high" | "medium" | "low" | "stale";

  /** Deep-link to provider management page, when known. */
  managementURL?: string;

  /** Free-form status message from the provider or from our adapters. */
  statusMessage?: string;

  /** Quota buckets. */
  buckets: QuotaBucket[];

  /** Schema version. */
  schemaVersion: number;

  /** ISO 8601 timestamp of last document update. */
  updatedAt: string;
}

// ---------------------------------------------------------------------------
// Firestore: model_benchmark_snapshots/{source_model_task_timestamp}
// Firestore: model_benchmark_source_status/{source}
// ---------------------------------------------------------------------------

export type ModelBenchmarkSource =
  | "artificial_analysis"
  | "terminal_bench"
  | "design_arena"
  | "huggingface"
  | "manual_fixture"
  | "cached_fixture";

export type ModelBenchmarkTaskCategory =
  | "general"
  | "coding"
  | "terminal"
  | "design"
  | "agent"
  | "analysis"
  | "unknown";

export type ModelBenchmarkFreshness =
  | "fresh"
  | "stale"
  | "unavailable"
  | "cached"
  | "manual";

export interface ModelBenchmarkSnapshotDoc {
  id: string;
  source: ModelBenchmarkSource;
  sourceURL?: string;
  attribution?: string;
  fetchedAt: string;
  modelID: string;
  providerID?: ProviderID;
  taskCategory: ModelBenchmarkTaskCategory;
  score?: number;
  rank?: number;
  costSignal?: number;
  latencySignal?: number;
  contextWindowTokens?: number;
  reliabilitySignal?: number;
  confidence?: number;
  freshness: ModelBenchmarkFreshness;
  schemaVersion: number;
  updatedAt: string;
}

export interface ModelBenchmarkSourceStatusDoc {
  source: ModelBenchmarkSource;
  status: "fresh" | "stale" | "unavailable" | "error";
  fetchedAt?: string;
  message: string;
  attribution?: string;
  schemaVersion: number;
  updatedAt: string;
}

// ---------------------------------------------------------------------------
// Firestore: usage_rollups/{windowKey}
// ---------------------------------------------------------------------------

export interface ProviderSummary {
  provider: Provider;
  providerID?: ProviderID;
  totalRequests: number;
  totalTokens: number;
  totalCost?: number;
}

export interface ProviderAccountSummary {
  id: string;
  providerID: ProviderID;
  accountID?: string;
  accountLabel: string;
  storageScope?: ProviderAccountStorageScope;
  totalRequests: number;
  totalTokens: number;
  totalCost?: number;
}

export interface ModelSummary {
  model: string;
  provider: Provider;
  requests: number;
  tokens: number;
  cost?: number;
}

export interface DeviceSummary {
  deviceId: string;
  requests: number;
  tokens: number;
}

export interface UsageRollupDoc {
  /** Window key: "today", "7d", "30d", "90d", "all_time". */
  today: number;
  "7d": number;
  "30d": number;
  "90d": number;
  all_time: number;

  /** Aggregated totals keyed by metric name. */
  totals: Record<string, number>;

  /** Per-provider summaries. */
  providerSummaries: ProviderSummary[];

  /** Per-account summaries. Missing on legacy docs. */
  accountSummaries?: ProviderAccountSummary[];

  /** Per-model summaries. */
  modelSummaries: ModelSummary[];

  /** Per-device summaries. */
  deviceSummaries: DeviceSummary[];

  /** Sparse daily points for sparkline rendering: YYYY-MM-DD -> value. */
  dailyPoints: Record<string, number>;

  /** ISO 8601 timestamp when the rollup was last computed. */
  computedAt: string;

  /** Schema version. */
  schemaVersion: number;
}

// ---------------------------------------------------------------------------
// Firestore: users/{uid}/usage_counter_days/{yyyy-mm-dd}
// Firestore: users/{uid}/usage_counter_totals/all_time
// ---------------------------------------------------------------------------

export interface UsageCounterDimensionDoc {
  requests: number;
  tokens: number;
  costUsd: number;
  provider?: Provider;
  providerID?: ProviderID;
  accountID?: string;
  accountLabel?: string;
  storageScope?: ProviderAccountStorageScope;
  model?: string;
  deviceId?: string;
  updatedAt: string;
  schemaVersion: number;
}

export interface UsageCounterDayDoc {
  day: string;
  requests: number;
  tokens: number;
  costUsd: number;
  updatedAt: string;
  schemaVersion: number;
}

// ---------------------------------------------------------------------------
// Firestore: rollup_jobs/current
// ---------------------------------------------------------------------------

export interface RollupJobDoc {
  /** Whether at least one usage doc has changed since last rollup. */
  dirty: boolean;

  /** ISO 8601 timestamp of the last successful rollup computation. */
  lastComputedAt?: string;

  /** ISO 8601 timestamp of the last time the dirty flag was set. */
  dirtiedAt?: string;

  /** Error code from the most recent failed rollup run. */
  lastErrorCode?: string;
}

// ---------------------------------------------------------------------------
// Firestore: users/{uid}/usage/{usageDoc}
// ---------------------------------------------------------------------------

export interface UsageEventDoc {
  /** Provider that served the request. */
  provider: Provider;

  /** Canonical provider account namespace. Defaults to provider when absent. */
  providerID?: ProviderID;

  /** Optional provider account attribution. Missing means unattributed/legacy. */
  providerAccountID?: string;

  /** Denormalized account label at ingestion time. */
  providerAccountLabel?: string;

  /** Account storage/source class. */
  providerAccountSource?: ProviderAccountStorageScope;

  /** Model identifier. */
  model?: string;

  /** Provider/session identifier used to collapse idempotent re-uploads. */
  sessionId?: string;

  /** Device that originated the request. */
  deviceId?: string;

  /** Source device identifier used by synced records from another device. */
  sourceDeviceId?: string;

  /** Number of input tokens. */
  inputTokens?: number;

  /** Number of output tokens. */
  outputTokens?: number;

  /** Number of cache creation/write tokens. */
  cacheCreationTokens?: number;

  /** Number of cache read tokens. */
  cacheReadTokens?: number;

  /** Number of reasoning/thinking tokens. */
  reasoningTokens?: number;

  /** Total tokens as written by legacy clients. */
  totalTokens?: number;

  /** Estimated cost in USD (optional, canonical field). */
  costUsd?: number;

  /** Cost in USD (legacy field written by desktop UsageSyncService). */
  cost?: number;

  /** Parser/source confidence used to choose the best copy of a duplicate. */
  provenanceConfidence?: string;

  /** ISO 8601 timestamp of the event. */
  timestamp?: unknown;

  /** Legacy desktop event start timestamp. */
  startTime?: unknown;

  /** Legacy desktop event end timestamp. */
  endTime?: unknown;

  /** Legacy or server create timestamp. */
  createdAt?: unknown;

  /** Legacy or server update timestamp. */
  updatedAt?: unknown;

  /** Schema version. */
  schemaVersion: number;
}

// ---------------------------------------------------------------------------
// Provider adapter contract
// ---------------------------------------------------------------------------

/** Result of testing a credential against a provider endpoint. */
export interface CredentialTestResult {
  /** Whether the credential is valid and active. */
  valid: boolean;

  /** Redacted label to store in Firestore (no secrets). */
  redactedLabel: string;

  /** Credential kind inferred from the raw value. */
  credentialKind: CredentialKind;

  /** Human-readable error code if invalid. */
  errorCode?: string;

  /** Human-readable message if invalid. */
  errorMessage?: string;

  /** Warning to surface to the user (e.g. short TTL). */
  warningMessage?: string;
}

/** Result of a quota refresh against a provider. */
export interface QuotaRefreshResult {
  /** Whether the refresh succeeded. */
  ok: boolean;

  /** Snapshot document to write (only when ok === true). */
  snapshot?: Omit<QuotaSnapshotDoc, "schemaVersion" | "updatedAt">;

  /** Error code on failure. */
  errorCode?: string;

  /** Error message on failure. */
  errorMessage?: string;
}

/** Every provider adapter must satisfy this interface. */
export interface ProviderAdapter {
  readonly provider: Provider;

  /** Test a raw credential without storing it. */
  testCredential(credential: string): Promise<CredentialTestResult>;

  /** Fetch current quota using the decrypted credential. */
  fetchQuota(
    credential: string,
    sourceId: string
  ): Promise<QuotaRefreshResult>;
}

// ---------------------------------------------------------------------------
// Runtime configuration shapes
// ---------------------------------------------------------------------------

export interface EnvConfig {
  /** GCP project id. */
  projectId: string;

  /** KMS key name for envelope encryption (projects/…/locations/…/keyRings/…/cryptoKeys/…). */
  kmsKeyName: string;

  /** Firebase app check enforcement (default true). */
  enforceAppCheck: boolean;

  /** Maximum credential string length (default 8192). */
  maxCredentialLength: number;

  /** Rate-limit window in seconds for refreshProviderQuota (default 60). */
  refreshRateLimitSeconds: number;

  /** Max batch size for scheduled rollup rebuilds (default 50). */
  rollupBatchSize: number;

  /** Max batch size for scheduled quota refresh (default 20). */
  quotaRefreshBatchSize: number;

  /** StoreKit product ID that unlocks hosted quota sync. */
  hostedQuotaProductID: string;

  /** HTTPS endpoint for the paid hosted quota runner. */
  hostedQuotaRunnerURL: string;

  /** Shared bearer token used between Functions and the hosted quota runner. */
  hostedQuotaRunnerToken: string;

  /** Daily hosted-runner attempt ceiling per account. */
  hostedQuotaDailyRefreshLimit: number;

  /** Monthly hosted-runner attempt ceiling per account. */
  hostedQuotaMonthlyRefreshLimit: number;

  /** App Store verification config. */
  appStore: AppStoreConfig;
}

// ---------------------------------------------------------------------------
// App Store hosted quota entitlement docs
// ---------------------------------------------------------------------------

export type AppStoreEnvironment =
  | "Production"
  | "Sandbox"
  | "Xcode"
  | "LocalTesting";

export interface AppStoreConfig {
  bundleId: string;
  appAppleId?: number;
  environment: AppStoreEnvironment;
  enableOnlineChecks: boolean;
  autoFallbackEnvironment: boolean;
  asc: {
    issuerId: string;
    keyId: string;
    privateKeyP8: string;
  };
}

export type EntitlementOwnershipType = "PURCHASED" | "FAMILY_SHARED";

export type HostedQuotaEntitlementSource =
  | "apple_jws_verified"
  | "apple_s2s"
  | "scheduled_reconcile";

export interface HostedQuotaEntitlementDoc {
  id: string;
  active: boolean;
  productID: string;
  transactionID: string;
  originalTransactionID: string;
  expiresAt?: string;
  expireAt?: import("firebase-admin/firestore").Timestamp;
  revokedAt?: string;
  revocationReason?: number;
  environment: AppStoreEnvironment;
  ownershipType?: EntitlementOwnershipType;
  appAccountToken?: string;
  signedTransactionHash: string;
  signedDateMs?: number;
  lastNotificationUUID?: string;
  lastVerifiedAt: string;
  source: HostedQuotaEntitlementSource;
  verificationVersion: number;
  schemaVersion: number;
  updatedAt: string;
}

export interface EntitlementBindingDoc {
  id: string;
  uid: string;
  productID: string;
  clientPlatform?: "ios" | "ipados" | "macos";
  consumedAt?: string;
  createdAt: string;
  schemaVersion: number;
}

export interface EntitlementEventDoc {
  id: string;
  uid: string;
  source: "client_callable" | "apple_s2s" | "scheduled_reconcile";
  notificationType?: string;
  notificationSubtype?: string;
  transactionId: string;
  originalTransactionId: string;
  productId: string;
  environment: AppStoreEnvironment;
  expiresAt?: string;
  revokedAt?: string;
  revocationReason?: number;
  rawJWSHash: string;
  observedAt: string;
  /**
   * Firestore TTL deletion target. Configure the TTL policy on this
   * field via Console / `firebase firestore:ttls:create` to have stale
   * audit rows reaped automatically.
   */
  expireAt?: import("firebase-admin/firestore").Timestamp;
  decoded: Record<string, unknown>;
  schemaVersion: number;
}

// ---------------------------------------------------------------------------
// Firestore: insight_canvases/{id}
// Canonical schema for the Insights tab. The same shape is consumed by
// iOS (Swift Codable) and Android (Kotlin @Serializable). When making
// changes, update the schema version and run the android-firestore-worker
// skill to keep Kotlin data classes aligned.
// ---------------------------------------------------------------------------

export interface InsightCanvasDoc {
  id: string;
  title: string;
  summary?: string;
  symbolName: string;
  theme: InsightTheme;
  widgets: InsightWidgetDoc[];
  layout: InsightLayoutDoc;
  filter: InsightFilterDoc;
  modelTag?: InsightModelTagDoc;
  schemaVersion: number;
  createdAt: string;
  updatedAt: string;
  lastRefreshedAt?: string;
  origin: InsightCanvasOrigin;
  sortIndex: number;
}

export type InsightCanvasOrigin =
  | "userCreated"
  | { template: { id: string } }
  | { composed: { prompt: string } }
  | { imported: { filename: string } };

export type InsightTheme =
  | "aurora"
  | "ember"
  | "mercury"
  | "whimsy"
  | "mono"
  | "print";

export type InsightWidgetKind =
  | "kpiTile"
  | "timeSeriesLine"
  | "timeSeriesArea"
  | "streamGraph"
  | "barRanking"
  | "donut"
  | "treemap"
  | "heatmap"
  | "scatter"
  | "sankey"
  | "radar"
  | "cohort"
  | "funnel"
  | "quotaPulse"
  | "forecast"
  | "anomalyTable"
  | "narrative"
  | "recommendation"
  | "useCaseCluster"
  | "agentFocusMatrix"
  | "modelFocusMatrix"
  | "drilldownList"
  | "mermaid"
  | "ascii"
  | "composed"
  | "error";

export type InsightFreshness =
  | "fresh"
  | "stale"
  | "computing"
  | "error"
  | "locked";

export type InsightEgressTier =
  | "localOnly"
  | "userKey"
  | "userRelay"
  | "hosted";

export interface InsightWidgetDoc {
  id: string;
  kind: InsightWidgetKind;
  title: string;
  subtitle?: string;
  spec: InsightWidgetSpecDoc;
  dataBinding: InsightDataBindingDoc;
  data?: InsightWidgetDataDoc;
  filter?: InsightFilterDoc;
  freshness: InsightFreshness;
  modelTag?: InsightModelTagDoc;
  lockedAt?: string;
  lastComputedAt?: string;
  schemaVersion: number;
  rationale?: string;
}

export type InsightWidgetSpecDoc =
  | { kpiTile: InsightKPITileSpecDoc }
  | { timeSeries: InsightTimeSeriesSpecDoc }
  | { ranking: InsightRankingSpecDoc }
  | { distribution: InsightDistributionSpecDoc }
  | { heatmap: InsightHeatmapSpecDoc }
  | { scatter: InsightScatterSpecDoc }
  | { sankey: InsightSankeySpecDoc }
  | { radar: InsightRadarSpecDoc }
  | { cohort: InsightCohortSpecDoc }
  | { funnel: InsightFunnelSpecDoc }
  | { quotaPulse: InsightQuotaPulseSpecDoc }
  | { forecast: InsightForecastSpecDoc }
  | { anomalyTable: InsightAnomalyTableSpecDoc }
  | { narrative: InsightNarrativeSpecDoc }
  | { recommendation: InsightRecommendationSpecDoc }
  | { useCaseCluster: InsightUseCaseClusterSpecDoc }
  | { agentFocusMatrix: InsightFocusMatrixSpecDoc }
  | { modelFocusMatrix: InsightFocusMatrixSpecDoc }
  | { drilldownList: InsightDrilldownSpecDoc }
  | { mermaid: InsightMermaidSpecDoc }
  | { ascii: InsightASCIISpecDoc }
  | { composed: InsightComposedSpecDoc }
  | { error: InsightErrorSpecDoc };

export interface InsightKPITileSpecDoc {
  metricLabel: string;
  compareWindow: "none" | "previousPeriod" | "weekOverWeek" | "monthOverMonth" | "yearOverYear";
  emphasizeDelta: boolean;
}

export interface InsightTimeSeriesSpecDoc {
  style: "line" | "area" | "stackedArea" | "stream" | "bar" | "stackedBar";
  smoothing: "none" | "monotone" | "rolling7";
  showAnnotations: boolean;
}

export interface InsightRankingSpecDoc {
  orientation: "horizontal" | "vertical";
  showValues: boolean;
}

export interface InsightDistributionSpecDoc {
  style: "donut" | "pie" | "treemap";
  showLegend: boolean;
}

export interface InsightHeatmapSpecDoc {
  palette: "ember" | "mercury" | "whimsy" | "mono";
}

export interface InsightScatterSpecDoc {
  logX: boolean;
  logY: boolean;
  bubble: boolean;
}

export interface InsightSankeySpecDoc {}
export interface InsightRadarSpecDoc {
  fill: boolean;
}

export interface InsightCohortSpecDoc {}
export interface InsightFunnelSpecDoc {}

export interface InsightQuotaPulseSpecDoc {
  compact: boolean;
}

export interface InsightForecastSpecDoc {
  showBands: boolean;
}

export interface InsightAnomalyTableSpecDoc {
  minScore: number;
}

export interface InsightNarrativeSpecDoc {
  emphasize: "headlineOnly" | "balanced" | "deepDive";
}

export interface InsightRecommendationSpecDoc {
  category: "efficiency" | "quality" | "cost" | "quota" | "risk" | "learning";
}

export interface InsightUseCaseClusterSpecDoc {
  maxClusters: number;
}

export interface InsightFocusMatrixSpecDoc {
  palette: "ember" | "mercury" | "whimsy" | "mono";
}

export interface InsightDrilldownSpecDoc {
  groupBy?: InsightDataBindingDimension;
}

export interface InsightMermaidSpecDoc {}
export interface InsightASCIISpecDoc {}

export interface InsightComposedSpecDoc {
  children: InsightWidgetSpecDoc[];
}

export interface InsightErrorSpecDoc {
  message: string;
}

export type InsightDataBindingDoc =
  | { kpi: { metric: string; window: InsightTimeWindowDoc } }
  | { timeSeries: { metric: string; dimension?: InsightDataBindingDimension; window: InsightTimeWindowDoc } }
  | { ranking: { metric: string; dimension: InsightDataBindingDimension; limit: number; window: InsightTimeWindowDoc } }
  | { distribution: { metric: string; dimension: InsightDataBindingDimension; window: InsightTimeWindowDoc } }
  | { heatmap: { metric: string; window: InsightTimeWindowDoc } }
  | { scatter: { xMetric: string; yMetric: string; dimension: InsightDataBindingDimension; window: InsightTimeWindowDoc } }
  | { sankey: { source: InsightDataBindingDimension; mid?: InsightDataBindingDimension; target: InsightDataBindingDimension; window: InsightTimeWindowDoc } }
  | { radar: { target: InsightRadarTargetDoc; window: InsightTimeWindowDoc } }
  | { cohort: { window: InsightTimeWindowDoc } }
  | { funnel: { stages: string[]; window: InsightTimeWindowDoc } }
  | { quota: { providerKey?: string } }
  | { forecast: { metric: string; horizonDays: number } }
  | { anomaly: { window: InsightTimeWindowDoc } }
  | { useCaseClusters: { window: InsightTimeWindowDoc } }
  | { agentFocusMatrix: { window: InsightTimeWindowDoc } }
  | { modelFocusMatrix: { window: InsightTimeWindowDoc } }
  | { drilldown: { limit: number } }
  | { narrative: InsightWidgetDataNarrativeDoc }
  | { recommendation: InsightWidgetDataRecommendationDoc }
  | { mermaid: { source: string } }
  | { ascii: InsightWidgetDataASCIICardDoc }
  | { composed: InsightDataBindingDoc[] };

export type InsightDataBindingDimension =
  | "provider"
  | "model"
  | "project"
  | "device"
  | "session"
  | "file"
  | "day"
  | "hourOfDay"
  | "dayOfWeek"
  | "focus"
  | "useCase";

export type InsightRadarTargetDoc =
  | { agent: string }
  | { model: string }
  | "allAgents"
  | "allModels";

export type InsightTimeWindowDoc =
  | "today"
  | "last24h"
  | "last7d"
  | "last30d"
  | "last90d"
  | "last365d"
  | "allTime"
  | { custom: { start: string; end: string } };

export interface InsightLayoutDoc {
  columnCount: number;
  rowHeight: number;
  gap: number;
  placements: Record<string, InsightCellPlacementDoc>;
  revision: number;
}

export interface InsightCellPlacementDoc {
  column: number;
  row: number;
  colSpan: number;
  rowSpan: number;
}

export interface InsightFilterDoc {
  window: InsightTimeWindowDoc;
  providers: string[];
  models: string[];
  projects: string[];
  focuses: string[];
  useCases: string[];
  minCostUSD?: number;
  maxCostUSD?: number;
}

export interface InsightModelTagDoc {
  providerKey: string;
  modelID: string;
  displayName: string;
  egressTier: InsightEgressTier;
  stampedAt: string;
}

export interface InsightCitationDoc {
  id: string;
  kind: InsightCitationKindDoc;
  label: string;
}

export type InsightCitationKindDoc =
  | { session: { id: string; provider?: string } }
  | { model: { id: string } }
  | { agent: { provider: string } }
  | { project: { name: string } }
  | { day: { date: string } }
  | { anomaly: { id: string } }
  | { query: { text: string } }
  | { quota: { provider: string; bucket: string } };

export interface InsightTaxonomyDoc {
  focuses: string[];
  useCases: string[];
}

export type InsightValueFormat =
  | "currency"
  | "tokens"
  | "percent"
  | "duration"
  | "count"
  | "raw";

// InsightWidgetDataDoc — the full union of widget data shapes.
// Each variant matches InsightWidgetKind one-to-one.
export type InsightWidgetDataDoc =
  | { kpi: InsightWidgetDataKPIDoc }
  | { timeSeries: InsightWidgetDataTimeSeriesDoc }
  | { ranking: InsightWidgetDataRankingDoc }
  | { distribution: InsightWidgetDataDistributionDoc }
  | { heatmap: InsightWidgetDataHeatmapDoc }
  | { scatter: InsightWidgetDataScatterDoc }
  | { sankey: InsightWidgetDataSankeyDoc }
  | { radar: InsightWidgetDataRadarDoc }
  | { cohort: InsightWidgetDataCohortDoc }
  | { funnel: InsightWidgetDataFunnelDoc }
  | { quota: InsightWidgetDataQuotaStateDoc }
  | { forecast: InsightWidgetDataForecastDoc }
  | { anomaly: InsightWidgetDataAnomalyTableDoc }
  | { narrative: InsightWidgetDataNarrativeDoc }
  | { recommendation: InsightWidgetDataRecommendationDoc }
  | { useCaseCluster: InsightWidgetDataUseCaseClusterDoc }
  | { focusMatrix: InsightWidgetDataFocusMatrixDoc }
  | { drilldown: InsightWidgetDataDrilldownDoc }
  | { mermaid: string }
  | { ascii: InsightWidgetDataASCIICardDoc }
  | { composed: InsightWidgetDataDoc[] }
  | { empty: { reason: string } }
  | { error: { message: string } };

export interface InsightWidgetDataKPIDoc {
  metricLabel: string;
  value: number;
  valueFormat: InsightValueFormat;
  delta?: number;
  deltaIsPercent: boolean;
  sparkline: number[];
  contextLabel?: string;
}

export interface InsightWidgetDataTimeSeriesDoc {
  series: InsightTimeSeriesSeriesDoc[];
  xAxisLabel: string;
  yAxisLabel: string;
  yFormat: InsightValueFormat;
  annotations: InsightTimeSeriesAnnotationDoc[];
}

export interface InsightTimeSeriesSeriesDoc {
  id: string;
  name: string;
  colorHex?: string;
  points: InsightTimeSeriesPointDoc[];
}

export interface InsightTimeSeriesPointDoc {
  date: string;
  value: number;
}

export interface InsightTimeSeriesAnnotationDoc {
  date: string;
  label: string;
  tone: "positive" | "neutral" | "warning" | "negative";
}

export interface InsightWidgetDataRankingDoc {
  rows: InsightRankingRowDoc[];
  valueFormat: InsightValueFormat;
  dimensionLabel: string;
}

export interface InsightRankingRowDoc {
  id: string;
  label: string;
  value: number;
  secondaryLabel?: string;
  colorHex?: string;
}

export interface InsightWidgetDataDistributionDoc {
  slices: InsightDistributionSliceDoc[];
  valueFormat: InsightValueFormat;
  total: number;
}

export interface InsightDistributionSliceDoc {
  id: string;
  label: string;
  value: number;
  colorHex?: string;
}

export interface InsightWidgetDataHeatmapDoc {
  rowLabels: string[];
  columnLabels: string[];
  cells: number[][];
  valueFormat: InsightValueFormat;
}

export interface InsightWidgetDataScatterDoc {
  points: InsightScatterPointDoc[];
  xAxisLabel: string;
  yAxisLabel: string;
  xFormat: InsightValueFormat;
  yFormat: InsightValueFormat;
}

export interface InsightScatterPointDoc {
  id: string;
  label: string;
  x: number;
  y: number;
  size: number;
  colorHex?: string;
}

export interface InsightWidgetDataSankeyDoc {
  nodes: InsightSankeyNodeDoc[];
  links: InsightSankeyLinkDoc[];
}

export interface InsightSankeyNodeDoc {
  id: string;
  label: string;
  colorHex?: string;
}

export interface InsightSankeyLinkDoc {
  source: string;
  target: string;
  value: number;
}

export interface InsightWidgetDataRadarDoc {
  axes: string[];
  series: InsightRadarSeriesDoc[];
}

export interface InsightRadarSeriesDoc {
  id: string;
  name: string;
  values: number[];
  colorHex?: string;
}

export interface InsightWidgetDataCohortDoc {
  cohortLabels: string[];
  periodLabels: string[];
  cells: (number | null)[][];
}

export interface InsightWidgetDataFunnelDoc {
  steps: InsightFunnelStepDoc[];
}

export interface InsightFunnelStepDoc {
  id: string;
  label: string;
  count: number;
}

export interface InsightWidgetDataQuotaStateDoc {
  buckets: InsightQuotaBucketDoc[];
}

export interface InsightQuotaBucketDoc {
  id: string;
  providerLabel: string;
  bucketName: string;
  used: number;
  limit?: number;
  resetsAt?: string;
  symbolName: string;
  colorHex?: string;
}

export interface InsightWidgetDataForecastDoc {
  actual: InsightTimeSeriesPointDoc[];
  forecast: InsightTimeSeriesPointDoc[];
  lowerBound: InsightTimeSeriesPointDoc[];
  upperBound: InsightTimeSeriesPointDoc[];
  xAxisLabel: string;
  yAxisLabel: string;
  yFormat: InsightValueFormat;
  summary?: string;
}

export interface InsightWidgetDataAnomalyTableDoc {
  rows: InsightAnomalyRowDoc[];
}

export interface InsightAnomalyRowDoc {
  id: string;
  occurredAt: string;
  label: string;
  detail?: string;
  score: number;
  citations: InsightCitationDoc[];
}

export interface InsightWidgetDataNarrativeDoc {
  headline: string;
  body: string;
  bullets: string[];
  tone: "positive" | "neutral" | "warning" | "negative";
  citations: InsightCitationDoc[];
  sparkline: number[];
}

export interface InsightWidgetDataRecommendationDoc {
  headline: string;
  rationale: string;
  action: string;
  estimatedImpact?: string;
  confidence: "low" | "medium" | "high";
  citations: InsightCitationDoc[];
}

export interface InsightWidgetDataUseCaseClusterDoc {
  clusters: InsightUseCaseClusterDoc[];
}

export interface InsightUseCaseClusterDoc {
  id: string;
  label: string;
  size: number;
  exampleSessionIDs: string[];
  colorHex?: string;
}

export interface InsightWidgetDataFocusMatrixDoc {
  rowLabels: string[];
  columnLabels: string[];
  cells: number[][];
}

export interface InsightWidgetDataDrilldownDoc {
  rows: InsightDrilldownRowDoc[];
}

export interface InsightDrilldownRowDoc {
  id: string;
  title: string;
  subtitle?: string;
  occurredAt: string;
  costUSD?: number;
  tokens?: number;
  citation: InsightCitationDoc;
}

export interface InsightWidgetDataASCIICardDoc {
  headline: string;
  monoBody: string;
  caption?: string;
}

export interface InsightDigestDoc {
  contentHash: string;
  generatedAt: string;
  windowStart: string;
  windowEnd: string;
  rowCount: number;
  totals: InsightDigestTotalsDoc;
  providers: InsightDigestProviderSnapshotDoc[];
  models: InsightDigestModelSnapshotDoc[];
  projects: InsightDigestProjectSnapshotDoc[];
  devices: InsightDigestDeviceSnapshotDoc[];
  daily: InsightDigestDailyPointDoc[];
  hourly: number[];
  useCaseHistogram: InsightDigestUseCaseBinDoc[];
  agentFocusSignals: InsightDigestAgentFocusSignalDoc[];
  modelFocusSignals: InsightDigestModelFocusSignalDoc[];
  quotaSnapshots: InsightDigestQuotaSnapshotDoc[];
  operatingActions: InsightDigestActionDoc[];
  summaryRunsLog: InsightDigestSummaryRunDoc[];
  anomalies: InsightDigestAnomalyDoc[];
  glossary: InsightTaxonomyDoc;
}

export interface InsightDigestTotalsDoc {
  costUSD: number;
  totalTokens: number;
  inputTokens: number;
  outputTokens: number;
  reasoningTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  sessionCount: number;
}

export interface InsightDigestProviderSnapshotDoc {
  id: string;
  displayName: string;
  costUSD: number;
  totalTokens: number;
  sessionCount: number;
  topModels: string[];
  topInferredTaskTitles: string[];
  topKeyTools: string[];
}

export interface InsightDigestModelSnapshotDoc {
  id: string;
  providerID: string;
  costUSD: number;
  totalTokens: number;
  sessionCount: number;
  avgCostPerSession: number;
  cacheHitRate: number;
  topInferredTaskTitles: string[];
  topProjects: string[];
}

export interface InsightDigestProjectSnapshotDoc {
  id: string;
  displayName: string;
  costUSD: number;
  totalTokens: number;
  sessionCount: number;
}

export interface InsightDigestDeviceSnapshotDoc {
  id: string;
  displayName: string;
  costUSD: number;
  sessionCount: number;
}

export interface InsightDigestDailyPointDoc {
  day: string;
  costUSD: number;
  totalTokens: number;
  sessionCount: number;
  perProvider: Record<string, number>;
}

export interface InsightDigestUseCaseBinDoc {
  id: string;
  count: number;
  costUSD: number;
}

export interface InsightDigestAgentFocusSignalDoc {
  agentID: string;
  focus: string;
  weight: number;
}

export interface InsightDigestModelFocusSignalDoc {
  modelID: string;
  focus: string;
  weight: number;
}

export interface InsightDigestQuotaSnapshotDoc {
  id: string;
  providerID: string;
  bucketName: string;
  used: number;
  limit?: number;
  resetsAt?: string;
}

export interface InsightDigestActionDoc {
  id: string;
  kind: string;
  projectID?: string;
  occurredAt: string;
  summary: string;
}

export interface InsightDigestSummaryRunDoc {
  id: string;
  providerID: string;
  modelID: string;
  costUSD: number;
  ranAt: string;
}

export interface InsightDigestAnomalyDoc {
  id: string;
  occurredAt: string;
  label: string;
  score: number;
  detail?: string;
}

export type InsightAnalysisPlatformDoc =
  | "macOS"
  | "iOS"
  | "iPadOS"
  | "android";

export type InsightAnalysisInstructionDoc =
  | "defaultBrief"
  | "answerFollowUp"
  | "generateReport"
  | "updateCanvas";

export interface InsightAnalysisRequestDoc {
  id: string;
  prompt: string;
  context: InsightAnalysisContextDoc;
  currentCanvas?: InsightCanvasDoc;
  selectedModel: InsightModelTagDoc;
  instruction: InsightAnalysisInstructionDoc;
  allowDeepTranscriptAnalysis: boolean;
  maxGeneratedWidgets: number;
  schemaVersion: 1;
}

export interface InsightAnalysisContextDoc {
  digest: InsightDigestDoc;
  evidenceIndex: InsightEvidenceDoc[];
  budgetReport: InsightContextBudgetReportDoc;
  priorRunSummaries: string[];
  evidencePacks: InsightEvidencePackDoc[];
}

export interface InsightEvidenceDoc {
  id: string;
  citation: InsightCitationDoc;
  source: string;
  summary: string;
  numericValue?: number;
}

export interface InsightEvidencePackDoc {
  id: string;
  sourcePlatform: InsightAnalysisPlatformDoc;
  generatedAt: string;
  timeWindow: InsightTimeWindowDoc;
  includedDataSources: string[];
  budgetReport: InsightContextBudgetReportDoc;
  evidence: InsightEvidenceDoc[];
  summary: string;
  contentHash: string;
  deepTranscriptIncluded: boolean;
}

export interface InsightPlatformCapabilityReportDoc {
  platform: InsightAnalysisPlatformDoc;
  providerFamilies: InsightProviderFamilyDoc[];
  includedDataSources: string[];
  supportsDeepLocalLogs: boolean;
  supportsSyncedEvidencePacks: boolean;
  supportsModelSelection: boolean;
  supportsConversation: boolean;
  supportsGeneratedWidgetPinning: boolean;
  supportsAuditAndCache: boolean;
  gaps: string[];
}

export type InsightProviderFamilyDoc =
  | "codex"
  | "claude"
  | "minimax"
  | "zai"
  | "kimi"
  | "ollama"
  | "hermes"
  | "openai"
  | "pi"
  | "openrouter"
  | "local-rules"
  | "other";

export interface InsightContextBudgetReportDoc {
  maxEncodedBytes: number;
  encodedBytes: number;
  estimatedPromptTokens: number;
  includedDataSources: string[];
  truncatedDataSources: string[];
  truncationSummary: string;
}

export interface InsightAnalysisResultDoc {
  id: string;
  requestID: string;
  schemaVersion: 1;
  generatedAt: string;
  platform: InsightAnalysisPlatformDoc;
  timeWindow: InsightTimeWindowDoc;
  executiveSummary: string;
  modelTag: InsightModelTagDoc;
  contextBudget: InsightContextBudgetReportDoc;
  findings: InsightFindingDoc[];
  anomalies: InsightAnomalyDoc[];
  recommendations: InsightRecommendationDoc[];
  generatedWidgets: InsightGeneratedWidgetDoc[];
  followUpQuestions: InsightFollowUpQuestionDoc[];
  citations: InsightCitationDoc[];
  tokenUsage?: InsightTokenUsageDoc;
  estimatedCostUSD?: number;
  auditID?: string;
  resultHash: string;
}

export type InsightConfidenceDoc = "low" | "medium" | "high";

export type InsightSeverityDoc =
  | "info"
  | "low"
  | "medium"
  | "high"
  | "critical";

export interface InsightFindingDoc {
  id: string;
  title: string;
  whyItMatters: string;
  evidence: InsightCitationDoc[];
  confidence: InsightConfidenceDoc;
  severity: InsightSeverityDoc;
  recommendedAction: string;
  generatedWidgetID?: string;
}

export interface InsightAnomalyDoc {
  id: string;
  title: string;
  occurredAt?: string;
  detail: string;
  score: number;
  evidence: InsightCitationDoc[];
  confidence: InsightConfidenceDoc;
}

export interface InsightRecommendationDoc {
  id: string;
  title: string;
  rationale: string;
  recommendedAction: string;
  estimatedImpact?: string;
  evidence: InsightCitationDoc[];
  confidence: InsightConfidenceDoc;
  severity: InsightSeverityDoc;
}

export interface InsightGeneratedWidgetDoc {
  id: string;
  widget: InsightWidgetDoc;
  reason: string;
  citations: InsightCitationDoc[];
}

export interface InsightFollowUpQuestionDoc {
  id: string;
  question: string;
  rationale?: string;
}

export interface InsightAnalysisAuditEntryDoc {
  id: string;
  requestID: string;
  platform: InsightAnalysisPlatformDoc;
  selectedModel: InsightModelTagDoc;
  egressTier: InsightEgressTier;
  timeWindow: InsightTimeWindowDoc;
  contextBudget: InsightContextBudgetReportDoc;
  includedDataSources: string[];
  truncationSummary: string;
  promptHash: string;
  resultHash: string;
  status:
    | "started"
    | "succeeded"
    | "partial"
    | "modelUnavailable"
    | "schemaViolation"
    | "cancelled"
    | "failed";
  startedAt: string;
  completedAt?: string;
  errorDescription?: string;
  tokenUsage?: InsightTokenUsageDoc;
  estimatedCostUSD?: number;
  ranAt: string;
}

export interface InsightModelPreferenceDoc {
  mode: "automatic" | "explicit";
  explicitModel?: InsightModelTagDoc;
  restrictToLocalOnly: boolean;
  maxEgressTier?: InsightEgressTier;
  deepTranscriptOptIn: boolean;
}

export interface InsightTokenUsageDoc {
  providerKey: string;
  modelID: string;
  inputTokens: number;
  outputTokens: number;
  reasoningTokens: number;
  cacheCreationTokens: number;
  cacheReadTokens: number;
  estimatedCostUSD: number;
  startedAt: string;
  completedAt: string;
}

export interface InsightInvestigateRequestDoc {
  prompt: string;
  digest: InsightDigestDoc;
  canvas?: InsightCanvasDoc;
  widget?: InsightWidgetDoc;
  modelTag: InsightModelTagDoc;
  capabilityTier: "tier1" | "tier2" | "tier3";
  maxNewWidgets: number;
  allowToolCalls: boolean;
  instruction: "composeCanvas" | "refineCanvas" | "refreshNarratives" | "refineWidget" | "explainBriefly";
}

export type InsightInvestigateEventDoc =
  | { thinkingDelta: string }
  | { partialCanvas: InsightCanvasDoc }
  | { widgetReady: InsightWidgetDoc }
  | { toolCall: InsightToolCallDoc }
  | { toolResult: InsightToolResultDoc }
  | { usage: InsightTokenUsageDoc }
  | { finalCanvas: InsightCanvasDoc };

export interface InsightToolCallDoc {
  id: string;
  name: string;
  arguments: InsightToolArgumentsDoc;
}

export interface InsightToolResultDoc {
  id: string;
  toolName: string;
  isError: boolean;
  summary: string;
  payload: InsightToolResultPayloadDoc;
}

export type InsightToolArgumentsDoc =
  | { drilldownSearch: { query: string; filter?: InsightFilterDoc } }
  | { drilldownSession: { sessionID: string } }
  | { agentUsage: { agent: string; window: InsightTimeWindowDoc } }
  | { modelUsage: { modelID: string; window: InsightTimeWindowDoc } }
  | { operatingActions: { window: InsightTimeWindowDoc } }
  | { quotaSnapshot: { providerKey?: string } }
  | { anomalyDetail: { anomalyID: string } }
  | "listFocuses"
  | "listUseCases";

export type InsightToolResultPayloadDoc =
  | { sessions: InsightDrilldownRowDoc[] }
  | { timeSeries: InsightWidgetDataTimeSeriesDoc }
  | { ranking: InsightWidgetDataRankingDoc }
  | { actions: InsightDigestActionDoc[] }
  | { quota: InsightWidgetDataQuotaStateDoc }
  | { anomaly: InsightAnomalyRowDoc }
  | { vocabulary: string[] }
  | { error: string };

export interface InsightCapabilityTierDoc {
  tier: number;
  structuredOutput: boolean;
  maxTokens: number;
}
