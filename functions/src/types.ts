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
