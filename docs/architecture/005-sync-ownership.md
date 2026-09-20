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
- IPC boundary: typed RPC contracts in `OpenBurnBarCore` (`BurnBarRPCContracts.swift`); version negotiated on connect. Current protocol is **v2**; v1 remains in `supported`.

### SQLite table → process owner (Phase 1 contract)

The live file is `~/Library/Application Support/OpenBurnBar/openburnbar.sqlite`. Dual-writer is debt; this table is the strangler contract. **Writer** is the only process allowed to `INSERT`/`UPDATE`/`DELETE`. The other process may open the file read-only or go through RPC.

| Table | Writer | Reader | Notes |
|------|--------|--------|-------|
| token_usage | app (`UsageStore`) | daemon RPC | Canonical usage |
| conversations | app | daemon read | FTS rebuilt by app migrator |
| conversations_fts | app | app | Virtual table |
| chat_threads | daemon (target) | app via RPC | Today both write — strangler start |
| chat_messages | daemon (target) | app via RPC | Today both write — strangler start |
| search_documents | daemon (target) | app | Projection/search |
| search_chunks | daemon (target) | app | |
| search_chunks_fts | daemon (target) | app | |
| chunk_embeddings | daemon (target) | app | |
| embedding_models | app | daemon | |
| embedding_versions | app | daemon | |
| agent_memories | daemon (target) | app | |
| memory_audit | daemon (target) | app | |
| memory_* | daemon (target) | app | Remaining memory_* tables |
| pcm_* / code_* | daemon | app RPC | Project code memory |
| ai_inbox_* | daemon | app | Self-heal DDL until migrator-first |
| switcher_profiles | app | daemon | |
| switcher_active_profile | app | daemon | Daemon may add `providerID` column guard |
| parser_checkpoints | app | app | |
| parser_checkpoint_files | app | app | |
| source_artifacts | app | app | |
| provider_accounts | app | app | |
| provider_quota_snapshots | app | mobile replica | |
| sync_cursors | app | app | |
| app_state | app | app | |
| vector_index_snapshots | daemon (target) | app | HNSW snapshots |
| project_memory_snapshots | daemon (target) | app | |
| grdb_migrations | migrator | both | One migrator only (Core) |
| remaining tables in `docs/SCHEMA_SQLITE.sql` | app | app | Until listed above |

New tables require a row here before the first `CREATE TABLE`.

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
