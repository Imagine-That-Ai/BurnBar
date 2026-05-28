# ADR 005: Sync ownership (local, cloud, iCloud)

**Status:** Accepted (Phase 6 governance, 2026-05-27)  
**Scope:** macOS app, daemon ledger, Firestore, iCloud file mirror

## Context

Multiple planes can hold overlapping data: local SQLite, daemon JSONL usage ledger, Firestore replication, and iCloud session files. Without explicit ownership, merge bugs and double-writes appear when sync coordinators and legacy `CloudSyncService` paths both touch the same rows.

## Decision

### Source of truth

| Data | Canonical owner | Replication |
|------|-----------------|-------------|
| Token usage rows | Local SQLite (`UsageStore`) | Firestore upload via sync services; daemon ledger for provider routing |
| Conversations (metadata) | Local SQLite | Firestore optional backup |
| Session logs / chat threads | Local SQLite + explicit user opt-in | Firestore; never silent full-transcript upload |
| Shared artifacts | Local SQLite + collaboration merge | Firestore 3-way merge via `DownloadSyncService` / artifact services |
| Provider quota snapshots | Local SQLite cache | Firestore read-only on mobile; Mac writes |
| Hermes / iroh pairing state | Firestore + device key material | Mobile write paths documented in threat model |

**Non-goals:** Firestore is not the interactive search path; GRDB projection + FTS serve queries locally ([OPENBURNBAR_SEARCH_ARCHITECTURE_SPINE.md](../OPENBURNBAR_SEARCH_ARCHITECTURE_SPINE.md)).

### Coordinator split (Phase 3+ remediation)

- **`CloudSyncCoordinator`** — `@MainActor` UI state (`isSyncing`, errors); schedules work.
- **`DownloadSyncService`** — pull + merge from Firestore into SQLite.
- **`ConversationSyncService`**, **`CLIAgentSessionMirror`** — domain-specific upload/download.
- **Legacy `CloudSyncService`** — shrinking god file; new domains must not add logic here—extract a `*SyncService` first.

### Daemon vs app

- Daemon owns provider execution, gateway, MissionControl, and heartbeat.
- App owns SQLite, UI, and Firestore client credentials.
- IPC boundary: typed RPC contracts in `OpenBurnBarCore` (`BurnBarRPCContracts.swift`); version negotiated on connect.

### Conflict resolution

1. Optimistic concurrency on Firestore docs with device-prefixed IDs (`{deviceId}_{entityId}`).
2. Merge failures surface typed sync errors ([003-error-handling.md](003-error-handling.md)); no silent discard.
3. iCloud mirror is **file copy only** — not authoritative for usage rollups.

## Consequences

- New sync features require an ownership row in this ADR (or a new ADR) before implementation.
- Integration tests target `DownloadSyncService` + fake Firestore gateway, not the monolithic `CloudSyncService.sync()` directly.
- SLOs treat Firestore read/write spikes as sync-plane signals ([slos.md](../runbooks/slos.md#cloud-functions)).

## References

- [Release architecture](../OPENBURNBAR_RELEASE_ARCHITECTURE.md)
- [Hosted quota sync](../HOSTED_QUOTA_SYNC.md)
- [CLI agent session mirror](../CLI_AGENT_CHAT_MIRROR.md)
- [001-naming-conventions.md](001-naming-conventions.md)
- [002-actor-boundaries.md](002-actor-boundaries.md)
