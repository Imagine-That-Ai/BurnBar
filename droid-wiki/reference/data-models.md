# Data models

Canonical schema lives in `functions/src/types/legacy.ts`. Every platform must match it. Run `./tools/schema-sync/check-drift.sh` before changing shared models.

## Firestore collections

### `users/{uid}/usage/{doc}` — UsageEventDoc

Per-event token usage written by the daemon after each agent turn.

| Field | Type | Description |
|-------|------|-------------|
| `provider` | string | Provider ID (e.g. `anthropic`, `openai`) |
| `model` | string | Model name |
| `inputTokens` | number | Prompt tokens |
| `outputTokens` | number | Completion tokens |
| `cacheTokens` | number | Cache-read tokens (Anthropic prompt caching) |
| `cost` | number | Computed cost in USD |
| `sessionId` | string | Agent session identifier |
| `timestamp` | Timestamp | Firestore server timestamp |

### `users/{uid}/usage_rollups/{window}` — UsageRollupDoc

Five separate documents: `today`, `7d`, `30d`, `90d`, `all_time`. Cloud Functions writes each document independently. Android's `mergeWindowDocs()` reads all five and merges them into a single flat `UsageRollups` client model.

| Field | Type | Description |
|-------|------|-------------|
| `totalCost` | number | Sum of cost in window |
| `totalInputTokens` | number | Sum of input tokens |
| `totalOutputTokens` | number | Sum of output tokens |
| `byProvider` | map | Cost and tokens keyed by provider ID |
| `byModel` | map | Cost and tokens keyed by model name |
| `updatedAt` | Timestamp | Last write time |

### `users/{uid}/quota_snapshots/{provider}_{sourceId}` — QuotaSnapshotDoc

| Field | Type | Description |
|-------|------|-------------|
| `provider` | string | Provider ID |
| `sourceId` | string | Account or API key identifier |
| `buckets` | QuotaBucket[] | Quota windows (daily, monthly, etc.) |
| `fetchedAt` | Timestamp | When the snapshot was fetched |

**QuotaBucket fields:** `window`, `limit`, `used`, `remaining`, `resetsAt`

### `users/{uid}/provider_accounts/{accountId}` — ProviderAccountDoc

| Field | Type | Description |
|-------|------|-------------|
| `accountId` | string | Unique account identifier |
| `provider` | string | Provider ID |
| `displayName` | string | Human-readable label |
| `credentialRef` | string | Secret Manager reference (never the key itself) |
| `createdAt` | Timestamp | Account creation time |

## SQLite tables (GRDB, SQLCipher-encrypted)

Managed by `OpenBurnBarDatabase` in `OpenBurnBarCore`. All I/O goes through GRDB's actor-safe `DatabaseQueue`.

| Table | Purpose |
|-------|---------|
| `usage` | Per-event token usage (mirrors UsageEventDoc) |
| `usage_rollups` | Aggregated windows (local cache of Firestore rollups) |
| `conversations` | Session log metadata (title, path, provider, timestamps) |
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

## Android models

Android models must match Firestore exactly. Use `@IgnoreExtraProperties` on every data class. Use `@PropertyName` when the Firestore key differs from Kotlin camelCase (e.g. `providerId` → `@PropertyName("providerId")`).

| Android class | Firestore document | Notes |
|---------------|-------------------|-------|
| `TokenUsage` | `UsageEventDoc` | Direct mapping |
| `UsageRollups` + `RollupSummary` | `UsageRollupDoc` | `mergeWindowDocs()` reads all 5 window docs |
| `ProviderQuotaSnapshot` + `QuotaBucket` | `QuotaSnapshotDoc` | Nested `QuotaBucket` list |
| `ProviderAccount` | `ProviderAccountDoc` | Direct mapping |

Timestamp conversion: `it.seconds * 1000 + it.nanoseconds / 1_000_000` (Firestore `Timestamp` → epoch ms).

Computed properties (e.g. derived display strings) go in the class body, **not** the primary constructor.
