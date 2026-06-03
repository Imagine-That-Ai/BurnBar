Everything is consistently wired. The `__testing__` export references `purgeLegacyKnowledgeVectorsForUser` at line 502, and the function is declared at line 534 — function declarations are hoisted, so the forward reference is fine (confirmed by passing tsc + tests).

Let me do one final check: confirm `__testing__` doesn't need `purgeLegacyKnowledgeVectorsForUser` declared before it. Since it's a `function` declaration (hoisted), and tsc passed, it's correct.

All work is complete. Here's the changelog.

## CHANGELOG

**`functions/src/callables/knowledgeSearch.ts`**
- Added a `dedupHashVersion == 1` floor to the recall query: after `.where("embeddingModelVersion", "==", embeddingModelVersion)` the query now chains `.where("dedupHashVersion", "==", 1)`, so the server never returns a stranded legacy v0 row (the cleartext-SHA-256 oracle). Updated the surrounding comment (the old "v0 rows fall back to a slugHmac-less recall" line is replaced by the flag-day reality). New invariant: both filters are equality → served by the new composite indexes.

**`functions/src/callables/knowledgeMemory.ts`**
- New constant `RETIRED_EMBEDDING_MODEL_VERSION = "bge-small-en-v1.5"` (the pre-flag-day tag; purge predicate to reach pre-`dedupHashVersion` ancients).
- A2 idempotent-skip floor in `commitKnowledgeBatch`: added `const priorVersion = priorExists ? Number(prior?.get("dedupHashVersion") ?? 0) : 0;` and changed the skip guard to require `priorVersion === DEDUP_HASH_VERSION_VAULT_HMAC` — a stored `dedupHashVersion !== 1` is never an idempotent match (force-rewrite at v1).
- New `async function purgeLegacyKnowledgeVectorsForUser(uid)` (shared helper): deletes via `deleteQueryInBatches` for `dedupHashVersion == 0` and `embeddingModelVersion == RETIRED_EMBEDDING_MODEL_VERSION`; returns `{ deletedByVersion, deletedByRetiredTag }`.
- New owner callable `export const purgeLegacyKnowledgeVectors` (returns `{ ok, deletedByVersion, deletedByRetiredTag, deleted }`) and new daily backstop `export const purgeLegacyKnowledgeVectorsScheduled` (`onSchedule` "every 24 hours", mirrors `backfillPrivacyPlaintextScheduled`; logs via `logInfo`).
- Imports added: `onSchedule` from `firebase-functions/v2/scheduler`; `logInfo` from `../logging.js`.
- A5 doc comments retargeted to the flag-day reality (file-header B-SEC-2 block, the `dedupHashVersion` enum block, the stored-`dedupHash` inline comment, and the `__testing__` comment). `__testing__` now also exports `RETIRED_EMBEDDING_MODEL_VERSION` and `purgeLegacyKnowledgeVectorsForUser`.

**`functions/src/index.ts`**
- Registered the two new exports `purgeLegacyKnowledgeVectors` and `purgeLegacyKnowledgeVectorsScheduled` from `./callables/knowledgeMemory.js`.

**`firestore.indexes.json`**
- Added four `cloud_search_knowledge` composite vector indexes covering the search filter permutations: `(embeddingModelVersion ==, dedupHashVersion ==, embedding vec)`, `(+sourceKind)`, `(+slugHmac)`, and `(+sourceKind+slugHmac)` — so A1's combined floor + `findNearest` is servable for every optional-filter combination. (The `dedupHashVersion == 0` and `embeddingModelVersion ==` purge queries use Firestore default single-field indexing.) JSON validated.

**`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/PensieveVectorCloak.swift`**
- Bumped `embeddingModelVersion` `"bge-small-en-v1.5"` → `"bge-small-en-v1.5-vault-dedup-v1"` (A3 flag-day lever) + doc comment. This propagates to `prepareBatch`/`KnowledgeSyncService`/`PensieveMemorySearchView` automatically and also re-derives the cloak (HKDF `info` is keyed on `modelVersion`), so re-ingested vectors land under a new tag with a fresh cloak.

**`tools/openburnbar-mcp-remote/src/embed.ts`**
- Bumped `EMBEDDING_MODEL_VERSION` to the byte-identical `"bge-small-en-v1.5-vault-dedup-v1"` + doc comment. `loadDefaultEmbedder()` picks it up via `modelVersion: EMBEDDING_MODEL_VERSION`.

**`functions/src/__tests__/knowledgeMemoryDedupHash.test.ts`** (tests added)
- Extended the fake `db` to honor `where` predicates: new `makeQuery` query-double that records `==` predicates and applies them in `.get()` and `.findNearest()` (mirrors the privacyBackfill predicate-recording pattern); `collectionRef` now supports `.where()`; `docSnap` carries `ref.__path` so `batch.delete(doc.ref)` works.
- Kept the two existing write-reject cases (v0 legacy client rejected; raw-embedding rejected).
- Added 3 cases: (1) `searchKnowledge` does NOT serve a seeded v0 row (only the v1 row surfaces); (2) `searchKnowledge` at the new tag returns nothing when only a v0/retired-tag row exists; (3) `purgeLegacyKnowledgeVectors` deletes a `dedupHashVersion:0` row + a field-absent ancient on the retired tag, keeps the v1 row, and returns `deletedByVersion:1, deletedByRetiredTag:1, deleted:2`.
- Result: 7/7 pass; full `tsc --noEmit` clean for functions and mcp-remote; `dataExport.test.ts` still green (22/22 combined).

**Doc-comment scope note:** The recon brief mentions `docs/PENSIEVE.md` / `docs/pensieve-leakage-analysis.md`, but per CONTRACT §STREAM OWNERSHIP those `docs/*.md` files belong to **B-honesty**, not B-dedup. I updated only the v0 doc *comments inside my owned `.ts`/`.swift` files*. The two `docs/*.md` "legacy v0 rows remain readable" lines still need the flag-day rewrite — handed to B-honesty.

**Cross-stream dependency / residual flagged:**
- **Hosted-MCP reader gap (not my ownership):** `services/hosted-mcp/src/knowledge.ts` (`burnbar_search_knowledge`) reads `cloud_search_knowledge` with `embeddingModelVersion` filtering **only when the caller passes it** and has **no `dedupHashVersion` floor** (`:172-177`). The live device path is closed (the device now sends the bumped tag), but an MCP query that omits the model tag or passes the retired tag could still surface v0 rows until `purgeLegacyKnowledgeVectorsScheduled` deletes them. Recommend the owner of `services/hosted-mcp/` add the same `dedupHashVersion == 1` floor for defense-in-depth.
- **Re-ingest trigger:** consistent with the recon finding, no client reads the `privacy_reseal_state` watermark; the re-ingest is driven by the `embeddingModelVersion` bump (the device re-chunks under the new tag), not by a watermark listener. The scheduled purge is the backstop that removes orphaned v0 docs the re-ingest cannot overwrite (new vault-keyed doc id ≠ old SHA-256 doc id).