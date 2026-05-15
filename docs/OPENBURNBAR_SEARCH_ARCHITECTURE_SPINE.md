# OpenBurnBar Search Architecture Spine

## Purpose

This document is the implementation map for the locked OpenBurnBar search program. It translates the review decisions into concrete module boundaries, schema changes, pipeline ownership, and rollout order.

Working constraints:

- GRDB/SQLite stays the hot-path authority on device.
- Firestore stays off the local interactive retrieval path. The exception is
  the BurnBar Pro encrypted hosted-session search surface, which stores only
  sealed metadata and keyed token/semantic search hashes for cross-device cloud
  search.
- `SearchService` remains the single app-facing search entrypoint during the transition.
- `DataStore` is split into focused stores over one shared `DatabaseQueue`; it is not replaced with a second persistence stack.

## Current implementation status on `main` (2026-04-26)

The search stack is live behind the seams below. Focused **store types** and database helpers live under [`AgentLens/Services/DataStore/`](../AgentLens/Services/DataStore/); `DataStore.swift` is the **façade/coordinator** over that directory (not a monolithic file anymore).

- **Authoritative local rows:** `conversations` + `source_artifacts` remain local-first in SQLite.
- **Derived retrieval substrate:** `search_documents`, `search_chunks`, `search_chunks_fts`, `projection_jobs`, `embedding_models`, `embedding_versions`, `chunk_embeddings`, `retrieval_health`.
- **Shared/team model:** `shared_artifact_sync_state`, `artifact_permissions`, and `audit_events` are persisted locally and synced via `CloudSyncService`.
- **Queue-driven indexing:** projection/rebuild/re-embed run via `ProjectionPipelineService.runSweep()` from `UsageAggregator`.
- **Single retrieval entrypoint:** `SearchService.retrieve(...)` and `SearchService.search(...)` serve consumers with lexical-first hybrid retrieval. There is **no** separate `AgentLens/Services/Retrieval/` module on disk; lexical/semantic/hybrid details are implemented **inside** `SearchService` + `DataStore` search access.

## BurnBar Pro Hosted Search Addendum

BurnBar Pro adds cross-device hosted search for paid, explicitly synced session
logs without changing the local search authority:

- macOS encrypts the full session body with `CloudVaultCrypto` and uploads the
  ciphertext to Firebase Storage through a signed upload URL.
- macOS writes `cloud_search_documents`, `cloud_search_chunks`, and
  `cloud_search_index_state` through Firebase Functions. These rows contain
  sealed titles/snippets/previews, body/content hashes, storage paths, HMAC
  token hashes, keyed semantic hashes, and semantic posting edges. They do not
  contain plaintext bodies. The commit callable verifies the encrypted Storage
  object exists, has the expected byte size and content type, and matches the
  document/body-hash path before the index row is accepted.
- Hosted index commits are generation stamped. Large uploads can span multiple
  Firestore batches, so the callable writes the active commit marker last and
  search ignores chunks from uncommitted or stale commit IDs.
- iOS/iPadOS and Android register device public keys, read a wrapped cloud
  vault key from `cloud_vault_key_wrappers`, query by locally derived opaque
  token/semantic hashes, and decrypt returned titles/snippets/full bodies
  locally.
- macOS publishes its public key without self-minting trusted Mac status. A Mac
  that is not already trusted can still sync with its local vault key; vault
  wrappers are written only for devices already trusted in the escrow list.
- Android and iOS escrow devices register as pending by default. Trusted status
  is an explicit approval state, and cloud vault wrappers are valid only when
  both source and target devices are trusted.
- Firestore rules require active premium entitlement for cloud index/key-wrapper
  writes. Hosted search index writes are server-only through the commit
  callable; direct client writes to `cloud_search_*` are denied, and the
  callable rejects top-level plaintext `title`, `snippet`, `body`, and `text`
  fields before Admin SDK writes occur.
- `tools/openburnbar-mcp` exposes both local deterministic semantic search over
  SQLite embeddings and an opt-in hosted encrypted MCP path. Hosted MCP search
  derives search hashes locally, sends only opaque hashes to Firebase Functions,
  and decrypts returned snippets/bodies on the MCP host.

This is a privacy-preserving hosted index, not a replacement for local hybrid
retrieval. Local `SearchService` remains the hot path for local corpus search;
cloud search is a separate premium surface for mirrored hosted session logs and
agent/MCP recall.

## Diligence source map (doc → code)

| Concept in this document | Where it is implemented in the repo today |
| --- | --- |
| Single search API for UI / context | [`AgentLens/Services/SearchService.swift`](../AgentLens/Services/SearchService.swift) — `retrieve`, `search` |
| SQLite + store split | [`AgentLens/Services/DataStore.swift`](../AgentLens/Services/DataStore.swift), [`AgentLens/Services/DataStore/`](../AgentLens/Services/DataStore/) (e.g. `OpenBurnBarDatabase`, `*Store` types) |
| Projection / embeddings queue | [`AgentLens/Services/ProjectionPipelineService.swift`](../AgentLens/Services/ProjectionPipelineService.swift) |
| Lexical + semantic retrieval internals | `SearchService` + `DataStore+SearchAccess` and related `DataStore` methods — **not** `LexicalRetriever.swift` (that filename does not exist) |
| Daemon-side indexed search (extension/daemon) | [`OpenBurnBarIndexedSearchService.swift`](../OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarIndexedSearchService.swift) — separate from AgentLens `SearchService` |
| “Vector index” / ANN in shared core | [`BurnBarPersistentVectorIndex.swift`](../OpenBurnBarCore/Sources/OpenBurnBarCore/BurnBarPersistentVectorIndex.swift) (not a standalone `VectorIndex.swift` under a future `Retrieval/` folder) |

## Current module layout on `main`

```text
AgentLens/Services/
  DataStore.swift                    # façade over Services/DataStore/* stores + coordinator
  DataStore/                         # OpenBurnBarDatabase, UsageStore, ConversationStore, SearchIndexStore, …
  ConversationIndexer.swift          # conversation source upsert + projection enqueue
  UsageAggregator.swift              # parser orchestration + discovery + projection sweep triggers
  ProjectionPipelineService.swift   # queue lease/process/retry + chunking + embeddings + rebuild/re-embed
  SearchService.swift                # lexical + semantic retrieval, bounded rerank, degraded-mode health
  CloudSyncService.swift             # shared artifact sync, RBAC snapshots, audit events, conflicts
  InsightEngine.swift                # materialized workflow insight rollups + freshness health
```

## Existing seams to keep and extend

| Existing code | Keep | Attach new work here |
| --- | --- | --- |
| `AgentLens/Services/ConversationIndexer.swift` | Keep the unchanged-file short-circuit and conversation upsert flow. | After each successful upsert, enqueue projection work for the affected source artifact. |
| `DataStore.upsertConversation(_:)`, `fetchConversation`, `fetchAllSessionLogs`, `searchConversationsFTS` | Keep current conversation/session authority; much of the store split is now under `DataStore/`. | Further narrow APIs through `ConversationStore` + search stores behind the same `DatabaseQueue` as needed. |
| `UsageAggregator.refreshAll()` / `refresh(provider:)` | Keep parser orchestration and local persistence flow. | Continue launching artifact discovery + `ProjectionPipelineService.runSweep()` from this seam; do not push indexing into views. |
| `SearchService.search(...)` | Keep this as the only consumer-facing search API. | Keep hybrid retrieval internals behind `SearchService` so views never own bespoke ranking paths. |
| `ContextBuilder.buildSystemPrompt(...)` | Keep prompt formatting responsibility here. | Replace direct `DataStore.fetchConversations(...)` reads with `SearchService.retrieve(...)`-backed context packs. |
| `InsightEngine` | Keep spend/token insight generation. | Keep using `WorkflowInsightRollupService` materialized refresh instead of ad hoc view-side recomputation. |
| `CloudSyncService` | Keep personal usage/session backup behavior. | Add a separate shared-artifact sync layer instead of making Firestore the search source. |
| `SessionLogsView` | Keep reading source transcripts directly. | Add health/status consumption only; do not add retrieval logic here. |

## Shipped: `AgentLens/Services/DataStore/` (extraction in progress, not empty)

The following **exist on `main`** as part of the store/database split (names may evolve; see the directory for the full list):

```text
AgentLens/Services/DataStore/
  OpenBurnBarDatabase.swift
  DataStoreCoordinator.swift
  DataStoreTypes.swift
  UsageStore.swift
  ConversationStore.swift
  ArtifactStore.swift
  SearchIndexStore.swift
  ProjectionStore.swift
  ParserCheckpointStore.swift
  BackfillCursorStore.swift
  RemoteSyncWatermarkStore.swift
  DeviceStore.swift
  ControlPlaneStore.swift
  SwitcherProfileStore.swift
  DatabaseEncryptionService.swift
  DataStore+*.swift                  # domain-specific access extensions
```

`DataStore.swift` is the **façade/composition root** over these types and the shared `DatabaseQueue`.

## Not implemented: optional future folder layout (roadmap only)

The tree below is a **design target**, not a description of the repository. In particular, **`AgentLens/Services/Retrieval/`** with standalone `LexicalRetriever.swift`, `SemanticRetriever.swift`, `HybridSearchPlanner.swift`, and `*VectorIndex.swift` **does not exist**—retrieval logic remains in **`SearchService`** and **`DataStore`** as described above. There are no top-level **`OpenBurnBarIndex/`**, **`OpenBurnBarParsers/`**, or **`OpenBurnBarPersistence/`** package directories (these empty shells were removed 2026-04-28); daemon search lives under **`OpenBurnBarDaemon`**, index contracts under **`OpenBurnBarCore`**, and parsing remains integrated with `UsageAggregator` and related services.

**Optional future extractions** (if the codebase outgrows current files):

```text
AgentLens/Services/Artifacts/        # not yet a dedicated subfolder; logic in UsageAggregator, etc.
AgentLens/Services/Projection/     # still largely ProjectionPipelineService + ProjectionStore
AgentLens/Services/Retrieval/        # NOT PRESENT — use SearchService + DataStore search paths

AgentLens/Services/Collaboration/    # not yet; CloudSyncService covers shared-artifact flow today

AgentLens/Models/                    # see AgentLens/Models/ for current record types
```

Retrieval, projection, and collaboration **subfolders** in this roadmap are organizational targets; today their responsibilities live in the files named above and in `ProjectionPipelineService` / `CloudSyncService` as appropriate.

## Source-of-truth model

Keep source artifacts first-class instead of folding everything into derived search rows.

### Existing local authority that stays

- `token_usage`
- `conversations`
- `chat_messages`
- `summary_runs`

### Current local authority for non-conversation artifacts

- `source_artifacts`
  - one row per discovered skill doc, agent doc, or shared artifact replica
  - stores canonical path/provenance/content hash and active/deleted status
- `shared_artifact_sync_state`
  - local sync cursor between a source artifact and its remote artifact/revision
  - tracks sync status (`synced`, `pending_upload`, `pending_pull`, `conflicted`, `failed`)
- `artifact_permissions`
  - local RBAC snapshot used by retrieval-time shared artifact filtering
- `audit_events`
  - local audit trail for create/update/share/permission/rebuild/conflict actions

Registered discovery roots and extra pattern allowlists are currently persisted in `SettingsManager` user defaults (JSON arrays), then consumed by `ArtifactDiscoveryService`.

Session transcripts can continue to live in `conversations` initially. The new retrieval substrate should point back to either `conversations` or `source_artifacts` through an explicit `(sourceKind, sourceID, sourceVersionID)` reference instead of forcing an early source-table migration.

## Derived retrieval model

These tables are derived and rebuildable:

- `search_documents`
  - one row per retrievable artifact/version
  - stores source linkage, title, project/provider/team filters, freshness metadata
- `search_chunks`
  - one row per retrievable chunk
  - stores `documentID`, parent source linkage, `ordinal`, `startOffset`, `endOffset`, optional message/section offsets, and chunk text
- `search_chunks_fts`
  - lexical index over titles + chunk text
- `projection_jobs`
  - durable local queue/outbox for project, reproject, purge, re-embed, and rebuild work
- `embedding_models`
  - provider/model identity, dimensions, distance metric
- `embedding_versions`
  - model version + chunker version + normalization/prompt version
- `chunk_embeddings`
  - chunk/vector rows keyed by `chunkID + embeddingVersionID`
- `retrieval_health`
  - typed health/error state for lexical, semantic, projection, rebuild, and collaboration subsystems
- `source_artifacts`
  - authoritative source content indexed into derived rows
- `shared_artifact_sync_state`
  - sync cursor metadata used by collaboration merge decisions
- `artifact_permissions`
  - local permission snapshot used to filter shared artifact results
- `audit_events`
  - local mirror of create/update/share/permission/rebuild/conflict events

### Chunking rules

- Chunk long transcripts on message boundaries when possible.
- Chunk docs on heading/paragraph boundaries when possible.
- Every chunk must keep parent linkage and stable offsets.
- Offsets must be sufficient to rebuild snippets and highlight ranges without reparsing the source file.
- Embeddings are attached to chunks, not to source artifacts directly.

## Projection pipeline

```text
Provider parsers + ConversationIndexer   ArtifactDiscoveryService   CloudSyncService(shared)
                 |                                 |                          |
                 +---------- authoritative local source rows in SQLite -------+
                                            |
                                            v
                            conversations + source_artifacts
                                            |
                                            v
                               projection_jobs enqueue
                                            |
                                            v
                       ProjectionPipelineService.runSweep()
                                            |
                 +--------------------------+--------------------------+
                 |                          |                          |
                 v                          v                          v
      search_documents + chunks + FTS   chunk_embeddings + versions   retrieval_health
                 |                                                     + insight rollup trigger
                 +------------------------------- persisted locally ---------------------------+
```

### Projection ownership

1. Ingest persists authoritative source rows first.
2. Ingest only enqueues projection work; it does not embed or rerank inline.
3. `ProjectionPipelineService.runSweep()` leases jobs from `projection_jobs`.
4. Lexical projection is the first-class baseline; semantic enrichment is additive.
5. Any source update, permission change, version bump, or rebuild request produces a durable job.
6. Failures write typed health state and retry metadata; no silent `try?` / `print` failure on critical paths.

## Retrieval pipeline

```text
Chat / Session Logs / ContextBuilder / Authoring
                     |
                     v
          SearchService.retrieve(query)
                     |
            query normalization + filters
                     |
        +------------+-------------+
        |                          |
        v                          v
DataStore.searchLexicalChunks   VectorSemanticCandidateProvider
 (FTS, always on)                (optional semantic path)
                                   ANN -> exact fallback
                                   -> exact bounded rerank baseline
        |                          |
        +------------+-------------+
                     v
              candidate union
                     v
      bounded rerank + source hydration
                     v
  RBAC/visibility filters + snippets + context inputs
```

### Retrieval rules

- Lexical search runs on every query.
- Semantic search is skipped when health is degraded, embeddings are stale, or no active embedding version exists.
- ANN only supplies candidates behind `VectorIndex`; final ranking remains exact bounded rerank.
- Result hydration always resolves back to the source artifact/conversation before rendering snippets or building prompts.
- `ContextBuilder` and any future search UI must call `SearchService.retrieve(...)`; they should not each invent their own ranking path.

## Discovery model for skills and agent docs

Artifact discovery must be allowlisted and explicit:

- roots come from `SettingsManager.artifactDiscoveryRegisteredRoots`
- matching rules live in `ArtifactDiscoveryRules` / `ArtifactDiscoveryService` (currently in `UsageAggregator.swift`)
- initial known-pattern categories:
  - repo docs roots
  - `AGENTS.md` / `CLAUDE.md`-style agent docs
  - `.factory/droids/**`
  - explicitly configured shared/team artifact replicas

Do not add general markdown crawling over arbitrary directories. If a root or pattern is not registered, it is not indexed.

## Team/shared artifact lifecycle

```text
Local shared edit/create
      |
      v
DataStore.upsertSourceArtifact(...)
      |
      +--> enqueue projection job (reproject/purge)
      |
      +--> append local audit event
      |
      v
CloudSyncService.syncSharedArtifacts()
      |
      +--> Firestore workspaces/{workspaceID}/teams/{teamID}/artifacts/{artifactID}
      +--> local permission snapshots + audit events
      |
      v
Remote pull + merge decision(local/synced/remote hash)
   | no conflict                     | stale write / mismatch
   v                                 v
upsert local replica            sync_status=conflicted + notice
   |                                 |
   +-------------> enqueue projection job for local search parity
```

### Firestore role

Firestore is for:

- shared artifact replication
- team membership / RBAC snapshots
- live presence and remote version notifications
- audit distribution

Firestore is not for:

- interactive ranking
- primary search storage
- prompt context authority

## RBAC, audit, and collaboration model

### Roles

- `owner`
  - manage membership/roles
  - edit/delete/share
  - resolve conflicts
  - trigger full rebuild/purge for that artifact
- `editor`
  - read/search
  - create new versions
  - participate in optimistic concurrency flow
- `viewer`
  - read/search/export only

### Enforcement

- local retrieval filters by the latest replicated `artifact_permissions` snapshot
- permission changes enqueue purge/reproject work locally
- revoked access removes the artifact from local retrieval results before or alongside content purge

### Collaboration contract

- use optimistic concurrency in v1, not CRDTs
- every save carries `baseVersionID`
- remote head mismatch marks local sync state as `conflicted`, emits an audit event, and surfaces collaboration notice instead of silent overwrite
- presence is ephemeral; versions and permissions are durable

### Audit events

Audit at minimum:

- artifact create
- artifact update
- artifact share/unshare
- permission change
- rebuild / re-embed trigger
- conflict detection
- conflict resolution

## Stable rollups vs on-demand analysis

Materialize only stable, expensive rollups:

- retrieval health summaries
- per-artifact freshness/staleness
- team/shared artifact counts
- rebuild progress

Keep exploratory analysis on demand through `SearchService.retrieve(...)` and source hydration. Do not precompute speculative insight graphs into the database.

## Operator runbook: health states and rebuild triggers

### Degraded-mode states surfaced to search consumers

| State | Trigger (current implementation) | Expected behavior |
| --- | --- | --- |
| `Index stale` | projection health is non-healthy, queue depth > 0, or failed projection jobs exist | Return best-effort local results and surface stale-index messaging |
| `Semantic unavailable` | semantic health non-healthy or no indexed vectors | Continue lexical retrieval; semantic scoring is reduced/disabled |
| `Rebuild in progress` | pending `.rebuild` or `.reembed` projection jobs | Search remains available while projection/re-embedding catches up |
| `Cloud/shared unavailable` | collaboration health failed/degraded or cloud sync unavailable | Local search continues; shared/team features degrade explicitly |

### Rebuild / re-embed triggers

- **Initial backfill:** `ProjectionPipelineService` enqueues a rebuild when derived search rows are empty but source rows already exist.
- **Conversation/source updates:** `ConversationIndexer`, `ArtifactDiscoveryService`, and `CloudSyncService` enqueue `project`/`reproject` jobs.
- **Deletes or access revocation:** enqueue `purge` jobs for affected source artifacts.
- **Embedding lineage changes:** enqueue `reembed` jobs (scoped or full) so lexical remains available during semantic refresh.
- **Manual/programmatic maintenance:** callers can enqueue rebuild/re-embed directly through `ProjectionPipelineService`.

### Test and eval entrypoints (current scripts)

```bash
# Swift package/unit checks
scripts/test-openburnbar-swift.sh

# Retrieval + authoring replay/golden evals
scripts/test-openburnbar-retrieval-evals.sh

# Full release smoke (Swift + retrieval evals + extension + authenticated daemon health)
scripts/test-openburnbar-release-smoke.sh
```

## Test strategy

Add test coverage in layers:

1. **Migration/store tests**
   - new tables, indexes, and FTS creation
   - backfill from `conversations` into `search_documents/search_chunks`
   - permission purge and rebuild migrations
2. **Projection tests**
   - transcript chunking with stable offsets
   - doc chunking with heading lineage
   - dirty-source enqueue behavior
   - retry/recovery of failed projection jobs
3. **Embedding/vector tests**
   - deterministic fake embedder in CI
   - embedding model/version tracking
   - exact and ANN `VectorIndex` contract parity
4. **Retrieval evals**
   - lexical-only baseline
   - hybrid lexical + semantic
   - semantic outage fallback
   - exact rerank quality goldens
5. **Collaboration tests**
   - RBAC filter enforcement
   - optimistic concurrency conflicts
   - audit log emission
   - local-first reads during Firestore outage
6. **Rebuild/recovery tests**
   - full rebuild
   - selective reproject
   - selective re-embed
   - interrupted backfill resume

Preferred harness shape:

- fixture builders for conversations, skill docs, agent docs, and shared artifacts
- fake clock
- fake embedder
- local Firestore/mock sync adapter
- replay/golden retrieval evals checked into the repo

## Performance guardrails

- keep parsing/ingest and projection separate; indexing must not block refresh UX
- write lexical rows before semantic rows so search remains usable during embedding outages
- cap rerank candidate sets; do not exact-score the full corpus on every query
- keep one active embedding version per query path
- batch projection work in small local transactions; resumable background jobs only
- avoid loading full source bodies until final result hydration
- do not replicate plaintext local derived search tables to Firestore; the
  only cloud index exception is the BurnBar Pro encrypted/HMAC session-log
  index described above
- project only changed artifacts/versions; no full rebuild on normal refresh
- treat rebuild/re-embed as explicit jobs with progress and pause/resume state

Suggested initial budgets:

- lexical query target: sub-100 ms on warm local cache
- hybrid query target: sub-250 ms on warm local cache
- rerank bound: <= 200 deduped candidates
- projection worker batch: small enough to keep UI-main-actor work negligible

## Rollout, backfill, and rebuild plan

### Phase 1: store split without product behavior change

- split `DataStore` into focused stores over one `DatabaseQueue`
- keep `SearchService` public API stable
- no UI-owned search logic

### Phase 2: derived local retrieval substrate

- add `search_documents`, `search_chunks`, `projection_jobs`, `embedding_*`, and health tables
- backfill existing `conversations` into derived search rows
- keep current conversation/session screens reading source rows directly

### Phase 3: registered-root artifact discovery

- add local skill/agent doc discovery from registered roots and known patterns
- project them into the same derived retrieval substrate

### Phase 4: hybrid retrieval

- ship lexical baseline first
- add embeddings and exact vector retrieval
- gate ANN behind the `VectorIndex` interface
- require eval parity before ANN becomes default candidate generation

### Phase 5: team/shared artifacts

- add shared artifact sync, RBAC snapshots, audit, presence, and optimistic concurrency
- search still reads local replicas only

### Phase 6: consumer cutover

- keep `SearchService` as the stable seam while fully serving from the derived hybrid retrieval path
- move `ContextBuilder` to retrieval-backed context packs
- add stable rollups for health/staleness/rebuild status

### Rebuild modes

- **reproject artifact**: content or metadata changed
- **re-embed version**: embedding model/version changed
- **purge artifact**: deleted or access revoked
- **full rebuild**: wipe derived tables only; preserve authoritative source artifacts and audit history

### Migration rule for the current FTS path

Do not ship two user-visible search paths. During migration:

1. keep `SearchService` as the single entrypoint
2. backfill new derived tables behind the scenes
3. dual-read only long enough to verify parity
4. cut over fully to the derived search path in `SearchService`
5. remove direct `conversations_fts` dependence once parity and rebuild safety are proven

## Immediate implementation order

1. split `DataStore` into stores and add derived schema
2. add projection queue + health + backfill
3. add registered-root discovery for skill/agent docs
4. add hybrid retrieval with lexical fallback and evals
5. add shared/team artifact sync, RBAC, audit, and conflicts
6. move prompt/context consumers onto the shared retrieval layer

## Explicit non-goals for this program

- plaintext Firestore-backed interactive search
- arbitrary markdown crawling
- view-owned ranking logic
- embedding-only retrieval without lexical fallback
- silent failure on projection/rebuild/sync critical paths
