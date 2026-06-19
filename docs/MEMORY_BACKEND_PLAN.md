# Memory Subsystem — BACKEND Implementation Plan

> **Implementer:** GPT‑5.5 / Codex (backend session). **Companion:** `docs/MEMORY_FRONTEND_PLAN.md` (chat/UI session). **Why (full rationale + 75‑agent audit + Codex adversarial review):** `docs/MEMORY_STRATEGY_AUDIT.md`. **Governing plan:** `docs/PROJECT_CODE_MEMORY_MASTER_PLAN.md` — this work is its **Phase‑1 Agent Memory, extended to the Hermes/CLI chat domain**. Not a new store.

This document is the executable build spec for the **data, persistence, extraction, embedding, vector, recall, and cloud** layers of a mem0‑class semantic memory feature. Build it exactly. Where a decision is genuinely open it is marked **`DECIDE`** with a recommended default.

---

## 0. Mission

Derive discrete, sourced **facts** from Hermes / CLI‑bridge chat, store them as a **thin versioned memory authority layer** (sealed‑reference bodies, never plaintext), make them **semantically recallable** with embedding‑version safety, and make them **forgettable** end‑to‑end. Local‑first SQLite is canonical; Firestore is an optional, sealed, review‑gated replication plane.

The frontend consumes one protocol — `MemoryServing` (§3). Everything else here is yours.

---

## 1. Non‑negotiable invariants (CI‑enforced, merge‑blocking)

These are gates. A PR that violates one does not merge. Each maps to a test in §12.

1. **G1 — No‑plaintext memory.** No fact body in any persistent index: no body‑bearing memory FTS, no fact body in `search_chunks.text`, none in `memory_audit`, logs, schema docs, or any cloud field. Bodies live **only** in the sealed snapshot store (`project_memory_snapshots` / Pensieve), referenced by `body_ref`/`body_redacted`. (Codex P1; mirrors the daemon's deliberate `agent_memories_fts` DROP.)
2. **G2 — Embedding‑version floor.** Every memory vector is keyed `(memory_id, embedding_version_id)` with an explicit `dimension`; recall filters `WHERE embedding_version_id = <active> AND dimension = <active>`; the ANN index is **partitioned one space per active version**. Cross‑generation vectors are never compared. Re‑embed (never compare) on version bump.
3. **G3 — Durable extraction outbox.** Extraction intent is persisted transactionally on the source commit and drained idempotently. Crash / retry / duplicate‑send / cancellation / local‑oracle replies yield **exactly‑once‑or‑idempotent** memories. (Codex P1.)
4. **G4 — Review/admission lifecycle.** New memories are `quarantined` by default. A `quarantined` memory **cannot** be injected into a prompt and **cannot** replicate to cloud. Cloud commit requires `approved`. (Codex P1; `knowledgeMemory.ts:395` requires explicit approval, `memoryHook.ts:223` defaults quarantined.)
4. **G5 — Two‑phase cross‑tier forget.** `forget` hard‑deletes locally **and** (if replicated) device‑authed deletes the sealed cloud row **and its cloaked vector**, with a receipt + tombstone. Forget is **fact‑level**, not source‑wide. Ships and is tested **before** any cloud replication is enabled. (Codex P1; master plan §5.8.)
6. **G6 — Embedding quality/drift.** A pinned eval set, an OS/model‑revision version stamp, a re‑embed SLA, and defined fallback behavior. Recall quality is gated, not assumed. (Codex P2→gate.)
7. **G7 — Secret/PII gate.** Every extracted fact passes a pre‑persistence secret/PII scanner (reject‑or‑redact + label‑only audit) before it touches any store. No app‑side gate exists today — you build it.

> Frontend owns the remaining two gates (wrapUntrusted injection trust + global prompt token arbiter); they are listed in the frontend plan.

---

## 2. Architecture — the memory authority layer

```
 chat assistant reply (terminal-commit)                [FRONTEND emits terminal event/status]
        │
        ▼
 memory_extraction_jobs  ── durable outbox (idempotency_key) ──┐         [G3]
        │  drained off-main, debounced, admission-gated         │
        ▼                                                       │
 ExtractionWorker ── LLM extract → SECRET/PII gate [G7] ─────────┘
        │  facts: {text, kind, confidence, provenance-envelope}
        ▼
 seal body → project_memory_snapshots (sealed)         body NEVER persisted in plaintext [G1]
        │
        ├─► agent_memories (authority record: body_ref/body_redacted, source_kind='chat',
        │                   scope keys, review_status='quarantined', valid_*, superseded_by)
        ├─► memory_provenance (many-to-one citations; per-citation state)        [Codex P1, G5]
        ├─► embed (local) → memory_embedding_refs (memory_id, embedding_version_id, dim, vector) [G2]
        └─► memory_audit (hash-chained event; labels only, no body)              [G1]
        │
        ▼
 dedup/merge/supersede (semantic, deadband, deterministic winner)
        │
        ▼
 MemoryServing.search / recallForPrompt  ──► [FRONTEND injects, wrapUntrusted + token arbiter]
        │
        ▼  (only if review_status='approved' AND user opted into cloud)         [G4]
 MemorySyncService → cloak (bge-384) + seal (CloudVault AAD) → commitKnowledgeBatch  [G5 forget]
```

**Ownership:** the **app (AgentLens, GRDB)** owns the chat memory authority at runtime, writing `source_kind='chat'` rows into the **unified `agent_memories` authority table** (the daemon continues to own `source_kind='code'`). One authority table, partitioned by `source_kind`; both follow identical sealed‑reference discipline. This is the master plan's "local index over Pensieve/snapshot memory, **not a third store**," now made relationally complete.

> **`DECIDE` (PR‑0, recommend = unified):** unified `agent_memories` authority (recommended — one authority, satisfies "no third store") vs an app‑owned `chat_memories` sibling with identical schema (cleaner process ownership, but two record tables). Recommend unified; if eng review rejects shared app+daemon writes to one table, fall back to the sibling — all integrity tables (§5.2‑5.4) are shared either way.

---

## 3. The seam — `MemoryServing` (backend implements, frontend depends on)

Define in `AgentLens/Services/Memory/MemoryServing.swift`. This is the **only** surface the frontend touches.

```swift
public protocol MemoryServing: Sendable {
    // mem0 CRUD (each mutation returns an event_id; poll eventStatus)
    func add(_ request: MemoryAddRequest) async throws -> MemoryEventID
    func search(_ query: MemoryQuery) async throws -> [RecalledMemory]
    func get(id: MemoryID) async throws -> Memory?
    func getAll(_ page: MemoryPageRequest) async throws -> MemoryPage
    func update(id: MemoryID, _ patch: MemoryPatch) async throws -> MemoryEventID
    func delete(id: MemoryID) async throws -> MemoryEventID          // fact-level two-phase forget [G5]
    func deleteAll(scope: MemoryScope) async throws -> MemoryEventID
    func listEntities() async throws -> [MemoryEntity]
    func eventStatus(_ id: MemoryEventID) async throws -> MemoryEventStatus

    // Recall for prompt injection — frontend's single entry point.
    // Returns version-floored, review-gated (approved/injectable only [G4]), ranked snippets
    // with provenance for citations. Bodies are decrypted transiently; never logged.
    func recallForPrompt(_ request: MemoryRecallRequest) async throws -> [MemorySnippet]

    // Review lifecycle [G4]
    func approve(id: MemoryID) async throws -> MemoryEventID
    func reject(id: MemoryID) async throws -> MemoryEventID

    // Extraction trigger entry (frontend calls on terminal assistant commit) [G3]
    func enqueueExtraction(_ intent: ExtractionIntent) async throws
}
```

Shared model types (`MemorySnippet` carries `memoryID`, `text`, `confidence`, `provenance: [Citation]`, `trustTier`, `tokenCountEstimate`; `Citation` carries `localJumpID: ChatMessageRef?`, `crossDeviceHMAC`, `threadLogicalID`, `authoredAt`, `citationState`). Frontend renders citations from these; never reads tables directly.

---

## 4. Data model — v51 GRDB migration

One migration: `migrator.registerMigration("v51_chat_memory_authority")` in `AgentLens/Services/DataStore/OpenBurnBarDatabase.swift` (next after `v50`). **Schema lands here first**; `docs/SCHEMA_SQLITE.sql` is regenerated as a derived mirror (extend `scripts/.../verify-sqlite-schema-doc.mjs` to read this migrator — today it does not, a CI blind spot).

### 4.1 Drop the contradictory body FTS (PR‑0, before v51)
`agent_memories_fts` (`OpenBurnBarDatabase.swift:1742`) carries `bodyText` and is mirrored in `docs/SCHEMA_SQLITE.sql:237`, but daemon tests assert it absent (`BurnBarProjectCodeMemoryStoreTests.swift:329`). It violates **G1**. Drop it in a `v51a_drop_body_fts` step (`DROP TABLE IF EXISTS agent_memories_fts`), remove from the doc, keep the daemon bootstrap in lockstep.

### 4.2 Authority record — additive `ALTER`s on `agent_memories`
```sql
ALTER TABLE agent_memories ADD COLUMN source_kind   TEXT NOT NULL DEFAULT 'code';  -- 'code' | 'chat'
ALTER TABLE agent_memories ADD COLUMN review_status TEXT NOT NULL DEFAULT 'approved'; -- legacy=approved; new chat='quarantined'
ALTER TABLE agent_memories ADD COLUMN user_id  TEXT;   -- chat scope keys (nullable for code rows)
ALTER TABLE agent_memories ADD COLUMN agent_id TEXT;
ALTER TABLE agent_memories ADD COLUMN run_id   TEXT;
ALTER TABLE agent_memories ADD COLUMN app_id   TEXT;
CREATE INDEX IF NOT EXISTS agent_memories_chat_scope_idx
  ON agent_memories(source_kind, user_id, agent_id, run_id, app_id, updated_at);
```
`body_ref`/`body_redacted` discipline is unchanged: body sealed into `project_memory_snapshots`, row stores the reference. Reuse `BurnBarProjectCodeMemoryStore.memoryBodyReference(...)` pattern.

### 4.3 `memory_provenance` — many‑to‑one citations (Codex P1)
```sql
CREATE TABLE IF NOT EXISTS memory_provenance (
    id                 TEXT PRIMARY KEY,
    memory_id          TEXT NOT NULL,
    source_kind        TEXT NOT NULL,          -- 'chat_message'
    thread_logical_id  TEXT NOT NULL,          -- content-derived, cross-device stable (§6)
    message_id         TEXT,                   -- local jump id when available
    role               TEXT NOT NULL,          -- user|assistant (NEVER tool/memory-derived)
    authored_at        TEXT NOT NULL,
    content_hash       TEXT NOT NULL,          -- envelope content hash (§6)
    occurrence         INTEGER NOT NULL DEFAULT 0,
    xdevice_hmac       TEXT NOT NULL,          -- HMAC over the canonical envelope (§6)
    citation_state     TEXT NOT NULL DEFAULT 'live',  -- live|source_pruned|tombstoned
    created_at         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS memory_provenance_memory_idx ON memory_provenance(memory_id);
CREATE INDEX IF NOT EXISTS memory_provenance_hmac_idx   ON memory_provenance(xdevice_hmac);
CREATE INDEX IF NOT EXISTS memory_provenance_msg_idx    ON memory_provenance(message_id);
```

### 4.4 `memory_extraction_jobs` — durable outbox (Codex P1, G3)
```sql
CREATE TABLE IF NOT EXISTS memory_extraction_jobs (
    id              TEXT PRIMARY KEY,
    idempotency_key TEXT NOT NULL UNIQUE,      -- HMAC(thread_logical_id, message_id, prompt_version)
    thread_id       TEXT NOT NULL,
    message_id      TEXT NOT NULL,
    scope_json      TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending', -- pending|running|succeeded|failed|skipped
    attempts        INTEGER NOT NULL DEFAULT 0,
    last_error      TEXT,
    not_before      TEXT,                      -- backoff
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS memory_extraction_jobs_status_idx ON memory_extraction_jobs(status, not_before);
```
Reuse the reaping/retention pattern from `ProjectionStore.reapTerminalProjectionJobs`.

### 4.5 `memory_embedding_refs` — vector linkage, no plaintext (Codex P1, G2)
```sql
CREATE TABLE IF NOT EXISTS memory_embedding_refs (
    memory_id           TEXT NOT NULL,
    embedding_version_id TEXT NOT NULL,        -- FK → embedding_versions.id (v14 substrate)
    dimension           INTEGER NOT NULL,
    vector              BLOB NOT NULL,         -- local; cloaked separately for cloud
    norm                REAL NOT NULL,
    created_at          TEXT NOT NULL,
    PRIMARY KEY (memory_id, embedding_version_id)
);
CREATE INDEX IF NOT EXISTS memory_embedding_refs_version_idx ON memory_embedding_refs(embedding_version_id, dimension);
```
> **Explicit resolution of Codex P1 (chunk_embeddings reuse):** memory facts do **not** enter `search_chunks.text` (would break G1). Vectors live here, reusing the `embedding_models`/`embedding_versions` registry + HNSW machinery. Lexical recall is over **redacted title/tags/kind only** (no body FTS); optional ephemeral in‑memory body match runs over the small recalled candidate set after transient decrypt (never persisted).

### 4.6 `memory_source_tombstones` — fact‑level forget (Codex P1, G5)
```sql
CREATE TABLE IF NOT EXISTS memory_source_tombstones (
    id                TEXT PRIMARY KEY,
    thread_logical_id TEXT NOT NULL,
    message_id        TEXT,
    content_hash      TEXT,
    reason            TEXT NOT NULL,           -- clear_history|gc_30d|user_delete
    created_at        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS memory_source_tombstones_thread_idx ON memory_source_tombstones(thread_logical_id);
```

---

## 5. Components

### 5.1 Embedding providers + version registry (Decision 2, Codex P1)
`AgentLens/Services/Search/Embedding/`:
- **Primary (durable, cross‑device): `BgeEmbeddingProvider`** — the shipped Pensieve **bge‑384** family (`tools/openburnbar-mcp-remote/src/embed.ts:62`), portable, already cloak/seal‑aligned for cloud. Conform `ChunkEmbeddingProviding` **and** `QueryEmbeddingProviding`. Pin model + revision in `EmbeddingModelDescriptor.versionTag` (e.g. `bge-small-en-v1.5-384`).
- **Fallback (Mac‑local, zero‑artifact): `NLEmbeddingProvider`** — Apple `NaturalLanguage` (reuse the daemon `BurnBarCodeEmbedding.swift` pattern; the app cannot import the daemon module — reimplement ~20 lines). **Stamp OS build + model revision into the versionTag** (`nl-sentence-en-<dim>-r<rev>`) so an OS upgrade forces a re‑embed, never a silent compare.
- Register each as an `embedding_models` + `embedding_versions` row with `isActive`; reuse the v14 registration path (`SearchService+Factory.swift:241`, `ProjectionStore`). The 96‑d `DeterministicFakeEmbeddingProvider` stays CI‑only and is **hard‑excluded** from recall ranking.
- Selection: a `MemoryEmbeddingProviderSelector` mirroring `ProjectionPipelineService.swift:79‑111` (provider preference → fallback). No ONNX/CoreML download in v1; bundled CoreML bge is a **deferred** upgrade behind G6.

### 5.2 Vector store linkage
Reuse `VectorSemanticProvider` + `BurnBarPersistentVectorIndex` (pure‑Swift HNSW) for memory vectors via a `memory_id ↔ UInt64` key codec; **one ANN snapshot per active `embedding_version_id`** (G2). Exact‑cosine streaming fallback when no snapshot exists. No `sqlite-vec`.

### 5.3 Extraction outbox + worker (Decision 3, Codex P1, G3)
`AgentLens/Services/Memory/`:
- `ExtractionIntent` enqueue (`MemoryServing.enqueueExtraction`) writes a `memory_extraction_jobs` row keyed by `idempotency_key = HMAC(thread_logical_id, message_id, prompt_version)`. The frontend calls this on the **explicit terminal assistant‑commit event** (frontend plan §5.1) — never on UI state.
- `MemoryExtractionWorker` (actor): debounced (idle/session‑end), off‑main, admission‑gated by a **non‑throwing** `ExtractionAdmissionController` modeled on `AutoSummaryEngine` (`inFlight`/`maxConcurrent`, `coalesceDelayNanoseconds`, `summaryFailureRetryCooldown`) — **not** BudgetGate. Drains `pending` jobs: LLM extract → **G7 secret/PII gate** → seal body → write record + provenance + embedding_ref + audit, all under one `BEGIN IMMEDIATE` **except** the LLM/embed calls which run *outside* the held transaction (precompute, then write — mirror `PreparedCodeChunk`). Terminal states + bounded retries + backoff. Single‑flight per idempotency key.
- Extraction model: in‑process Hermes backend for the live leg; **offline / CLI‑bridge defers to the user's own model at session end** (reuse `memoryHook.ts` `defaultExtractor` shape) with `enqueue+retry, never throw`. Extraction prompt: reuse/port `EXTRACT_PROMPT` (skip ephemeral chatter; emit `{text, kind, confidence}`).

### 5.4 Dedup / merge / supersede (Decision 4 + Codex)
On each new fact: scope‑constrained ANN near‑neighbor lookup (same scope keys + source_kind). **Deadband/hysteresis** (`T_merge` > `T_keep`) to stop oscillation. Deterministic winner: `(confidence desc, valid_from asc, lexicographic id)`. Never LLM‑author merged text on the hot path (concatenate‑and‑supersede or keep‑highest‑confidence verbatim; summarize only in a separate idempotent batch). Drive `valid_to`/`superseded_by` + a `memory_audit` row in one transaction; **union loser provenance into survivor** (`memory_provenance`). Recall filters `valid_to IS NULL`. Pin `T_merge` with the G6 eval set.

### 5.5 Provenance envelope (Decision 4, Codex P1, §6)
Build `CanonicalSourceEvent`: `{schema_version, thread_logical_id (content‑derived stable id — derive from first user message hash / existing `stableId`, NOT the device‑local UUID), message_id?, role, authored_at, content_hash, occurrence}`. `xdevice_hmac = CloudVaultCrypto.pensieveDedupKey(label: "memory-citation")` HKDF over the envelope. Store both `message_id` (local jump) and `xdevice_hmac` (cross‑device). Many‑to‑one via `memory_provenance`.

### 5.6 Recall query service (the frontend's `recallForPrompt`/`search`)
`MemoryRecallService`: embed query (active version) → version‑floored ANN over `memory_embedding_refs` → RRF with redacted lexical (title/tags) → reuse `CrossEncoderReranker` (optional) → hydrate sealed bodies transiently → filter `review_status ∈ {approved}` and `valid_to IS NULL` (**G4** — quarantined never returned for injection) → return `MemorySnippet[]` with provenance + `tokenCountEstimate` (frontend arbiter consumes). Scope filters mirror mem0.

### 5.7 Cloud sync + two‑phase forget + review lifecycle (G4, G5)
`MemorySyncService` reusing `ChatThreadSyncService` sealed‑payload + `CloudVaultCrypto` AAD:
- **Vectors local‑only by default.** If cloud recall is enabled, replicate via the **shipped Pensieve cloak path** (`embed.ts` Householder cloak → seal → `commitKnowledgeBatch`), carrying `embeddingModelVersion`; never a raw vector mirror.
- **G4:** only `review_status='approved'` replicates; `commitKnowledgeBatch`/`knowledgeMemory.ts:395` already requires explicit approval — honor it, don't enqueue un‑committable work.
- **G5 forget:** `delete(id)` = local hard‑delete (record + provenance + embedding_ref + sealed body section) **and**, if replicated, device‑authed cloud delete‑by‑HMAC of the sealed row + cloaked vector, with receipt + tombstone surfaced in doctor. **Fact‑level** (per‑citation), not `deleteKnowledgeSource`‑coarse. Lands + tested before replication ships.
- **G7 secret/PII gate:** `MemorySecretScanner` (reuse/share the daemon secret corpus + add injection‑sentinel patterns) runs pre‑persistence; register new fields in `packages/data-domains/registry.json` at `end_to_end` + extend `scan-chat-cloud-plaintext.mjs` + `firestore.rules` allowlist.

---

## 6. PR sequence (backend)

Each PR: cheap local checks pass, coherent + reviewable, validation matrix + risks + rollback in the body, factory‑review labeled (`AGENTS.md`).

- **PR‑0 — Reconcile + drop body FTS.** Update `docs/PROJECT_CODE_MEMORY_MASTER_PLAN.md` (fold chat‑memory into Phase‑1). `v51a_drop_body_fts` (G1). Extend `verify-sqlite-schema-doc.mjs` to read the app migrator. Tests: migration applies; FTS absent; daemon lockstep.
- **PR‑1 — v51 schema + authority writes (flagged OFF).** §4 tables/ALTERs; the app‑side sealed‑reference chat‑memory writer; `memory_audit` actions. No extraction yet. Tests: migration up + clear‑to‑baseline; no‑plaintext invariant (G1); write→read sealed‑reference round‑trip.
- **PR‑2 — Embedding providers + version registry + vector linkage.** §5.1‑5.2; bge‑384 primary + NLEmbedding fallback registered as `embedding_versions`; `memory_embedding_refs`; per‑version HNSW partition. Tests: version‑floor (G2) — dimension mismatch throws; cross‑version never compared; revision bump forces re‑embed.
- **PR‑3 — Extraction outbox + worker + secret gate.** §5.3, §4.4, G3, G7. Tests: crash/retry/duplicate‑send/cancel → exactly‑once‑or‑idempotent; lock not held across LLM/embed; secret/PII rejected pre‑persistence.
- **PR‑4 — Dedup/merge/supersede.** §5.4. Tests: deadband no oscillation; deterministic winner; provenance union; recall excludes superseded.
- **PR‑5 — Recall service + `MemoryServing` impl.** §5.6, §3 (search/get/getAll/update/delete/listEntities/eventStatus/recallForPrompt). Tests: scoped recall; quarantined excluded (G4); version‑floored; event_id status transitions.
- **PR‑6 — Forget + review lifecycle (still local).** G4/G5 local half: approve/reject, fact‑level delete, source tombstones, clear‑history + 30‑day‑GC reconciliation. Tests: G5 fact‑level forget; tombstone suppresses recall.
- **PR‑7 — Cloud sync (gated on PR‑6).** §5.7 cloak+seal replication, approved‑only, cross‑tier forget receipts, registry/scanner/rules. Tests: only approved replicates; forget unrecoverable from both tiers; no plaintext/raw‑vector cloud field.

Backend exposes `MemoryServing` after PR‑5; frontend can integrate against a stub/fake from PR‑1.

---

## 7. Test matrix (backend)

| Gate | Test | PR |
|---|---|---|
| G1 no‑plaintext | grep‑assert no body in FTS/search_chunks/audit/cloud; sealed‑ref round‑trip | 0,1,7 |
| G2 version floor | dimension‑mismatch throws; cross‑version isolation; re‑embed on bump | 2 |
| G3 outbox | crash/retry/concurrent‑send/cancel idempotency; lock‑not‑held‑across‑network | 3 |
| G4 review | quarantined never recalled/replicated; approve flips | 5,7 |
| G5 forget | fact‑level two‑phase; unrecoverable both tiers; tombstone suppression | 6,7 |
| G6 drift | pinned eval recall bar; revision stamp; fallback path | 2 |
| G7 secrets | secret/PII rejected pre‑persist; registry/scanner/rules block plaintext cloud | 3,7 |

Targets: macOS app test target (`AgentLensTests/Active/`), daemon (`OpenBurnBarDaemonTests`), and the JS callable tests (`functions/`) for the cloud half.

---

## 8. Implementer guardrails (read before coding)

- Schema lands in the GRDB migrator **first**; `SCHEMA_SQLITE.sql` is a regenerated mirror, never the source of truth.
- Never put a fact body in any persistent index or cloud field (**G1** is the cardinal rule).
- Do not route extraction admission through `BudgetGate` (it throws + exempts subscription creds). Use the non‑throwing `AutoSummaryEngine`‑style controller.
- Do not import `OpenBurnBarDaemon` from `AgentLens` (it ships executables, not a lib) — reuse patterns, not symbols.
- Keep the daemon raw‑SQLite bootstrap in lockstep with every migrator change.
- Do not branch off or build on in‑flight security branches; base on current `main` (run‑09 is merged; the FTS‑orphan/projection‑reap blocker is already cleared).
- Reasoning/“why” for every decision is in `docs/MEMORY_STRATEGY_AUDIT.md`; the frontend contract is `MemoryServing` (§3) — keep it stable.

---

## Appendix — locked decisions (post‑Codex)

1. **Thin versioned authority layer** (not row‑widening, not greenfield): unified `agent_memories` record + `memory_provenance` + `memory_extraction_jobs` + `memory_embedding_refs` + `memory_source_tombstones`; sealed‑reference bodies only.
2. **Embeddings:** bge‑384 portable family primary (cross‑device, cloak‑aligned); NLEmbedding Mac‑local fallback (revision‑stamped); HNSW + version floor; no sqlite‑vec; deferred bundled CoreML behind G6.
3. **Extraction:** durable transactional outbox + idempotent off‑main worker, debounced/session‑end, admission‑gated; explicit terminal‑commit event (not UI state); offline defers to user's own model.
4. **Provenance:** versioned canonical source‑event envelope + cross‑device HMAC + local jump id; many‑to‑one join; fact‑level source‑pruned reconciliation.

Codex adversarial review (full) and the 75‑agent audit: `docs/MEMORY_STRATEGY_AUDIT.md`.
