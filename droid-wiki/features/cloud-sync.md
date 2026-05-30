# Cloud sync

Optional cross-device continuity. Local SQLite is always canonical — cloud sync is replication, not the source of truth.

---

## Purpose

OpenBurnBar's primary design principle is local-first. The daemon parses agent logs directly from disk and stores everything in a local GRDB/SQLite database. Cloud sync adds cross-device continuity for users who want their usage history and quota state available on their iPhone, iPad, or secondary Mac — but it is never required.

---

## What syncs automatically (when signed in)

| Data | Destination | Notes |
|------|------------|-------|
| Usage rows | Firestore `users/{uid}/usage/{doc}` | `UsageSyncService.swift` |
| Usage rollups | Firestore `users/{uid}/usage_rollups/{window}` | 5 documents: today, 7d, 30d, 90d, all_time |
| Quota snapshots | Firestore `users/{uid}/quota_snapshots/{provider}_{sourceId}` | `QuotaSnapshotSyncService.swift` |
| Provider accounts | Firestore `users/{uid}/provider_accounts/{accountId}` | |
| Chat thread metadata | Firestore `users/{uid}/chat_threads/` | `ChatThreadSyncService.swift`; bodies require opt-in |
| Text expansion snippets | Firestore | `TextExpansionSyncService.swift` |
| Mac cloud presence | Firestore | `MacCloudPublisher.swift` |

## What requires explicit opt-in

| Data | Opt-in | Notes |
|------|--------|-------|
| Conversation session-log backups | Settings → Cloud → Backup & Sync | Encrypted blobs; `SessionLogSyncService.swift` (49,432 bytes) |
| Chat message bodies | Settings → Cloud | Separate gate from thread metadata |
| Hosted search index | BurnBar Pro subscription | Uploads encrypted token/semantic postings |

---

## Auth

Firebase Auth via Google or Apple Sign-in. Without sign-in, all data stays local. Signing out does not delete local data.

---

## Firestore schema (canonical source: `functions/src/types.ts`)

```
users/{uid}/
    usage/{doc}              → UsageEventDoc
    usage_rollups/today      → UsageRollupDoc
    usage_rollups/7d         → UsageRollupDoc
    usage_rollups/30d        → UsageRollupDoc
    usage_rollups/90d        → UsageRollupDoc
    usage_rollups/all_time   → UsageRollupDoc
    quota_snapshots/{k}      → QuotaSnapshotDoc
    provider_accounts/{id}   → ProviderAccountDoc
    chat_threads/{id}        → ChatThreadDoc (metadata only by default)
    devices/{id}             → DeviceDoc
```

---

## iCloud

`ICloudSessionMirrorService` (referenced in `CLIAgentSessionMirror.swift`) copies session logs to iCloud Documents as a secondary backup path. This is separate from Firestore sync and requires iCloud Drive to be enabled.

---

## Conflict resolution

Local SQLite is authoritative. When the app starts or reconnects:
1. Local writes take precedence over remote state for the same document
2. `CloudSyncCoordinator.swift` (15,511 bytes) manages merge decisions
3. `CloudSyncCircuitBreaker.swift` (9,124 bytes) backs off on Firestore errors to prevent write storms
4. `CloudSyncFirestoreGateway.swift` abstracts Firestore operations for testability (with a `CloudSyncFirestoreFakeGateway.swift` for testing)

---

## Key source files

All under `AgentLens/Services/CloudSync/`:

| File | Purpose |
|------|---------|
| `CloudSyncCoordinator.swift` | Orchestrates all sync services |
| `CloudSyncTypes.swift` | Shared types and document models |
| `SessionLogSyncService.swift` | Session log backup (opt-in) |
| `CollaborationSyncService.swift` | Shared artifact and workspace sync |
| `QuotaSnapshotSyncService.swift` | Quota state replication |
| `ChatThreadSyncService.swift` | Thread metadata sync |
| `UsageSyncService.swift` | Usage row sync |
| `CloudSyncCircuitBreaker.swift` | Error backoff |
| `HermesRelayHostService.swift` | Hermes relay presence management |

Top-level: `AgentLens/Services/CloudSyncService.swift` (the high-churn orchestration entry point).

---

## Android

Android defaults to read-only Firestore consumption. Outbound write paths exist for: iroh pairing state, FCM device tokens, mission dispatch, and approval policy. These follow the canonical schemas in `functions/src/types.ts` and are aligned via the `android-firestore-worker` skill.
