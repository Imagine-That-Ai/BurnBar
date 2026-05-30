# Local database

The local SQLite database is the canonical store for all usage history, conversations, retrieval projections, and shared-artifact state. It is owned by the macOS app and accessed through GRDB.

---

## Purpose

OpenBurnBar is local-first. The SQLite database is the source of truth for:

- AI token usage and cost records
- Conversation transcripts and session logs
- Full-text and semantic search indexes (retrieval projections)
- Source artifacts (skill docs, agent docs, shared artifacts)
- Budget ledger and enforcement state
- Parser checkpoints and backfill cursors
- Device, switcher profile, and text-expansion data
- Mirrored controller runtime cache (from the daemon)

Cloud systems (Firestore, iCloud) are replication planes, not authority. Local SQLite wins on conflict.

---

## Key files

| File | Size | Role |
|---|---|---|
| `AgentLens/Services/DataStore/OpenBurnBarDatabase.swift` | ~1817 lines | Schema owner — all 46 migrations registered here |
| `AgentLens/Services/DataStore/UsageStore.swift` | ~82 KB | Token usage queries, rollups, dashboard snapshots |
| `AgentLens/Services/DataStore/ConversationStore.swift` | ~48 KB | Conversation CRUD, FTS, session access |
| `AgentLens/Services/DataStore/DataStoreTypes.swift` | ~999 lines | All record structs and enums shared across stores |
| `AgentLens/Services/DataStore/DataStore.swift` | ~229 lines | `DataStoreActor` — owns the queue and all sub-stores |
| `AgentLens/Services/DataStore/DataStoreCoordinator.swift` | — | `@Observable` SwiftUI bridge; renamed from `DataStore` |
| `AgentLens/Services/DataStore/SearchIndexStore.swift` | — | search_documents, search_chunks, embeddings |
| `AgentLens/Services/DataStore/ProjectionStore.swift` | — | projection_jobs queue |
| `AgentLens/Services/DataStore/ArtifactStore.swift` | — | source_artifacts, shared_artifact_revisions |
| `AgentLens/Services/DataStore/BudgetLedger.swift` | — | Budget ledger records |
| `AgentLens/Services/DataStore/BudgetRulesStore.swift` | — | User-defined budget rules |
| `AgentLens/Services/DataStore/BudgetEnforcement.swift` | — | Budget gate enforcement |
| `AgentLens/Services/DataStore/ParserCheckpointStore.swift` | — | Per-provider parser file positions |

---

## Schema overview

The schema is managed by `OpenBurnBarDatabase`'s static `migrator`, currently at **v46** (`v46_drain_target_per_provider`). Migrations are append-only and must never be modified after they ship.

### Core usage tables

| Table | Migration | Purpose |
|---|---|---|
| `token_usage` | v1 | Every token usage record: provider, model, session, cost, timestamps |
| `usage_rollups` | (derived) | Aggregated rollups by window (today, 7d, 30d, 90d, all_time) |

### Conversation tables

| Table | Migration | Purpose |
|---|---|---|
| `conversations` | v3 | Session metadata: provider, project, timing, message counts, inferred title, fullText |
| `conversations_fts` | v3 | FTS5 virtual table over `inferredTaskTitle` + `fullText` (porter+unicode61 tokenizer) |
| `chat_messages` | v3 | Individual chat messages per session |
| `chat_threads` | v20 | Multi-turn Hermes/chat thread records |

### Retrieval projection tables

| Table | Migration | Purpose |
|---|---|---|
| `search_documents` | v14 | Indexed document metadata (sourceKind, sourceID, title, etc.) |
| `search_chunks` | v14 | Chunked text spans with offsets and ordinals |
| `search_chunks_fts` | v14 | FTS5 virtual table over chunk text |
| `chunk_embeddings` | v14 | Vector embeddings per chunk |
| `source_artifacts` | v15 | Skill docs, agent docs, and shared artifact registrations |
| `shared_artifact_revisions` | v16 | Revision history for shared artifacts |
| `projection_jobs` | v14 | Queue for indexing work (project/reproject/purge/rebuild/reembed) |
| `retrieval_health` | v14 | Per-subsystem health records |

### Budget tables

| Table | Migration | Purpose |
|---|---|---|
| `budget_rules` | v42 | User-defined per-provider budget rules |
| `budget_events` | v42 | Budget enforcement event log |

### Supporting tables

| Table | Migration | Purpose |
|---|---|---|
| `devices` | v22 | Registered devices for cross-device sync |
| `switcher_profiles` | v32 | Account switcher profiles |
| `parser_checkpoints` | v29 | File-offset checkpoints per provider parser |
| `backfill_cursors` | v33 | Cursors for historical backfill sweeps |
| `provider_accounts` | v35 | Provider account records |
| `text_expansion_snippets` | v43 | Text expansion snippet store |
| `project_memory_snapshots` | v39 | Project Memory intelligence snapshots |

---

## GRDB patterns

**Writer selection:** Production code uses `DatabasePool` (concurrent reads, serialised writes). Tests use `DatabaseQueue` (serialised reads and writes). Both satisfy the `DatabaseWriter` protocol that all stores accept.

**Actor isolation:** `DataStoreActor` (`AgentLens/Services/DataStore/DataStore.swift`) is a Swift actor. All stores are `nonisolated` properties initialised at `init` time. Heavy I/O runs off the main thread.

**Record types:** Domain records (`SearchDocumentRecord`, `SearchChunkRecord`, `ProjectionJobRecord`, etc.) are plain `Equatable & Sendable` structs defined in `DataStoreTypes.swift`. Stores execute raw GRDB SQL and decode rows into these structs.

**Migrations:** Registered in `OpenBurnBarDatabase`'s static `migrator` property. `runMigrationsSafely()` runs an integrity check and creates a backup before any migration that would change the schema, then migrates. A failed migration restores from the backup.

---

## Budget tables

Budget enforcement uses three files in `AgentLens/Services/DataStore/`:

- `BudgetLedger.swift` — append-only ledger of spend events
- `BudgetRulesStore.swift` — reads and writes user-defined rules (daily/monthly caps per provider)
- `BudgetEnforcement.swift` — gate logic that blocks requests when a rule would be exceeded
- `BudgetGate.swift` — the synchronous gate called at request time
- `BudgetSettings.swift` — `@Observable` settings model

Budget rules and events land in `budget_rules` and `budget_events` (migration v42).

---

## Parser checkpoints

`ParserCheckpointStore.swift` persists the last-read file offset for each provider log parser (Claude Code, Codex, Factory Droid, Grok, Kimi, MiniMax, etc.). This lets the import pipeline resume after an app restart without re-reading gigabytes of historical logs.

Checkpoints live in the `parser_checkpoints` table (migration v29). Backfill cursors (migration v33) track historical replay sweeps separately.

---

## Related pages

- [Local retrieval system](../retrieval/index.md) — projection pipeline that writes to the search tables
- [Daemon overview](../daemon/index.md) — daemon support directory (separate from SQLite)
