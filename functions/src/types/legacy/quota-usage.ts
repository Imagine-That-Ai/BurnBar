/**
 * @fileoverview Shared TypeScript types for OpenBurnBar Cloud Functions v2.
 *
 * Extracted from src/types/legacy.ts (the strangler "leftovers" bucket) and
 * grouped by domain. Re-exported verbatim from src/types/legacy.ts so every
 * existing `import ... from "../types/legacy"` keeps resolving unchanged.
 */

import type { Provider, ProviderAccountStorageScope, ProviderID } from "./providers.js";

// ---------------------------------------------------------------------------
// Firestore: quota_snapshots/{provider}_{sourceId}
// ---------------------------------------------------------------------------

export type QuotaBucket = import("../generated/usage-quota.js").QuotaBucket & {
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
};

export type QuotaSnapshotDoc = Omit<
  import("../generated/usage-quota.js").QuotaSnapshotDoc,
  "sourceKind" | "provider" | "providerID" | "accountStorageScope"
> & {
  sourceKind: "provider";
  provider: Provider;
  providerID?: ProviderID;
  accountStorageScope?: ProviderAccountStorageScope;
  /** Human-readable source label. */
  source: string;

  /** Schema-sync alias for {@link source}. */
  sourceLabel?: string;

  /** ISO 8601 next reset for the snapshot (schema-sync canon). */
  resetAt?: string;

  /** Provider plan tier at fetch time (schema-sync canon). */
  planTier?: string;

  /** Confidence level: "high" | "medium" | "low" | "stale". */
  confidence: "high" | "medium" | "low" | "stale";

  /** Deep-link to provider management page, when known. */
  managementURL?: string;

  /** Free-form status message from the provider or from our adapters. */
  statusMessage?: string;

  /** Quota buckets. */
  buckets?: QuotaBucket[];

  /** Schema version. */
  schemaVersion: number;

  /** ISO 8601 timestamp of last document update. */
  updatedAt: string;
};

// ---------------------------------------------------------------------------
// Firestore: users/{uid}/project_memory_snapshots/{docID}
//
// Keyed by an opaque vault-key-derived docID (no longer the plaintext slug);
// see ProjectMemorySnapshotDoc below.
// ---------------------------------------------------------------------------

export type ProjectMemoryFreshness = "fresh" | "needsRefresh" | "stale";

export interface CloudVaultBlobEnvelopeDoc {
  schemaVersion: number;
  algorithm: "AES-256-GCM";
  keyVersion: number;
  plaintextSHA256?: string;
  plaintextHMAC?: string;
  integrityHashVersion?: number;
  sealedBoxBase64: string;
  createdAt: string;
  aad?: string;
}

export interface CloudVaultSealedTextDoc {
  schemaVersion?: number;
  algorithm: "AES-256-GCM";
  keyVersion: number;
  nonce: string;
  ciphertext: string;
  tag: string;
  aad?: string;
}

// ---------------------------------------------------------------------------
// Firestore: users/{uid}/session_logs/{deviceId}_{escapedId}
//
// Encrypted conversation backup manifest. The conversation body is sealed in
// Cloud Storage (`bodyStorage === "firebase_storage_encrypted"`); only metadata
// lives in Firestore. The plaintext "cockpit facets" below are deliberately
// content-free (counters, cost, timing, working directory, generic tool tags)
// so the Streams cockpit can filter/sort/aggregate without ever decrypting.
// ---------------------------------------------------------------------------

/** Generation of the plaintext cockpit facet block; bump triggers a client backfill. */
export const CONVERSATION_FACET_SCHEMA_VERSION = 1;

/** Content-free facets attached to a session-log manifest for cockpit querying. */
export interface ConversationCockpitFacetsDoc {
  facetSchemaVersion: number;
  model: string;
  messageCount: number;
  userWordCount: number;
  assistantWordCount: number;
  inputTokens: number;
  outputTokens: number;
  cacheCreationTokens: number;
  cacheReadTokens: number;
  totalTokens: number;
  costUSD: number;
  /** Absolute working directory of the session, when known. */
  workingDirectory?: string;
  /** Generic tool names used (e.g. "bash", "edit"); never key files or commands. */
  toolTags?: string[];
  /** Wall-clock session duration in seconds, when both endpoints are known. */
  durationSeconds?: number;
}

export interface SessionLogManifestDoc extends ConversationCockpitFacetsDoc {
  id: string;
  deviceId: string;
  provider: string;
  sessionId: string;
  sourceType: string;
  projectName: string;
  inferredTaskTitle: string;
  bodyStorage: "firebase_storage_encrypted";
  storagePath: string;
  sealedTitle: CloudVaultSealedTextDoc;
  sealedBodyPreview: CloudVaultSealedTextDoc;
  encryption: {
    algorithm: string;
    keyVersion: number;
    tokenHashVersion: number;
    semanticHashVersion: number;
  };
  chunkCount: number;
  searchChunkCount: number;
  byteCount: number;
  encryptedByteCount: number;
  bodyHash: string;
  chunkHashes: string[];
  chunkMetadataVersion: number;
  cloudSearchIndexVersion: number;
  cloudSearchIndexedAt: import("firebase-admin/firestore").Timestamp | string;
  startTime?: import("firebase-admin/firestore").Timestamp | string;
  endTime?: import("firebase-admin/firestore").Timestamp | string;
  updatedAt: import("firebase-admin/firestore").Timestamp | string;
}

export type TextExpansionModeDoc = "static" | "llm_rewrite";

// ---------------------------------------------------------------------------
// Firestore: users/{uid}/text_snippets/{snippetID}
// ---------------------------------------------------------------------------

export interface TextExpansionSnippetDoc {
  id: string;
  uid: string;
  sourceDeviceID: string;
  triggerHash: string;
  sealedTitle: CloudVaultSealedTextDoc;
  sealedTrigger: CloudVaultSealedTextDoc;
  sealedBody: CloudVaultSealedTextDoc;
  sealedScope: CloudVaultSealedTextDoc;
  mode: TextExpansionModeDoc;
  isEnabled: boolean;
  revision: number;
  createdAt: import("firebase-admin/firestore").Timestamp | string | number;
  updatedAt: import("firebase-admin/firestore").Timestamp | string | number;
  deletedAt?: import("firebase-admin/firestore").Timestamp | string | number | null;
  encryption: {
    algorithm: "AES-256-GCM";
    keyVersion: number;
    tokenHashVersion: number;
  };
  schemaVersion: number;
}

/**
 * project_memory_snapshots/{docID}
 *
 * SEAL + OPAQUE DOC ID (privacy-leak-remediation-2026-06-02 §2). The human-
 * readable `projectSlug`/`projectDisplayName` are NO LONGER persisted in the
 * clear — both already live inside the sealed `sealedSnapshot` blob, and the doc
 * is now keyed by an opaque, deterministic `docID` the device derives from the
 * slug under the vault key (`projectMemoryDocID`, see CloudVaultCrypto). The
 * server never learns the project's name. `schemaVersion` 2 fences the new
 * sealed-only rows from the legacy plaintext-keyed rows.
 */
export interface ProjectMemorySnapshotDoc {
  /** Opaque, vault-key-derived deterministic doc id (mirrors the Firestore key). */
  docID?: string;
  contentHash: string;
  contentHashVersion?: number;
  sourceSessionCount: number;
  sourceConversationCount: number;
  generatedAt: string;
  freshness: ProjectMemoryFreshness;
  visualKinds: string[];
  sealedSnapshot: CloudVaultBlobEnvelopeDoc;
  encryption: {
    algorithm: string;
    keyVersion: number;
    envelopeSchemaVersion: number;
  };
  schemaVersion: number;
  updatedAt: string;
}

// ---------------------------------------------------------------------------
// Firestore: users/{uid}/knowledge_repos/{repoId}
//
// Pensieve repo connector (privacy-leak-remediation-2026-06-02 §4). The
// cleartext `repoFullName` is NO LONGER stored: a GitHub-push webhook (no vault
// key, no user context) can only equality-MATCH the incoming repo, never needs
// the name back, so the row carries a SERVER-keyed `repoMatchToken =
// HMAC_SHA256(KNOWLEDGE_REPO_MATCH_KEY, normalize(full_name))` the webhook
// recomputes from the GitHub-signed payload. Webhook routing additionally uses
// `repoInstallationMatchToken`, which binds that repo token to the GitHub App
// installation id that the server verified during registration. The user-visible
// display name lives only in `sealedRepoFullName`, sealed by the authed web
// client with the vault key and decrypted client-side. `repoId` is derived from
// the opaque token, not the name.
// ---------------------------------------------------------------------------

export interface KnowledgeRepoDoc {
  uid: string;
  repoId: string;
  repoMatchToken: string;
  repoInstallationMatchToken: string;
  sealedRepoFullName?: CloudVaultSealedTextDoc;
  sourceManifestId?: string;
  sourceSlug?: string;
  installId?: string;
  connectedAt: import("firebase-admin/firestore").Timestamp | string;
  schemaVersion: number;
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

export type ModelBenchmarkFreshness = "fresh" | "stale" | "unavailable" | "cached" | "manual";

export type ModelBenchmarkSnapshotDoc = Omit<
  import("../generated/model-benchmarks.js").ModelBenchmarkSnapshotDoc,
  "source" | "taskCategory" | "freshness" | "providerID"
> & {
  source: ModelBenchmarkSource;
  providerID?: ProviderID;
  taskCategory: ModelBenchmarkTaskCategory;
  freshness: ModelBenchmarkFreshness;
};

export type ModelBenchmarkSourceStatusDoc = Omit<
  import("../generated/model-benchmarks.js").ModelBenchmarkSourceStatusDoc,
  "source" | "status"
> & {
  source: ModelBenchmarkSource;
  status: "fresh" | "stale" | "unavailable" | "error";
};

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

export interface ExecutionSourceSummary {
  sourceId: string;
  sourceName: string;
  totalRequests: number;
  totalTokens: number;
  totalCost: number;
}

export interface ComboSummary {
  sourceId: string;
  sourceName: string;
  provider: Provider;
  model: string;
  requests: number;
  tokens: number;
  cost: number;
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

  /** Per-execution-source (agent harness) summaries. Missing on legacy docs. */
  executionSourceSummaries?: ExecutionSourceSummary[];

  /** Per-execution-source × model combo summaries. Missing on legacy docs. */
  comboSummaries?: ComboSummary[];

  /** Sparse daily points for sparkline rendering: YYYY-MM-DD -> value. */
  dailyPoints: Record<string, number>;

  /** Sparse per-day per-provider token split: YYYY-MM-DD -> providerID -> value. All_time only; missing on legacy docs. */
  dailyProviderTokens?: Record<string, Record<string, number>>;

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
  executionSourceId?: string;
  executionSourceName?: string;
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

  /**
   * Random nonce rotated when a capped delta drain intentionally leaves this
   * job dirty for a later scheduler pass. This is part of Cloud Task identity;
   * it does not affect stale dirty-epoch validation.
   */
  requeueNonce?: string;

  /** Error code from the most recent failed rollup run. */
  lastErrorCode?: string;

  /** Consecutive failures on the raw-usage full rebuild repair path. */
  consecutiveFullRebuildFailures?: number;

  /** ISO 8601 time until which the full rebuild repair path is paused. */
  fullRebuildCircuitOpenUntil?: string;

  /**
   * ISO 8601 start time of a full rebuild attempt, written transactionally
   * BEFORE the destructive work begins and cleared on the success/failure
   * paths. A leftover stale marker means the attempt was killed (timeout/OOM)
   * and counts as a consecutive failure on the next pass.
   */
  fullRebuildAttemptInFlightAt?: string;

  /** ISO 8601 time of the last client `force` full rebuild (cooldown anchor). */
  lastForceRebuildAt?: string;
}

// ---------------------------------------------------------------------------
// Firestore: users/{uid}/usage/{usageDoc}
// ---------------------------------------------------------------------------

export type UsageEventDoc = Omit<
  import("../generated/usage-quota.js").UsageEventDoc,
  "provider" | "providerID" | "providerAccountSource"
> & {
  provider: Provider;
  providerID?: ProviderID;
  providerAccountSource?: ProviderAccountStorageScope;
  sealedProjectName?: CloudVaultSealedTextDoc;
  projectKeyHash?: string;
  cacheCreationTokens?: number;
  reasoningTokens?: number;
  costUsd?: number;
  cost?: number;
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
};
