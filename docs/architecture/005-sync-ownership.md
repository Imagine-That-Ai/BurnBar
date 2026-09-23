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
- IPC boundary: typed RPC contracts in `OpenBurnBarCore` (`BurnBarRPCContracts.swift`); version negotiated on connect. Current protocol is **v2**; v1 remains in `supported`. v1 amendment 2026-09-22 (Wave 0.3): `daemon.memory.model_policy`, `daemon.memory.sync.inbox.list`, `daemon.memory.sync.inbox.ack` registered in `budgets/rpc-methods-baseline.json` (185→188); see the baseline note for justification. v1 amendment 2026-09-23 (Wave 2.1b): `daemon.chat.thread.create` (188→189) for the chat single-writer cutover — the app's `upsertChatThread` INSERT moves to the daemon; see the baseline note. v1 amendment 2026-09-23 (Wave 2.1c–iii): `daemon.memory.snapshot.upsert` / `.delete` / `.delete_all` (189→192), `daemon.search.vector_snapshot.upsert` (192→193), `daemon.memory.authority.apply` (193→194) for the snapshot, vector-snapshot, and memory-authority single-writer cutovers; see the baseline note. v1 amendment 2026-09-23 (Wave 2.1c-iv): `daemon.search.index.apply` (194→195) for the search-index single-writer cutover; see the baseline note. v1 amendment 2026-09-23 (Wave 2.1c-v): `daemon.switcher.active_profile.apply` (195→196) for the switcher single-writer cutover; see the baseline note.

### SQLite table → process owner (Phase 1 contract)

The live file is `~/Library/Application Support/OpenBurnBar/openburnbar.sqlite`. Dual-writer is debt; this table is the strangler contract. **Writer** is the only process allowed to `INSERT`/`UPDATE`/`DELETE`. The other process may open the file read-only or go through RPC.

| Table | Writer | Reader | Notes |
|------|--------|--------|-------|
| token_usage | app (`UsageStore`) | daemon RPC | Canonical usage |
| conversations | app | daemon read | FTS rebuilt by app migrator |
| conversations_fts | app | app | Virtual table |
| chat_threads | daemon | app via RPC | Cut over Wave 2.1b: app writes via `daemon.chat.thread.create`; app reads stay local until the read cutover |
| chat_messages | daemon | app via RPC | Cut over Wave 2.1b: app writes via `daemon.chat.message.append` (`replace: true` preserves re-save semantics) |
| search_documents | daemon | app via RPC | Cut over Wave 2.1c-iv: app writes via `daemon.search.index.apply` (atomic document-upsert / document-delete / chunk-mutation batch; app-finalized rows stored verbatim, timestamps as GRDB text); app reads stay local until the read cutover |
| search_chunks | daemon | app via RPC | Cut over Wave 2.1c-iv with `search_documents` via `daemon.search.index.apply` (deletes-before-inserts in ≤64-row batches; FTS `title`/`projectName`/`provider` supplied explicitly from the finalized document — the app can no longer read the document row back) |
| search_chunks_fts | daemon | app via RPC | Cut over Wave 2.1c-iv: the daemon assigns FTS `rowid`s in-transaction and records the `ftsRowid` linkage per chunk row; app chunk writes ride `daemon.search.index.apply` |
| chunk_embeddings | daemon (target) | app | |
| embedding_models | app | daemon | |
| embedding_versions | app | daemon | |
| agent_memories | daemon | app via RPC | Cut over Wave 2.1c-iii: app writes via `daemon.memory.authority.apply` (remember/update/review/delete/reconcile/claim/enqueue/record/mark/audit ops applied atomically; app-finalized rows stored verbatim); app reads stay local until the read cutover. One-shot rebuilds owned by the versioned Core migrator (v68); daemon bootstrap must not duplicate versioned repairs |
| memory_embedding_refs | daemon | app read-only | Enforced Wave 0.3: dead app-side upsert removed; app reads via `memoryEmbeddingMatches` |
| memory_audit | daemon | app via RPC | Cut over Wave 2.1c-iii: the daemon assigns `seq`/`prev_hash`/`hash` in-transaction from the live chain head, closing the cross-process chain fork; app audit appends ride `daemon.memory.authority.apply` |
| memory_* | daemon | app via RPC | Cut over Wave 2.1c-iii with `agent_memories` via `daemon.memory.authority.apply` (`memory_body_snapshots`, `memory_provenance`, `memory_fact_tombstones`, `memory_source_tombstones`, `memory_quarantine_bodies`, `agent_memory_bodies`); reseal conflicts surface as retryable `rpcConflict`, never a partial apply |
| pcm_* / code_* | daemon | app RPC | Project code memory |
| ai_inbox_* | daemon | app | Self-heal DDL until migrator-first |
| switcher_profiles | app | daemon | |
| switcher_active_profile | daemon | app via RPC | Cut over Wave 2.1c-v: app writes via `daemon.switcher.active_profile.apply` (atomic pointer-set batch plus clear-by-profile; mirror/fallback lookups finalized against local reads, daemon assigns `updatedAt`); app reads stay local until the read cutover. The legacy fetch-time dedup is subsumed: every set rewrites its scope |
| parser_checkpoints | app | app | |
| parser_checkpoint_files | app | app | |
| source_artifacts | app | app | |
| provider_accounts | app | app | |
| provider_quota_snapshots | app | mobile replica | |
| sync_cursors | app | app | |
| app_state | app | app | |
| vector_index_snapshots | daemon | app via RPC | Cut over Wave 2.1c-ii: app writes via `daemon.search.vector_snapshot.upsert` (app-finalized row stored verbatim, incl. the app's `dot_product` metric spelling; `storageRelativePath` traversal-jailed); app reads stay local until the read cutover |
| project_memory_snapshots | daemon | app via RPC | Cut over Wave 2.1c: app writes via `daemon.memory.snapshot.upsert` / `.delete` / `.delete_all` (app-finalized bytes stored verbatim; daemon lane keeps its own hash/stamp semantics); app reads stay local until the read cutover |
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
