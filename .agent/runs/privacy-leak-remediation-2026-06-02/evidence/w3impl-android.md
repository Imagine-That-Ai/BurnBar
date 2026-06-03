All correct:
- Rollback `payload["scopeJSON"]` (line 243) is in the `else` (no-key) branch only.
- Subscription plaintext writes (lines 233-234) are in the `else` branch; lines 230-231 are `FieldValue.delete()` strips in the sealed branch.
- All referenced symbols (`CloudVaultSealedTextCodec`, `AndroidCloudVaultKeyAccess`, `CloudVaultCrypto.sealText`) exist in the `:app` module.

All work is complete. Here is the changelog.

## CHANGELOG

### `android/app/src/main/java/com/openburnbar/data/missions/RollbackService.kt` (modified)
- **Imports added:** `AndroidCloudVaultKeyAccess`, `CloudVaultCrypto` (`com.openburnbar.data.cloud`), `CloudVaultSealedTextCodec` (`com.openburnbar.data.firebase`), plus `CoroutineScope`/`Dispatchers`/`SupervisorJob`/`launch`.
- **Writer `submit(...)`:** resolves the vault key via `AndroidCloudVaultKeyAccess.keyForReading` and seals `scope.asJson` → **`sealedScope`** (`CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText(...))`). Plaintext `scopeJSON` is DROPPED on the sealed path; it is written only in the no-key legacy-degrade `else` branch so un-approved devices still sync during migration.
- **Reader `toRollbackRequestOrNull(...)`:** now takes `vaultKey: ByteArray?`; opens **`sealedScope`** → legacy `scopeJSON` fallback, and **`sealedErrorMessage`** → legacy `errorMessage` fallback. Visibility widened `private`→`internal` for testability.
- **Reader `toRollbackSnapshotOrNull(...)`:** now takes `vaultKey: ByteArray?`; opens **`sealedActionLabel`** → legacy `actionLabel`, **`sealedTouchedFiles`** (sealed JSON array string, reparsed) → legacy `touchedFiles` list, **`sealedMacSnapshotPath`** → legacy `macSnapshotPath`. Visibility `private`→`internal`.
- **Listener key-threading:** added `private val ioScope` (SupervisorJob + IO). Both `startObservingSession` and `startObservingRequests` now resolve the read key in a launched coroutine before registering the listener and pass it into the decoders. Added a file-private `NoopListenerRegistration` placeholder reserved synchronously to keep the idempotency guards honest and avoid leaking listeners on stop-during-resolve.
- New sealed field names: `sealedScope`, `sealedErrorMessage`, `sealedActionLabel`, `sealedTouchedFiles`, `sealedMacSnapshotPath`. Canonical `CloudVaultSealedText` envelope `{algorithm,keyVersion,nonce,ciphertext,tag}` via `sealText`/`openText` (no `sealBlob`).

### `android/app/src/main/java/com/openburnbar/data/square/AgentSubscriptionTopicStore.kt` (modified)
- **Imports added:** same crypto trio + coroutine imports.
- **Writer `writeFirestore(...)`:** wraps the write in `ioScope.launch`, resolves the vault key, and seals `displayName` → **`sealedDisplayName`** and `description` → **`sealedDescription`**. Plaintext `displayName`/`description` are stripped via `FieldValue.delete()` on the sealed path; written only in the no-key legacy-degrade `else` branch. `agentURI`/`topicID`/cadence/etc. kept plaintext (routing key + doc-ID source).
- **Reader `decodeFirestoreTopic(...)`:** now takes `vaultKey`; delegates display-string resolution to the new seam. Listener `restartFirestoreListener` resolves the read key in `ioScope.launch` before registering, then threads it into decode.
- **New top-level `internal fun decodeSubscriptionTopicDisplay(data, vaultKey)`:** sealed-first (`sealedDisplayName`/`sealedDescription`) with legacy plaintext fallback; the production member delegates to it (zero drift, unit-testable).
- New sealed field names: `sealedDisplayName`, `sealedDescription`. SharedPreferences on-device cache left plaintext (intentional, on-device).

### `android/app/src/test/java/com/openburnbar/data/missions/RollbackServiceSealedFieldsTest.kt` (new)
Mirrors `BudgetRuleSealedFieldsTest` (stubs `android.util.Base64`→JDK). Covers: sealed `sealedScope`+`sealedErrorMessage` open + no plaintext in stored map; legacy `scopeJSON`/`errorMessage` fallback; no-key keeps sealed opaque + defaults safely; sealed snapshot `sealedActionLabel`/`sealedTouchedFiles`/`sealedMacSnapshotPath` open + no leak; legacy snapshot fallback; no-key drops sealed-only snapshot (no leak); codec round-trip with wrong-key→null.

### `android/app/src/test/java/com/openburnbar/data/square/AgentSubscriptionTopicStoreSealedFieldsTest.kt` (new)
Mirrors the same pattern. Covers: sealed `sealedDisplayName`/`sealedDescription` open + no plaintext leak; legacy fallback; no-key keeps sealed opaque (null) while legacy plaintext still resolves.

### Deviations / notes
- **Listener key threading via `ioScope`:** the briefs say "thread key into the snapshot listener." The Android listeners are non-suspend `fun` exposing `StateFlow`, while `keyForReading` is `suspend`. I resolved the key inside a launched coroutine before registering (matching the established `FirestoreRepository.listenToUsagePage` callbackFlow pattern) rather than changing the public listener signatures. A `NoopListenerRegistration` placeholder preserves the existing idempotency/stop semantics.
- **Reused `CloudVaultSealedTextCodec`** (the canonical `internal` map↔envelope helper already used by the budget-rule path) for byte-identical envelope serialization, rather than hand-rolling map conversion — reachable cross-package because both files are in `:app`.
- **No `sealBlob`** used anywhere (per hard rule); `sealedTouchedFiles` is the whole `[String]` array serialized to one JSON string and sealed via `sealText`.
- Out of my owned scope (flag separately, per the brief): firestore.rules `validRollbackRequest`/`validRollbackSnapshot`/`subscription_topics` allowlists; `legacy.ts` `SubscriptionTopicDoc` type; `registry.json` honesty edits + codegen; the latent Swift `RollbackRequest.Status` `cancelled`/`inFlight` token mismatch. No builds run (central verify follows).