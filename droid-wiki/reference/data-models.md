# Data models

Canonical schema lives in `functions/src/types/legacy.ts` (legacy hand-maintained) and is migrating to TypeSpec emitters in `tools/schema-sync/`. Every platform must match it. Run `./tools/schema-sync/check-drift.sh` before changing shared models.

## Firestore collections (canonical schema)

### `users/{uid}/usage/{doc}` — `UsageEventDoc`

Per-event token usage written by the daemon after each agent turn.

| Field | Type | Description |
|-------|------|-------------|
| `provider` | `Provider` | Provider key (e.g. `claude-code`, `openai`, `kimi`) |
| `providerID` | `ProviderID` | Canonical provider account namespace |
| `providerAccountID` | string | Optional account attribution |
| `providerAccountLabel` | string | Denormalized label at ingestion time |
| `providerAccountSource` | `ProviderAccountStorageScope` | Storage/source class |
| `model` | string | Model identifier |
| `sessionId` | string | Agent session identifier |
| `deviceId` | string | Device that originated the request |
| `sourceDeviceId` | string | Source device for synced records |
| `inputTokens` | number | Prompt tokens |
| `outputTokens` | number | Completion tokens |
| `cacheCreationTokens` | number | Cache write tokens |
| `cacheReadTokens` | number | Cache-read tokens |
| `reasoningTokens` | number | Reasoning/thinking tokens |
| `totalTokens` | number | Legacy total tokens |
| `costUsd` | number | Estimated cost in USD (canonical) |
| `cost` | number | Legacy cost in USD |
| `provenanceConfidence` | string | Parser/source confidence for duplicate resolution |
| `timestamp` | Timestamp / string | Event timestamp |
| `schemaVersion` | number | Forward-compat version |

**Android:** `data class TokenUsage` in `android/app/src/main/java/com/openburnbar/data/models/TokenUsage.kt` mirrors every field with `@PropertyName` annotations. Effective cost uses `costUsd` with fallback to `cost`.

**iOS/macOS:** The daemon writes these into the local SQLite `usage` table via GRDB; `UsageSyncService` mirrors them to Firestore.

---

### `users/{uid}/usage_rollups/{window}` — `UsageRollupDoc`

Cloud Functions writes **five separate documents** (`today`, `7d`, `30d`, `90d`, `all_time`). Android's `mergeWindowDocs()` reads all five and merges them into a single flat `UsageRollups` client model.

| Field | Type | Description |
|-------|------|-------------|
| `totals` | `Record<string, number>` | Aggregated totals keyed by metric name |
| `providerSummaries` | `ProviderSummary[]` | Per-provider cost + tokens |
| `accountSummaries` | `ProviderAccountSummary[]` | Per-account cost + tokens |
| `modelSummaries` | `ModelSummary[]` | Per-model cost + tokens |
| `deviceSummaries` | `DeviceSummary[]` | Per-device cost + tokens |
| `dailyPoints` | `Record<string, number>` | Sparse daily points for sparklines (`YYYY-MM-DD`) |
| `computedAt` | string | ISO 8601 timestamp of last computation |
| `schemaVersion` | number | Forward-compat version |

**Android:** `data class UsageRollups` + `RollupSummary` in `TokenUsage.kt`.

---

### `users/{uid}/quota_snapshots/{provider}_{sourceId}` — `QuotaSnapshotDoc`

| Field | Type | Description |
|-------|------|-------------|
| `sourceKind` | `"provider"` | Source kind |
| `sourceId` | string | Account or API key identifier |
| `provider` | `Provider` | Provider key |
| `providerID` | `ProviderID` | Canonical provider catalog key |
| `accountID` | string | Provider account this snapshot belongs to |
| `accountLabel` | string | Denormalized label at fetch time |
| `accountStorageScope` | `ProviderAccountStorageScope` | Storage scope of the source account |
| `fetchedAt` | string | ISO 8601 timestamp when fetched |
| `source` | string | Human-readable source label |
| `confidence` | `"high" | "medium" | "low" | "stale"` | Snapshot confidence |
| `managementURL` | string | Deep-link to provider management page |
| `statusMessage` | string | Free-form status message |
| `buckets` | `QuotaBucket[]` | Quota windows |
| `updatedAt` | string | ISO 8601 timestamp of last update |
| `schemaVersion` | number | Forward-compat version |

**QuotaBucket fields:** `name`, `used`, `limit`, `remaining`, `window`, `resetsAt`, `meta`.

**Android:** `data class ProviderQuotaSnapshot` + `data class QuotaBucket` in `TokenUsage.kt`. Computed properties include `quotaRemaining`, `quotaLimit`, and `percentageRemaining`.

---

### `users/{uid}/provider_accounts/{accountId}` — `ProviderAccountDoc`

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Stable account ID unique within a user namespace |
| `providerID` | `ProviderID` | Canonical provider key |
| `label` | string | User-visible account label |
| `identityHint` | string | Non-secret identity hint (email/org/team) |
| `status` | `ProviderAccountStatus` | `connected`, `disconnected`, `stale`, `error`, `disabled`, `deleted` |
| `credentialKind` | `CredentialKind` | `token`, `bearer`, `session`, `cookie`, `plan` |
| `storageScope` | `ProviderAccountStorageScope` | `cloud_refreshable`, `local_only`, `device_keychain`, `server_private` |
| `redactedLabel` | string | Redacted display label only |
| `sourceDeviceID` | string | Device that owns a local-only credential |
| `linkedSwitcherProfileID` | string | Switcher/browser/CLI profile linkage |
| `isDefault` | boolean | Default account flag |
| `sortKey` | number | Display sort order |
| `lastValidatedAt` | string | ISO 8601 timestamp of last validation |
| `lastRefreshAt` | string | ISO 8601 timestamp of last quota refresh |
| `lastErrorCode` | string | Last known error code |
| `endpointProfileID` | string | Multi-host endpoint profile |
| `region` | `"cn" | "sgp" | "ams" | "global"` | Regional cluster |
| `tokenPlanTier` | `"lite" | "standard" | "pro" | "max"` | Token Plan tier |
| `tokenPlanBillingCycle` | `"monthly" | "annual"` | Billing cycle |
| `authMethodID` | string | Auth wizard method id |
| `schemaVersion` | number | Forward-compat version |
| `createdAt` / `updatedAt` | string | Timestamps |

**Android:** `data class ProviderAccount` in `TokenUsage.kt` with `@IgnoreExtraProperties` and live-data extra fields (`usage_limit`, `usage_used`, `integration`, etc.).

---

### Chat — `ChatMessageRecord` and `ChatThreadSummary`

**`ChatMessageRecord`** (`AgentLens/Models/ConversationRecord.swift`)

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | UUID |
| `role` | `ChatMessageRole` | `user`, `assistant`, `system` |
| `content` | string | Message text (mutable for streaming hot path) |
| `timestamp` | Date | Message time |
| `cliUsed` | string | CLI bridge identifier (e.g. `codex`, `claude`) |
| `transcriptPieces` | `ChatTranscriptPiece[]` | Ordered segments for assistant messages (text + tool calls) |
| `attachments` | `HermesAttachment[]` | User-attached files |

**`ChatThreadSummary`** (same file)

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Thread UUID |
| `title` | string | Display title |
| `lastMessageAt` | Date | Most recent message timestamp |
| `messageCount` | Int | Total messages in thread |

Both are persisted to local SQLite (`chat_messages`, `chat_threads`) and optionally synced to Firestore via `ChatThreadSyncService`.

---

### Mission Control — `BurnBarMissionStatus` and `BurnBarRunStateSnapshot`

**`BurnBarMissionStatus`** (`OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarRPCContracts.swift`)

Lifecycle states: `draft`, `pending`, `queued`, `running`, `paused`, `completed`, `failed`, `cancelled`, `approved`, `rejected`.

Terminal statuses: `completed`, `failed`, `cancelled`, `rejected`.

**`BurnBarRunStateSnapshot`** (Mission Control internals)

Captured by `MissionControlMissionStateMerger` to reconcile mission status from run results. Fields include `status`, `resultDetail`, `prLinkage`, `burnRecords`, and `eventLog`.

---

### Local SQLite / GRDB tables

Managed by `OpenBurnBarDatabase` in `OpenBurnBarCore`. All I/O goes through GRDB's actor-safe `DatabaseQueue`. The database is encrypted with SQLCipher; the key lives in the macOS Keychain.

| Table | Purpose |
|-------|---------|
| `usage` | Per-event token usage (mirrors `UsageEventDoc`) |
| `usage_rollups` | Aggregated windows (local cache of Firestore rollups) |
| `conversations` | Session log metadata (title, path, provider, timestamps) |
| `chat_messages` | In-app chat transcript |
| `chat_threads` | Chat thread metadata |
| `search_documents` | Full-text search document index |
| `search_chunks` | Retrieval chunks linked to conversations |
| `search_chunks_fts` | FTS5 virtual table over `search_chunks` |
| `chunk_embeddings` | Vector embeddings for semantic search |
| `source_artifacts` | Skill docs and agent docs for retrieval |
| `projection_jobs` | Queue for background projection/embedding tasks |
| `retrieval_health` | Health status per retrieval subsystem |
| `budget_ledger` | Running cost ledger for budget enforcement |
| `budget_rules` | Per-provider budget rules (soft/hard caps, daily limits) |
| `budget_enforcement` | Enforcement events log |
| `shared_artifact_sync_state` | Cloud sync state for shared artifacts |
| `shared_artifact_permissions` | Permission records for shared artifacts |
| `shared_artifact_audit_events` | Audit trail for artifact access |

---

### Search / Retrieval — `SearchDocumentRecord` and `SearchChunkRecord`

**`SearchDocumentRecord`** (`AgentLens/Services/DataStore/DataStoreTypes.swift`)

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | UUID |
| `sourceKind` | `SearchSourceKind` | `conversation`, `skill_doc`, `agent_doc`, `shared_artifact` |
| `sourceID` | string | Original source identifier |
| `sourceVersionID` | string | Version identifier for rekeying |
| `provider` | string | Provider key |
| `projectName` | string | Project context |
| `title` | string | Document title |
| `subtitle` | string | Optional subtitle |
| `bodyPreview` | string | Preview snippet |
| `contentHash` | string | Content hash for deduplication |

**`SearchChunkRecord`** (same file)

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | UUID |
| `documentID` | string | Parent `SearchDocumentRecord` id |
| `ordinal` | int | Chunk order within document |
| `startOffset` / `endOffset` | int | Byte offsets |
| `text` | string | Chunk text content |
| `contentHash` | string | Hash for stable-identity diffing |

---

### Shared Artifacts — `SharedArtifactCloudRecord`

**`SharedArtifactCloudRecord`** (`AgentLens/Services/CloudSyncSharedArtifactModels.swift`)

Represents a collaborative artifact that can be shared across devices and users via Firestore.

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Artifact UUID |
| `title` | string | Display title |
| `content` | string | Sealed/encrypted content |
| `ownerUserID` | string | Firebase UID of the owner |
| `scope` | `SharedArtifactScope` | `personal`, `team`, `public` |
| `createdAt` / `updatedAt` | Date | Timestamps |
| `schemaVersion` | int | Forward-compat version |

Related records in local SQLite: `SharedArtifactSyncStateRecord`, `SharedArtifactPermissionRecord`, `SharedArtifactAuditEventRecord`.

---

### Provider identity — `AgentProvider`

**`AgentProvider`** (`AgentLens/Models/AgentProvider.swift` and `OpenBurnBarCore`)

Core enum across the entire codebase. Values include: `anthropic`, `openai`, `google`, `cohere`, `mistral`, `ollama`, `codex`, `claudeCode`, `cursor`, `factory`, `grok`, `kimi`, `minimax`, `xai`, `zai`, `pi`, `hermes`.

Used for: provider routing, quota adapters, usage aggregation, theme colors, logo selection, and retrieval source tagging.

---

## Schema migration

- **Legacy canonical:** `functions/src/types/legacy.ts` — hand-maintained, used by Cloud Functions runtime.
- **Migration target:** `tools/schema-sync/` — TypeSpec sources that emit TypeScript, Swift, and Kotlin bindings.
- **Drift check:** `./tools/schema-sync/check-drift.sh` compares generated emitters against hand-maintained types.
- **Android alignment:** The `android-firestore-worker` skill auto-aligns Kotlin data classes when TypeSpec emitters change.

## Related pages

- [Configuration](configuration.md) — environment variables and settings that drive model behavior
- [RPC surface](rpc-surface.md) — methods that read and write these models
- [Dependencies](dependencies.md) — GRDB, Firebase, and serialization libraries that persist these models
