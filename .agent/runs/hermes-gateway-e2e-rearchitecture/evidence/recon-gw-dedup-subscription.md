Final confirmation complete. Critical gap findings:
- **No client consumes the `privacy_reseal_state` watermark** — `PRIVACY_RESEAL_EPOCH` is written server-side but no Swift/Kotlin client reads it. So the "force re-ingest" signal currently has no client listener for Pensieve. The re-ingest must be triggered another way (embeddingModelVersion bump).
- **No re-ingest trigger exists** for Pensieve dedup-v0 on any client.
- `PensieveKnowledgeWatcher` is referenced in docs but **does not exist** as a file (only `KnowledgeSyncService.swift`). The Mac re-sync path is `KnowledgeSyncService`.

I have all the facts. Here is the design brief.

---

## RECON SUMMARY — what is already done vs. what this slice must still build

### DEDUP-V0 (the keyless `contentHash` oracle)

**Already shipped (do NOT redo):**
- `resolveDedupHash` (`functions/src/callables/knowledgeMemory.ts:193-201`) **already requires** `raw.dedupHash` and **never falls back to `contentHash`**. The v0 write path is gone; every new row is stamped `dedupHashVersion = 1`.
- `requireCloakedVector` (`:142-151`) reads **only** `raw.cloakedVector`; a raw `embedding` is rejected (`:261`).
- All **three** device emitters already send the vault-keyed `dedupHash`/`slugHmac` and **no `contentHash`**: Swift `PensieveKnowledgeChunker.prepareBatch` (`OpenBurnBarCore/.../PensieveKnowledgeChunker.swift:196,230,234`), Mac `KnowledgeSyncService.encode` (`AgentLens/.../KnowledgeSyncService.swift:291-302`), Node shim `prepareMemoriesForCommit` (`tools/openburnbar-mcp-remote/src/memoryHook.ts:212,229-239`). **Android has no Pensieve emitter** (grep confirms — `android/.../DataDomains.kt` is the only hit, a registry type, not a writer).
- The test `knowledgeMemoryDedupHash.test.ts` **already flips v0→rejected** (the "FLAG-DAY: a legacy client … is REJECTED" case at `:210-228`, and the raw-embedding rejection at `:230-241`).
- `dataExport.ts` already lists `dedupHashVersion` in `OPAQUE_EXPORT_COLUMNS` (`:237`).

**The real residual gaps this slice designs:**
1. **Stranded v0 rows are never purged.** Legacy v0 docs have `vectorId == legacy cleartext SHA-256(plaintext)` (the doc id was the contentHash). A re-ingest produces a NEW doc id (`vectorId == vault-keyed dedupHash`), so the v0 row is **orphaned, not overwritten** — the keyless SHA-256 oracle survives forever in `dedupHash`/`vectorId` on those old docs. `privacyBackfill.ts` can only `FieldValue.delete()` *fields*, not whole docs (`gatedDeletions`/`sweepDocument` at `:167-229`), so it **cannot** retire a v0 row.
2. **No forced re-ingest.** Production `embeddingModelVersion` is the same string `"bge-small-en-v1.5"` on v0 and v1 rows (`PensieveVectorCloak.swift:35`). Search (`knowledgeSearch.ts:91`) filters by that string, so v0 rows still surface. No `dedupHashVersion`/model-version bump has been wired, and **no client consumes the `privacy_reseal_state` watermark** (grep: zero Swift/Kotlin readers of `privacy_reseal_state`/`resealEpoch`) — so there is no live re-ingest trigger for Pensieve today.
3. **Read path still tolerates v0** (`knowledgeSearch.ts` has no `dedupHashVersion` guard; `commitKnowledgeBatch` idempotent skip at `:295-299` still reads any stored `dedupHash`, including a v0 doc's). Flag-day means: server stops *returning/serving* v0 and purges it.

### SUBSCRIPTION CLOAK (the optional escalation from w3-subscription_topics.md)

**Already shipped (the *minimal* w3 fix):** `encodeTopic` seals `displayName`/`description` → `sealedDisplayName`/`sealedDescription` (`AgentBrandZoneView.swift:1246-1264`); `decodeTopic` opens them with legacy fallback (`:1272-1336`); the merge writers actively `FieldValue.delete()` the legacy plaintext (`upsert` `:1123-1124`); Android mirrors it (`writeFirestore`/`sealedSubscriptionTopicPayload` `AgentSubscriptionTopicStore.kt:199-219,343-352`); the rule has a `hasOnly` allowlist with `validCloudSealedText` and **no longer allows plaintext display fields** (`firestore.rules:1721-1736`); the registry reason is updated (`registry.json:243`); `privacyBackfill.ts` strips legacy `displayName`/`description` once sealed (`:142-148`).

**What this slice designs (the escalation w3 deferred):** the **subscription GRAPH is still in cleartext** — `agentURI` and `topicID` are plaintext fields AND the doc id is `documentID(agentURI:topicID)` = `agentURI:topicID` with `/`,`:`→`_` (`AgentBrandZoneView.swift:1266-1270`, Android `:296`). The server can enumerate exactly **which agents each user follows**. Make the graph opaque: vault-keyed-HMAC doc id + a `sealedAgentURI` for display, while preserving unsubscribe-by-id, `order(by:)`, and dedup.

---

## DESIGN BRIEF

### Part A — DEDUP-V0 flag-day retirement

**A1. Add a `dedupHashVersion` floor to the SEARCH read path.** `functions/src/callables/knowledgeSearch.ts:89-93` — after the `embeddingModelVersion` filter, add `query = query.where("dedupHashVersion", "==", 1)` (or `.where("dedupHashVersion", ">=", 1)` with the model-version filter kept; Firestore allows the inequality since `embeddingModelVersion`/`sourceKind`/`slugHmac` are equality filters — verify composite index, see A7). This stops the server from ever **returning** a stranded v0 row. v0 rows (which carry `dedupHashVersion: 0` or, for pre-`dedupHashVersion` ancients, no field at all) drop out of recall immediately on deploy.

**A2. Add a `dedupHashVersion` floor to the idempotent-skip read in `commitKnowledgeBatch`.** `functions/src/callables/knowledgeMemory.ts:295-299` — the skip currently trusts any stored `dedupHash`. Change the guard so a stored doc whose `dedupHashVersion !== 1` is **never** treated as an idempotent match (force a rewrite at v1): 
```ts
const priorVersion = priorExists ? Number(prior?.get("dedupHashVersion") ?? 0) : 0;
if (priorExists && priorVersion === DEDUP_HASH_VERSION_VAULT_HMAC && priorDedupHash === v.dedupHash) {
  skipped += 1; continue;
}
```
This makes a re-ingest of an unchanged source rewrite any v0 row at v1 (when the doc id collides) instead of skipping it.

**A3. Force the re-ingest via a model-version bump (the flag-day lever).** Because the v0 doc id is the *legacy SHA-256*, a re-ingest writes a *new* doc id and cannot reach the v0 row by id. The lever that guarantees every source re-chunks is bumping the embedding-model tag so the new vectors live under a new `embeddingModelVersion` and the device re-runs the full pipeline:
- `OpenBurnBarCore/.../PensieveVectorCloak.swift:35` — bump `embeddingModelVersion = "bge-small-en-v1.5"` → `"bge-small-en-v1.5-vault-dedup-v1"` (a new pinned tag). This propagates automatically through `prepareBatch` (`:245`), `KnowledgeSyncService` (`:286`), `PensieveMemorySearchView` (`:248`), and the Node shim (`embed.ts:187` `EMBEDDING_MODEL_VERSION`) — bump the Node constant to the identical string (`tools/openburnbar-mcp-remote/src/embed.ts`, grep `EMBEDDING_MODEL_VERSION`). 
- This makes search at the new tag (A1) return **only** freshly re-ingested v1 rows, and the old tag's v0 rows become permanently unreachable by recall — then A4 deletes them.

**A4. Purge stranded v0 rows (the missing capability — `privacyBackfill` can't do whole-doc deletes).** Add a doc-deleting sweep, NOT a field-strip. Two concrete options, ship the callable + scheduled pair mirroring `purgeKnowledgeMemory`/`backfillPrivacyPlaintextScheduled`:
- **Preferred — extend `knowledgeMemory.ts`** with `purgeLegacyKnowledgeVectors` (owner-scoped callable + a daily `onSchedule` backstop), reusing `deleteQueryInBatches` (`knowledgeMemory.ts:163-173`):
  ```ts
  // delete every v0 / pre-versioned row
  deleted += await deleteQueryInBatches(coll.where("dedupHashVersion", "==", 0));
  // ancients with no version field: page by absence is not directly queryable,
  // so also delete rows under the RETIRED embeddingModelVersion tag:
  deleted += await deleteQueryInBatches(coll.where("embeddingModelVersion", "==", "bge-small-en-v1.5"));
  ```
  The second predicate (delete-by-retired-model-tag) is what reaches pre-`dedupHashVersion` ancient rows that lack the field (Firestore can't query "field absent"), and it is safe because A3 moved all live data to the new tag. Register both in `functions/src/index.ts` next to line 160.
- Add a `firestore.indexes.json` composite index for `(embeddingModelVersion ASC)` and `(dedupHashVersion ASC)` scoped to `cloud_search_knowledge` if not present (see A7).

**A5. Retire the v0 enum + comments, lock it in the type system.** `functions/src/callables/knowledgeMemory.ts`:
- Keep `DEDUP_HASH_VERSION_LEGACY_CLEARTEXT = 0` (`:94`) **only** as the purge predicate's named constant — re-point its doc comment from "retained so existing legacy rows remain readable" to "retained ONLY as the purge predicate; v0 rows are deleted by `purgeLegacyKnowledgeVectors`, never served (knowledgeSearch + commit idempotent-skip both floor at v1)."
- Update the file-header B-SEC-2 block (`:18-43`) and the `dedupHashVersion` doc block (`:75-93`): replace "Existing legacy v0 rows remain readable until the device re-ingests" with the flag-day statement: "v0 rows are unreachable by recall (search floors `dedupHashVersion==1` and filters the new model tag) and are deleted by the v0 purge; the cleartext-SHA-256 oracle no longer exists in any served or queryable row."

**A6. Flip the test from "v0 tolerated on read" to "v0 rejected/purged end-to-end."** `functions/src/__tests__/knowledgeMemoryDedupHash.test.ts`:
- The write-path rejection cases (`:210-241`) already assert v0-write→rejected; **keep them**.
- ADD a search-path case: seed a v0 row (`dedupHashVersion: 0`, doc-id = `KNOWN_PLAINTEXT_SHA256`, `embeddingModelVersion: "bge-small-en-v1.5"`) into the in-memory `stored` map, run `searchKnowledge` at the new model tag, and assert the v0 row is **not** in `hits` (needs the fake `db` to honor the `.where("dedupHashVersion","==",1)` / model-tag filter — extend `makeDb` query stub to record `where` predicates, currently it ignores them at `:81-83`; mirror the predicate-recording pattern used in `privacyBackfill.test.ts`).
- ADD a purge case: seed one v0 row + one v1 row, run `purgeLegacyKnowledgeVectors`, assert only the v0 row (and any retired-tag row) is deleted and the v1 row survives. This is the "v0 → rejected" test flip the slice asks for, expressed on the read+purge side (the write side is already covered).

**A7. Composite indexes.** `firestore.indexes.json` — add (or confirm) a `cloud_search_knowledge` composite covering `embeddingModelVersion (==) + dedupHashVersion (==) + __name__` so A1's combined filter + `findNearest` is servable, and a single-field exemption/index for the `dedupHashVersion (==)` and `embeddingModelVersion (==)` purge queries in A4. Grep `firestore.indexes.json` for an existing `cloud_search_knowledge` vector index and extend it.

**A8. Honesty docs.** `docs/PENSIEVE.md` + `docs/pensieve-leakage-analysis.md` (referenced at `knowledgeMemory.ts:43`): update the "legacy v0 rows remain readable" line to the flag-day reality (v0 unreachable + purged). No registry change needed — `cloud_search_knowledge` is already a sealed/cloaked surface and `dedupHashVersion` is already in `OPAQUE_EXPORT_COLUMNS`.

---

### Part B — Subscription-graph cloak (opaque doc id + token-hashed `agentURI`)

**Design:** the doc id becomes a vault-keyed HMAC of `agentURI:topicID` (deterministic → unsubscribe-by-id and dedup survive); `agentURI`/`topicID` plaintext fields are replaced by `sealedAgentURI`/`sealedTopicID` (display/routing on device) plus a token-hashed `agentURIHash` only if any client query needs equality (none does today — `topic(agentURI:)` lookups run over the **already-decoded local array** `AgentBrandZoneView.swift:1066`, Android `:93`, so no Firestore query on `agentURI` is needed). `order(by:)` is preserved because it sorts on `consentGivenAt` (`AgentBrandZoneView.swift:1198`, Android `:185`), an unsealed timestamp — keep it cleartext.

**B1. iOS opaque doc id.** `OpenBurnBarMobile/.../AgentBrandZoneView.swift:1266-1270` — change `documentID(agentURI:topicID:)` from the `agentURI:topicID`-replace scheme to a vault-keyed HMAC. Reuse the existing trapdoor helper rather than inventing one: derive via `CloudVaultCrypto.tokenHashes(for: "\(agentURI):\(topicID)", keyData: vaultKey)` (`CloudVaultCrypto.swift:217`) taking the single 32-hex element, OR add a tiny `pensieveSlugHmac`-style helper `subscriptionDocID(agentURI:topicID:keyData:)` next to `pensieveSlugHmac` (`CloudVaultCrypto.swift:274`) using the same HKDF-derived key (label `"subscription-topic"`). Because `documentID` now needs the vault key, the four call sites must pass it: `setDeliveryMode` (`:1097`), `upsert` (`:1126`, already has `vaultKey`), `unsubscribe` (`:1139`), `setMuted` (`:1157`) — each already (or trivially can) resolve the key via `MobileCloudVaultKeyAccess.keyForWriting`/`keyForReading` (pattern at `:1115-1117`).

**B2. iOS seal `agentURI`/`topicID`, drop plaintext.** `encodeTopic` (`:1246-1264`): remove plaintext `"agentURI"`/`"topicID"`, add `"sealedAgentURI": dictionary(CloudVaultCrypto.sealText(topic.agentURI,…))` and `"sealedTopicID": …`. Keep `cadence`/`consentGivenAt`/delivery fields cleartext (server filter/order inputs, carry no graph identity). `decodeTopic` (`:1272-1319`): open `sealedAgentURI`/`sealedTopicID` via the existing `openSealedString` helper (`:1325-1336`) with a **legacy fallback** to plaintext `data["agentURI"]`/`data["topicID"]` so in-flight docs still decode; the `documentID` fallback for `displayName` (`:1308`) must change since the doc id is now an opaque HMAC, not human text — fall back to the opened `sealedDisplayName` only.

**B3. Android mirror.** `android/.../AgentSubscriptionTopicStore.kt`:
- `documentID(agentURI, topicID)` (`:296`) → vault-keyed HMAC via `CloudVaultCrypto.tokenHashes(text, vaultKey)` (Kotlin `CloudVaultCrypto.kt:97`) single element, or a new `subscriptionDocID` helper matching the Swift label byte-for-byte. The three call sites (`writeFirestore` `:216`, `deleteFirestore` `:225`) must thread the vault key — `writeFirestore` already resolves it (`:209-212`); `deleteFirestore` (`:221-227`) and `unsubscribe` (`:118-123`) must resolve `keyForReading`/`keyForWriting` before computing the id.
- `sealedSubscriptionTopicPayload` (`:343-352`) — replace plaintext `"agentURI"` with `"sealedAgentURI"`/`"sealedTopicID"` via `CloudVaultCrypto.sealText` + `CloudVaultSealedTextCodec.toMap`. `decodeFirestoreTopic` (`:229-245`) — open the sealed fields with legacy plaintext fallback (`data["agentURI"]`). SharedPreferences `save`/`load` (`:247-284`) stay plaintext (on-device only).

**B4. firestore.rules opaque allowlist.** `firestore.rules:1721-1736` — drop `"agentURI"`/`"topicID"` from the `hasOnly` allowlist, add `"sealedAgentURI"`/`"sealedTopicID"`, and add `validCloudSealedText(request.resource.data.sealedAgentURI)` + `validCloudSealedText(request.resource.data.sealedTopicID)` (mirroring the existing `sealedDisplayName`/`sealedDescription` lines `:1729-1730`). Keep a transition window where plaintext `agentURI`/`topicID` are still tolerated **only when the sealed copy is absent** via `rejectsPlaintextWhenSealed("agentURI","sealedAgentURI")` (`:1013`) — same pattern w3 used for display fields — then a follow-up flag-day removes them. The doc-id is now an opaque HMAC, which the rule already permits (it does not constrain `topicId` shape).

**B5. privacyBackfill field-strip.** `functions/src/callables/privacyBackfill.ts:142-148` — extend the `subscription_topics` plan to also strip legacy plaintext `agentURI`/`topicID` once sealed:
```ts
{ collection: "subscription_topics", fields: [
  { field: "displayName", requires: "sealedDisplayName" },
  { field: "description", requires: "sealedDescription" },
  { field: "agentURI", requires: "sealedAgentURI" },
  { field: "topicID", requires: "sealedTopicID" },
]},
```
Bump `PRIVACY_RESEAL_EPOCH` (`:47`) so any future watermark-aware client re-seals (note: today no client reads the watermark, so the actual reseal is driven by the natural write path in B1–B3 — call this out; do not rely on the watermark for Pensieve/subscription re-seal until a client consumer is added). **Caveat:** the opaque-doc-id migration is NOT a field strip — old docs keep their *old* (human-derived) doc id forever; `gatedDeletions` cannot re-key a doc. So old docs with the legacy doc id remain until the user toggles/re-subscribes (which `upsert` writes at the new opaque id and `unsubscribe` deletes by recomputed id). Document this residual; a one-time client-side "re-key sweep" (read all topics, rewrite each at the new opaque id, delete the old doc) in `restartRealtimeListener` is the complete solve — design it as an opt-in step, mirror the Android side.

**B6. Type honesty.** `functions/src/types/legacy.ts:3077` `SubscriptionTopicDoc` — make `agentURI?`/`topicID?` optional, add `sealedAgentURI?: CloudVaultSealedTextDoc`, `sealedTopicID?: CloudVaultSealedTextDoc` (dormant type; no server logic reads it — confirmed: only `privacyBackfill.ts:143` references the *collection name*, never the fields).

**B7. Registry honesty.** `packages/data-domains/registry.json:243` — extend the reason: "...Doc id is an opaque vault-keyed HMAC and `agentURI`/`topicID` are vault-sealed (`sealedAgentURI`/`sealedTopicID`), so the server cannot enumerate which agents a user follows." Then `node packages/data-domains/codegen.mjs` + `cd android && ./gradlew :app:syncGeneratedSources` (never hand-edit `gen/*` or `DataDomains.kt`).

**B8. Tests.** 
- Swift round-trip: `encodeTopic`→opaque-doc-id is deterministic for the same `(agentURI,topicID,key)` (so unsubscribe-by-id works) and differs across keys; `decodeTopic` opens `sealedAgentURI`/`sealedTopicID` and still falls back to legacy plaintext. 
- Kotlin round-trip: same, via `AndroidCloudVaultKeyAccess.keyForReading` + `CloudVaultCrypto.openText` + the new `documentID`. 
- `functions/scripts/test-firestore-rules.mjs` (mirror the existing `subscription_topics` cases): (a) `{sealedAgentURI,sealedTopicID,sealedDisplayName,sealedDescription}` → `assertSucceeds`; (b) `{agentURI, sealedAgentURI}` both → `assertFails` (via `rejectsPlaintextWhenSealed`); (c) legacy `{agentURI,topicID,displayName,description}`-only (no sealed) → `assertSucceeds` during transition; (d) non-allowlisted key → `assertFails`. 
- `privacyBackfill.test.ts` (`:207`): extend the seeded `subscription_topics/t1` doc to carry `agentURI`+`sealedAgentURI` and assert `agentURI` is stripped post-sweep.

---

**Cross-cutting note for both parts:** every new sealed field uses the existing `CloudVaultCrypto.sealText`/`openText` envelope and every new opaque id uses the existing `tokenHashes` HKDF-HMAC trapdoor (`CloudVaultCrypto.swift:217`, Kotlin `:97`) — **no new crypto**, consistent with the shared-crypto contract. The server stays blind store-and-forward: the only server reads are equality/inequality filters on opaque columns (`dedupHashVersion`, `embeddingModelVersion`, `consentGivenAt`) — never plaintext.

**Files with exact change points:** `functions/src/callables/knowledgeMemory.ts:75-95,193-201,295-299,461-486` (purge callable) · `functions/src/callables/knowledgeSearch.ts:89-93` · `functions/src/index.ts:160` · `functions/src/__tests__/knowledgeMemoryDedupHash.test.ts:81-83,210-242` · `firestore.indexes.json` · `OpenBurnBarCore/.../PensieveVectorCloak.swift:35` · `tools/openburnbar-mcp-remote/src/embed.ts` (`EMBEDDING_MODEL_VERSION`) · `OpenBurnBarMobile/.../AgentBrandZoneView.swift:1097,1126,1139,1157,1246-1270,1308` · `OpenBurnBarCore/.../CloudVaultCrypto.swift:274` (new `subscriptionDocID` helper) · `android/.../AgentSubscriptionTopicStore.kt:118-123,199-227,229-245,296,343-352` · `android/.../CloudVaultCrypto.kt:97` · `firestore.rules:1721-1736` · `functions/src/callables/privacyBackfill.ts:47,142-148` · `functions/src/types/legacy.ts:3077` · `packages/data-domains/registry.json:243` · `functions/scripts/test-firestore-rules.mjs` · `functions/src/__tests__/privacyBackfill.test.ts:207` · `docs/PENSIEVE.md`, `docs/pensieve-leakage-analysis.md`.