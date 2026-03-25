# Plan 03 — Neural / extended sparse retrieval & multi-field index

**Agent assignment:** Extend lexical retrieval beyond single FTS5 `search_chunks_fts` on chunk text — toward **SOTA hybrid** patterns (sparse neural or **multi-field BM25/FTS**, optional **separate title/project path**).

---

## 1. Research baseline

- **Classic FTS5 (current):** `search_chunks_fts` with `title`, `chunkText`, Porter + unicode61 — see **`DataStore.swift`** migrator ~1263–1272.
- **Limits:** single embedding space; rare tokens / codes / typos; title vs body not weighted differently at query time beyond FTS column match.
- **“Neural sparse” in production** often means **SPLADE**, **sparse vectors in a vector DB**, or **Elasticsearch learned sparse** — typically **not** in-process SQLite on desktop without a bundled model.

**Pragmatic phases for BurnBar:**

1. **Phase A (high ROI, low risk):** Multi-field / multi-index FTS and **boost** metadata (title, project, provider) + query-side field weights.
2. **Phase B:** **Synonym / expansion table** or offline **query expansion** from planner (deterministic, no ML).
3. **Phase C (optional heavy):** Bundle **Core ML** tokenizer + exported sparse weights, or call **hosted sparse API**, writing into new tables.

This plan focuses procedure for **A + B** with a **hook** for **C**.

---

## 2. Current indexing pipeline (must understand before schema change)

### 2.1 Where chunks and FTS rows are written

- **`LocalSearchStore.replaceChunks`** / projection — **`DataStore.swift`** ~3396+: deletes `search_chunks_fts` + `search_chunks` for `documentID`, reinserts chunks, syncs FTS.
- **`ProjectionPipelineService.swift`** — orchestrates projection jobs, embedding writes to **`chunk_embeddings`**, comments at top describe flow to `search_documents`, `search_chunks`, `search_chunks_fts`.

### 2.2 Lexical query execution

- **`LocalSearchStore.searchLexicalChunks`** — **`DataStore.swift`** ~3493+:  
  `search_chunks_fts MATCH ?` + joins `search_chunks`, `search_documents`, filters, **`bm25(search_chunks_fts)`**, `snippet(...)`.

### 2.3 Schema inventory

- **`LocalSearchStore.schemaInventory`** / tests **`BurnBarMigrationTests`** list expected tables: `search_documents`, `search_chunks`, `search_chunks_fts`, `chunk_embeddings`, etc.

Any new virtual table or columns require **GRDB migrator** registration in **`DataStore.swift`** (search for `migrator.registerMigration`).

---

## 3. Procedure

### Phase A — Multi-field / weighted lexical (SQLite-native)

1. **Audit columns** already on `search_documents`: `title`, `subtitle`, `bodyPreview`, `projectName`, `provider` — confirm which are populated at projection time (`ProjectionPipelineService` + document upsert paths).

2. **FTS schema options** (pick one approach):
   - **Option A1 — Single FTS with more columns:** extend `CREATE VIRTUAL TABLE search_chunks_fts` to include e.g. `projectName`, `provider` **duplicated per chunk row** (storage cost) or
   - **Option A2 — Second FTS on documents:** `search_documents_fts` MATCH on title/bodyPreview; union chunk hits with document hits at query time (more complex SQL).

3. **Migrator:** add new migration version:
   - If rebuilding FTS: follow pattern of drop/recreate or FTS5 `rebuild` — see GRDB docs; may need **reprojection job** enqueue for all documents (`ProjectionJobType.rebuild`).

4. **Query builder:** extend **`BurnBarFTSQueryBuilder`** or add **`BurnBarFTSQueryBuilder.fieldBoosted(...)`** to emit queries like `title : foo OR chunkText : foo` if FTS5 syntax supports; verify SQLite FTS5 **column filter** syntax for your column names.

5. **Rank fusion:** combine `bm25` from document-level vs chunk-level hits — either **RRF** between two lists (align with **`HybridFusionStrategy`** in `SearchService`) or weighted sum after normalizing ranks.

6. **`SearchService.retrieve`:** optionally run **second lexical query** against document FTS with small limit, merge chunk IDs into `candidates` before semantic stage.

### Phase B — Deterministic query expansion (no neural model)

1. In **`BurnBarSearchPlan`** or new **`BurnBarQueryExpander`** in **BurnBarCore**:
   - Expand acronyms / project aliases from user **Settings** or static map.
   - Add **quoted phrase** handling improvements for code tokens (already partial in planner).

2. Feed expanded tokens into **`BurnBarFTSQueryBuilder`** (OR-clause expansion).

3. **Tests:** `BurnBarSearchPlannerTests.swift` for expansion determinism.

### Phase C — Neural sparse (optional, large scope)

1. **Choose runtime:** Core ML on-device vs hosted API (OpenAI/other) returning sparse token weights per chunk or per query.

2. **Storage:**
   - New table `chunk_sparse_terms (chunkID, term, weight)` or blob encoding — index with inverted structure or use only at query time for top-N chunks (two-stage).

3. **Query path:** query → sparse vector → top chunks by dot product — **merge** with existing FTS via **RRF** in `SearchService`.

4. **Projection:** extend **`ChunkEmbeddingProviding`** or parallel pipeline job type **`sparse_project`** to populate sparse storage when chunk text changes.

5. **Daemon:** if sparse index lives in SQLite, **BurnBarIndexedSearchService** could read it read-only (Plan 04 alignment).

---

## 4. Files likely touched

| Area | Files |
|------|--------|
| Schema | `AgentLens/Services/DataStore.swift` (migrations, `LocalSearchStore`) |
| Projection | `AgentLens/Services/ProjectionPipelineService.swift`, job types if new |
| Query | `BurnBarCore/.../BurnBarSearchPlanner.swift`, `BurnBarFTSQueryBuilder` |
| Retrieval | `AgentLens/Services/SearchService.swift` (merge lists) |
| Tests | `BurnBarMigrationTests.swift`, `BurnBarSearchIntegrationHarnessTests.swift` |

---

## 5. Risks

- **Migration cost:** rebuilding FTS5 on large DBs is slow; must run in background with UI progress (existing projection queue patterns).
- **Ranking complexity:** multiple lists require disciplined **RRF** to avoid double-counting same document many times — align with document-level dedupe in `retrieve` (~2260+).

---

## 6. Definition of done (Phase A+B)

- [ ] Migrator applies cleanly; existing tests updated for schema inventory.
- [ ] At least one **measurable** recall improvement on internal harness queries (add golden queries to `BurnBarSearchIntegrationHarnessTests`).
- [ ] No regression on aggregate / `countOccurrencesInConversationFullText` paths (separate SQL on `conversations`).

---

## 7. Out of scope

- Full SPLADE training pipeline.
- Replacing OpenAI dense embeddings — orthogonal.
