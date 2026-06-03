Confirmed. The facet-refresh path is a `merge:true` update writing only `facetFields` + `legacyPlaintextFieldDeletes` (FieldValue.delete — removes keys) + `updatedAt`. Under `merge:true`, `request.resource.data` is the **post-merge full document**, so a `hasOnly()` allowlist must cover the union of ALL manifest keys (since merge updates produce the merged resource). This is the critical correctness constraint for the allowlist.

I now have complete, file:line-precise understanding of all six surfaces, the writers, the server-read contract, the test harness, and the canonical mirror pattern. Producing the DESIGN BRIEF.

---

# RECON FINDINGS — firestore.rules hardening (denylist → hasOnly allowlist)

## 0. Canonical pattern to mirror
`validConversationMirror()` at **firestore.rules:889-942** is the gold standard: `request.resource.data.keys().hasOnly([...])` + an explicit `!hasAny([...private fields])` belt-and-suspenders + per-key type/bound checks + `validSealedPayloadForUser(userId, vaultKeyID, sealedPayload)`. The sealed-payload validator chain is `validSealedPayloadForUser` (417) → `matchesCurrentVaultKey` (410, requires `cloud_vault_state/current.status=="active"` and matching `vaultKeyID`) → `validCloudSealedPayload` (389). The sealed-text (map) validator is `validCloudSealedText` (353-381). These are the EXISTING crypto primitives to reuse — do not invent new ones.

**CRITICAL MERGE SEMANTICS:** Every writer below uses `setData(..., merge: true)`. Under Firestore rules, `request.resource.data` for a merge write is the **post-merge full document**, and `FieldValue.delete()` fields are ABSENT from `request.resource.data`. Therefore: (a) a `hasOnly()` allowlist must be the **union of every key any write path ever leaves on the doc**, and (b) keys deleted via `FieldValue.delete()` must NOT be in the allowlist (they're never present).

---

## 1. DATA FLOW + SERVER-READ + VAULT-KEY (per surface)

### A. session_logs manifest — `ownerWritableSessionLogManifest` (firestore.rules:294-307)
- **Writer (sole):** `AgentLens/Services/CloudSync/SessionLogSyncService.swift:239-272` (full create) and the **facet-refresh merge path** at `:184-188` (`facetFields` + `legacyPlaintextFieldDeletes()` + `updatedAt`, `merge:true`). No other writer (CLIAgentSessionMirror/DownloadSyncService only read/delete).
- **Server reader:** `functions/src/callables/conversationQuery.ts:137-164` `mapSessionLogManifestRow` reads ONLY: `provider, sourceType, deviceId, model, facetSchemaVersion, messageCount, userWordCount, assistantWordCount, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens, costUSD, toolTags, durationSeconds, sealedTitle, sealedBodyPreview, storagePath, bodyHash, startTime, endTime, updatedAt`. Facet filters at `:92-133`.
- **SERVER-READ REQUIREMENT:** Server reads ONLY plaintext metadata facets + sealed envelopes + storage pointers. **It never needs message body/title/projectName/workingDirectory as plaintext.** → seal/exclude, no fork.
- **VAULT-KEY:** Mac writer holds the vault key; bodies live in Storage (`.json.aesgcm`), titles/previews are `validCloudSealedText`. Readers (iOS/Mac) hold the key. ✅ sealable.

### B. session_logs chunk — `ownerWritableSessionLogChunk` (firestore.rules:334-346)
- **Writer (sole):** `SessionLogSyncService.swift:295-314` (active chunk) and `:336-351` (superseded-chunk tombstone). `merge:false` per-chunk.
- **Server reader:** none directly on `session_logs/{id}/chunks/*` (remoteMcp note at `functions/src/callables/remoteMcp.ts:129` confirms hardened cloud search keeps these empty of plaintext). Search runs off `cloud_search_chunks` (sealed). 
- **SERVER-READ:** store-and-forward; sealed snippet + token hashes only. No fork.

### C. chat_threads — `ownerWritableChatThread` / `chatThreadHasPlaintextContent` / `validChatThread` (firestore.rules:479-498)
- **Writer (sole):** `AgentLens/Services/CloudSync/ChatThreadSyncService.swift:87-124`. Base keys always written: `threadId, messageCount, createdAt, updatedAt, deviceId, contentIncluded`. When `includeContent`: adds `contentSealed, sealedSchemaVersion, vaultKeyID, sealedPayload` and `FieldValue.delete()`s `title/preview/messages`. When not: `contentSealed:false` and deletes `title/preview/messages/sealedPayload/vaultKeyID`. `merge:true`.
- **Server reader:** none. Pure cross-device mirror.
- **SERVER-READ:** store-and-forward. No fork.
- **VAULT-KEY:** writer + readers all on the user's devices, hold key. ✅ sealable. (`sealedPayload` already validated by `validChatThreadSealedContent` → `validSealedPayloadForUser`.)

### D. mobile_assistant_chats — already `hasOnly` (firestore.rules:964-1001)
- **Writer:** `OpenBurnBarMobile/Services/MobileChatHistoryStore.swift` + `android/.../data/assistants/AssistantChatHistoryStore.kt`. Already sealed (`validMobileAssistantChatMirror`, `contentSealed==true`, `validSealedPayloadForUser`). **No hardening needed; ADD A NEGATIVE TEST only** (plaintext-denial coverage gap).

### E. hermes_relay_requests + chunks — already `hasOnly` AND already sealed (firestore.rules:539-617, 1933-1943)
- **`relayRequestWrite` (539-585):** already `hasOnly` allowlist, denies `body/path/sessionId/error`, requires `payloadCiphertext` + `wrappedKey` + `relayEncryption=="p256-hkdf-sha256-aesgcm"`. **The gateway request is ALREADY SEALED.**
- **`relayChunkWrite` (588-617):** already `hasOnly`, denies `data/text/error`, requires `ciphertext`. **Already sealed.**
- **Writer:** Mac `HermesRelayHostService.swift` / iOS+Android relay clients.
- **CONCLUSION ON "gateway IF being sealed":** hermes_relay_requests is **already sealed text** (ciphertext fields, not plaintext `text`). The brief's "assume sealed" is already the live state. **No new gateway rule needed; ADD COVERAGE TESTS only** (create + update for request and chunk).

### F. media_session_events (firestore.rules:2096-2111) + media_attachment_manifests (2447-2462)
- **Schema:** `functions/src/types/legacy.ts:2588-2612` (`MediaSessionEventDoc`) and `:2644-2655` (`MediaAttachmentManifestDoc`).
- **Server reader:** `functions/src/mediaMonitoring.ts`, `functions/src/mediaQuota.ts`, `dataExport.ts:155` — aggregate counters/buckets only; never the filename for content purposes.
- **SERVER-READ:** store-and-forward audit/rollup. No fork on counters.
- **⚠️ PRIVATE-TEXT FINDING:** `MediaAttachmentManifestDoc.filename` (e.g. `"screen.png"`, test at `:618,633`) is **plaintext filename = PRIVATE TEXT per the brief**. The current rule (`firestore.rules:2453`) only requires `filename is string` — server-readable plaintext filename. **This is a real leak and must be coordinated with the gateway/sealing design** (see Product Fork F).

---

## 2. EXHAUSTIVE ALLOWLIST KEY SETS (read from the actual writers)

### A. session_logs MANIFEST `hasOnly` (union of create + facet-refresh; SessionLogSyncService.swift:239-272 + facetFields 544-565):
```
id, deviceId, provider, sessionId, sourceType, inferredTaskTitle,
bodyStorage, storagePath, sealedTitle, sealedBodyPreview, encryption, vaultKeyID,
chunkCount, searchChunkCount, byteCount, encryptedByteCount, bodyHash,
chunkSize, chunkHashes, chunkMetadataVersion, cloudSearchIndexVersion,
cloudSearchIndexedAt, updatedAt, startTime, endTime,
facetSchemaVersion, model, messageCount, userWordCount, assistantWordCount,
inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens,
costUSD, toolTags, durationSeconds
```
Notes: `inferredTaskTitle` is the literal constant `"Encrypted session"` (writer line 245) — allowed but constrain to a short string. `sealedTitle`/`sealedBodyPreview` are `validCloudSealedText` maps. `encryption` is a metadata map (`algorithm/keyVersion/vaultKeyID/tokenHashVersion/semanticHashVersion`). Keep the existing `validSessionLogFacets()` (316-332) checks. Keep belt-and-suspenders `!hasAny(["body","payloadCiphertext","ciphertext","data","text","title","snippet","terms","projectName","workingDirectory"])` (the current denylist list from `legacyPlaintextFields`, SessionLogSyncService.swift:499-510).

### B. session_logs CHUNK `hasOnly` (union of active + superseded; SessionLogSyncService.swift:295-314 + 336-351):
```
index, hash, uid, docId, conversationId, sessionId, deviceId, provider, model,
sealedSnippet, tokenHashes, semanticHashes, semanticHashVersion,
bodyStorage, storagePath, bodyHash, schemaVersion, superseded, updatedAt
```
Notes: `sealedSnippet` = `validCloudSealedText`. `superseded:true` only on tombstone path. Keep `!hasAny([...legacyPlaintextFields])`.

### C. chat_threads `hasOnly` (ChatThreadSyncService.swift:87-124):
```
threadId, messageCount, createdAt, updatedAt, deviceId, contentIncluded,
contentSealed, sealedSchemaVersion, vaultKeyID, sealedPayload
```
`title/preview/messages` are NEVER allowed (always `FieldValue.delete()` → absent). Keep `chatThreadHasPlaintextContent()` denial (479-481) and `validChatThreadSealedContent` (483-491). Convert `validChatThread`/`ownerWritableChatThread` (493-498) to ALSO enforce this `hasOnly`.

### D. media_session_events `hasOnly` (legacy.ts:2588-2612):
```
id, sessionId, feature, streamClass, startedAt, endedAt, endReason,
peerDeviceIdHash, byteCountInbound, byteCountOutbound, freezeCount,
p95RoundTripMillisBucket, p95BitsPerSecondBucket, durationBucket,
expireAt, schemaVersion
```
(Current rule 2096-2108 only checks id/feature/startedAt/schemaVersion + 4 denials → replace with full `hasOnly`.)

### E. media_attachment_manifests `hasOnly` (legacy.ts:2644-2655):
```
id, blobHash, filename, mime, size, peerDeviceIdHash, direction, createdAt,
expireAt, schemaVersion
```
(Current rule 2447-2460.) **`filename` decision deferred to Product Fork F.**

---

## 3. PRODUCT FORK F — media_attachment_manifests.filename (the ONE genuine fork)
The only surface where the right rule depends on a product call you can't derive from code alone:
- **Option F1 (seal it):** Add `sealedFilename` (`validCloudSealedText`) to the manifest, drop plaintext `filename` from the allowlist. Consequence: DSR export (`dataExport.ts:155`) and admin tooling can no longer show the human filename server-side; they'd show blobHash/mime/size only, or decrypt client-side. Matches the brief's "filenames = PRIVATE TEXT."
- **Option F2 (honest label):** Keep plaintext `filename` but bound it tightly (`size()<=256`) and document it as server-readable in the trust manifest. Consequence: filenames remain server-readable plaintext (a real, if low-sensitivity, leak). 
- **Recommendation:** F1 (seal) for consistency with the sealing model; the manifest is purely an audit record and clients already hold the vault key. If product wants server-side filename display for support, choose F2 with an explicit honest label. **This is the only decision the rules stream must get from product.**

Every other surface has NO fork: the server provably never reads the plaintext (§1), so seal/exclude is unconditionally correct.

---

## 4. GATEWAY (hermes_relay_requests) — already sealed
No new rule required. `relayRequestWrite`/`relayChunkWrite` (539-617) are already `hasOnly` + sealed (`payloadCiphertext`/`ciphertext`, `!body`/`!text`). If the gateway design later renames its sealed field, the rule already enforces the ciphertext shape. Action: **coverage tests only** (below).

---

## 5. BLAST RADIUS (lockstep)
- `firestore.rules`: edit functions at 294-307, 334-346, 479-498, 2096-2111, 2447-2462 (+ if F1: add `sealedFilename`, update `MediaAttachmentManifestDoc`).
- `functions/scripts/test-firestore-rules.mjs`: add tests (§ DESIGN BRIEF). Existing tests that MUST keep passing: 707 (chat content), 1434 (cli mirror), 1474 (conv/session-log backup), 1559 (facets), 611 (media). If F1 chosen, **update the media test at lines 611-641** (it currently writes plaintext `filename` and expects success — would break under a sealed allowlist).
- `functions/src/types/legacy.ts` (2644-2655) if F1: add `sealedFilename`, mark `filename` removed.
- Media writer (Swift, real Firestore write path — not located in `OpenBurnBarMedia/`; trace the media-monitoring sink that emits these collections before landing F1) must seal `filename`.
- `packages/data-domains/gen/*` + `website/src/data/trust.generated.ts` if the media manifest schema changes (regenerate).
- No iOS/Android writer change for A/B/C/D/E (they already write the allowlisted shapes).

---

## DESIGN BRIEF

**1. session_logs manifest — `ownerWritableSessionLogManifest` (firestore.rules:294-307).** Add `&& request.resource.data.keys().hasOnly([...])` with the 39-key set in §2.A. Keep the existing 10 `!("x" in ...)` denials and `validSessionLogFacets(...)`. Constrain `inferredTaskTitle` to `is string && size()<=64`, `sealedTitle`/`sealedBodyPreview` to `validCloudSealedText`, `encryption` to `is map`, `vaultKeyID` to `validVaultKeyID`.

**2. session_logs chunk — `ownerWritableSessionLogChunk` (firestore.rules:334-346).** Add `hasOnly([...])` with the 19-key set in §2.B. Keep the 10 denials. Constrain `sealedSnippet` to `validCloudSealedText`, `tokenHashes`/`semanticHashes` to `validCloudSearchHashes`.

**3. chat_threads — `validChatThreadSealedContent`/`ownerWritableChatThread` (firestore.rules:483-498).** Add `request.resource.data.keys().hasOnly([threadId, messageCount, createdAt, updatedAt, deviceId, contentIncluded, contentSealed, sealedSchemaVersion, vaultKeyID, sealedPayload])` AND keep `!chatThreadHasPlaintextContent()` (no `messages/title/preview`). Wire into `ownerWritableChatThread` (951).

**4. media_session_events (firestore.rules:2098-2108).** Replace the 4-field check with `hasOnly([...])` (16-key set §2.D) + bucketed-enum constraints from the schema. Keep `update/delete: if false`.

**5. media_attachment_manifests (firestore.rules:2449-2460).** Replace with `hasOnly([...])` (§2.E). **DECIDE FORK F:** F1 → swap `filename` for `sealedFilename` (`validCloudSealedText`) and update test 611-641 + `legacy.ts:2644`; F2 → keep `filename is string && size()<=256`.

**6. gateway (hermes_relay_requests):** no rule change — already sealed.

**TESTS to add to `functions/scripts/test-firestore-rules.mjs`** (conventions: top-level `test("…", async () => {…})`; `authedDb(uid)`; `seedCloudVaultState(uid)` before any `sealedPayload()` write; `seedHostedCloudEntitlement(uid)` for backup-gated paths; `assertSucceeds(setDoc(...))` / `assertFails(...)`; merge updates via `setDoc(doc(...), patch, { merge: true })`):

- **T1 hermes_relay_requests create+update:** seed entitlement + `pi_agent`/connection not needed (own collection); mirror lines 2149-2208 but on `users/u/hermes_relay_requests/req-1` + `…/chunks/00000000`. Assert plaintext `body`/`text`/`data` fail; `payloadCiphertext`+`wrappedKey`+`relayEncryption` succeed; then a second `setDoc(..., {merge:true})` update (status `pending`→`streaming`) succeeds, and an update injecting `body:"leak"` fails.
- **T2 mobile_assistant_chats plaintext denial:** `seedCloudVaultState`; `assertSucceeds` sealed doc (shape from 964-994); `assertFails` adding `messages`/`title`/unlisted `summary` key.
- **T3 session_logs manifest unlisted-key denial:** `seedHostedCloudEntitlement`; `assertSucceeds` the §2.A shape; `assertFails` each of: an arbitrary unlisted key `{...facetBase, smuggled:"x"}`, plus `body`/`title`/`projectName` (some already covered at 1614-1627 — add the arbitrary-unlisted-key case).
- **T4 session_logs chunk unlisted-key denial:** `assertSucceeds` §2.B shape; `assertFails` `{...chunk, smuggled:"x"}` and `{...chunk, text:"leak"}`.
- **T5 update-path plaintext (create sealed, then update adding plaintext) for conversations:** create the sealed doc (1478-1514), then `setDoc(..., {projectName:"BurnBar"}, {merge:true})` → `assertFails`.
- **T6 update-path plaintext for cli_sessions:** create sealed (1440-1455), then merge-update adding `summary:"leak"`/`title:"leak"` → `assertFails`.
- **T7 update-path plaintext for session_logs:** create sealed manifest, then merge-update adding `workingDirectory`/arbitrary key → `assertFails` (catches the merge-semantics regression where a later partial write smuggles a key past a create-only check).
- **T8 media_session_events unlisted-key denial:** seed `seedBurnBarProMaxEntitlement`; `assertSucceeds` full §2.D shape; `assertFails` arbitrary unlisted key.
- **T9 (if F1) media_attachment_manifests sealed filename:** `assertSucceeds` with `sealedFilename` map; `assertFails` plaintext `filename`. Update existing test 611-641 accordingly.

**Key implementation guardrail for the rules author:** because all writers use `merge:true`, validate the `hasOnly` set against the **union of every write path's resulting document** (create + facet-refresh for manifests; content/no-content for chat_threads). Do NOT add `FieldValue.delete()` keys (`title`/`preview`/`messages` on chat_threads; the 10 `legacyPlaintextFields` on manifest/chunk) to any allowlist — they are absent from `request.resource.data` and must stay denied via `!hasAny(...)`.