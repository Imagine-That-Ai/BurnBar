All `errorMessage` grep hits in functions are unrelated (provider validation errors, log helpers, a `RollbackRequestDoc`-unrelated `legacy.ts` type). None read `users/{uid}/rollback_requests`. The grep for `scopeJSON` in functions returned empty. The `conversations_chat` domain (registry.json:30) already owns `cli_sessions` and `cli_agent_mission_requests` and lists "project/file/command labels" as deviceOnly — that is the natural honesty home for rollback (file paths + diagnostics), but rollback_requests is currently buried in `excludedCollections` as "Ephemeral job state."

I have complete recon. Here is the design brief.

---

## DESIGN BRIEF — `users/{uid}/rollback_requests` (Hermes Square Phase C)

**SURFACE:** `users/{uid}/rollback_requests/{requestId}`. Two private-text fields leak to Firestore in plaintext:
- `scopeJSON` (string ≤4096) — the rollback scope JSON. For `singleFile` scope this embeds an **absolute file path** (e.g. `{"kind":"singleFile","path":"/Users/me/file.swift"}`, proven by `RollbackServiceTest.kt:33`). `fullSession`/`lastN` carry no path but the field is uniformly sealed for consistency + future-proofing.
- `errorMessage` (string ≤2048) — Mac-written resolution diagnostic (paths/stack/error text). The contract comment (`firestore.rules:1625`) says "Mac claims and resolves"; the Mac would write this on `failed`.

### 1. WRITERS + exact plaintext fields
- **iOS** `OpenBurnBarMobile/Services/RollbackService.swift:138-150` `encodeRequest(_:)` — writes `scopeJSON` (`:143`, `String(data: JSONEncoder().encode(request.scope))`). Called from `submit(...)` `:86`. Does NOT write `errorMessage` (phone only submits `pending`).
- **Android** `android/app/src/main/java/com/openburnbar/data/missions/RollbackService.kt:175-185` `submit(...)` payload — writes `"scopeJSON" to scope.asJson` (`:179`, scope serialized by `RollbackScope.asJson` `:49-55` which JSON-escapes the path via `jsonString` `:268`). Does NOT write `errorMessage`.
- **Mac claim/respond writer: DOES NOT EXIST YET.** Exhaustive grep (`grep -rln "rollback_requests"` across `*.swift/*.kt/*.ts/*.mjs`) returns ONLY the iOS + Android files + `firestore.rules` + `registry.json`. The AgentLens "rollback" grep hits are false positives (SQLite txn rollback in `UsageStore.swift`, `ParserCheckpointStore.swift`, etc.). The "Mac claims/resolves" path (which would write `status: in_flight/completed/failed` + `resolvedAt` + `errorMessage`) is **aspirational** — comment-only. **Implication: when the Mac claim path is built, it must seal `errorMessage` → `sealedErrorMessage` from day one.** This brief specifies the contract so it lands sealed.

### 2. READERS (both decode the plaintext today; add legacy fallback)
- **iOS** `RollbackService.swift:114-136` `decodeRequest(_:)` — reads `data["scopeJSON"]` (`:117`) and `data["errorMessage"]` (`:125`). Feeds `startObservingRequests()` `:58-74` (Mac-side observe of pending/in_flight).
- **Android** `RollbackService.kt:228-254` `toRollbackRequestOrNull(...)` — reads `this["scopeJSON"]` (`:230`) and `this["errorMessage"]` (`:243`). Feeds `startObservingRequests()` `:126-145`.

### 3. SERVER-READ REQUIREMENT — **NONE (pure store-and-forward)**
- **No Cloud Function reads `rollback_requests` at all.** `grep -rn "rollback" functions/src` → empty. `grep "scopeJSON" functions` → empty. Every `errorMessage` hit in `functions/` is unrelated (provider-credential validation strings, `guards.ts:83 errorMessage()` log helper, `legacy.ts:1351/1369/3063` unrelated doc types). The doc is device↔device only (phone writes, Mac reads/claims), gated purely by `firestore.rules`. No matching/routing/indexing uses the plaintext. **Verdict: SEAL both fields with the vault key. No keyed-hash needed.**

### 4. VAULT-KEY AVAILABILITY (all readers/writers hold it)
- iOS: `MobileCloudVaultKeyAccess` (`OpenBurnBarMobile/Services/MobileCloudVaultKeyAccess.swift`) — already imported by sibling stores (`BudgetRulesStore.swift`, `ActivityStore.swift`).
- Android: `AndroidCloudVaultKeyAccess` (`CloudVaultCrypto.kt:249`) — already used by `FirestoreRepository.kt`, `ThreadInboxStore.kt`.
- Mac (future claim path): `CloudVaultKeyAccess` (`AgentLens/Services/CloudVaultKeyAccess.swift`).
All three already wire the same per-user key; rollback writers/readers can adopt it with zero new key plumbing.

### 5. firestore.rules — CURRENT (lines 1627-1643) and EXACT CHANGE
Current allowlist (`firestore.rules:1629-1638`): `hasOnly(["id","sessionID","scopeJSON","requestedAt","requestedBy","status","resolvedAt","errorMessage","schemaVersion","source"])` with `scopeJSON is string && size()<=4096` and `errorMessage is string && size()<=2048`.

**Change `validRollbackRequest()` to mirror the usage/budget `rejectsPlaintextWhenSealed` pattern (`firestore.rules:1013-1037`):**
```
function validRollbackRequest() {
  return request.resource.data.keys().hasOnly([
    "id", "sessionID", "scopeJSON", "sealedScope", "requestedAt", "requestedBy",
    "status", "resolvedAt", "errorMessage", "sealedErrorMessage", "schemaVersion", "source"
  ])
  && request.resource.data.sessionID is string
  && request.resource.data.sessionID.size() <= 256
  && rejectsPlaintextWhenSealed("scopeJSON", "sealedScope")
  && rejectsPlaintextWhenSealed("errorMessage", "sealedErrorMessage")
  && (!("scopeJSON" in request.resource.data) || (request.resource.data.scopeJSON is string && request.resource.data.scopeJSON.size() <= 4096))
  && (!("sealedScope" in request.resource.data) || validCloudSealedText(request.resource.data.sealedScope))
  && (!("errorMessage" in request.resource.data) || (request.resource.data.errorMessage is string && request.resource.data.errorMessage.size() <= 2048))
  && (!("sealedErrorMessage" in request.resource.data) || validCloudSealedText(request.resource.data.sealedErrorMessage))
  && request.resource.data.status in ["pending", "in_flight", "completed", "failed"];
}
```
- `rejectsPlaintextWhenSealed` (`firestore.rules:1013`) and `validCloudSealedText` (`firestore.rules:449`) already exist — reuse, do not redefine.
- Keep `allow read/create/update/delete` lines 1640-1642 unchanged (`ownerWritableNonSecret` + `ownsUserNamespace`).
- The gate is migration-safe: legacy docs with plaintext-only still write; a doc is rejected only once BOTH plaintext+sealed are present.

### 6. REGISTRY domain + honesty edit
- `rollback_requests` is currently **excluded** from the privacy registry — `packages/data-domains/registry.json:242` lists it under `excludedCollections` as `"Ephemeral job state."` This is **dishonest**: it carries device-private file paths + diagnostics, not just job state.
- **Owning domain = `conversations_chat`** (`registry.json:30`), which already owns `cli_sessions` + `cli_agent_mission_requests` (`firestorePaths` `:37`) and lists `"project/file/command labels"` as `deviceOnly` (`:36`).
- **Honesty edit:** (a) change `registry.json:242` from `"Ephemeral job state."` to note that scope/error text is now sealed on-device (or remove from `excludedCollections` and fold into `conversations_chat`); (b) add `"rollback_requests"` to `conversations_chat.firestorePaths` and add `"rollback scope paths"`/`"rollback error diagnostics"` to its `deviceOnly` list.
- After edit: run `node packages/data-domains/codegen.mjs` then `cd android && ./gradlew :app:syncGeneratedSources` (per CONTRACT §8 — never hand-edit `gen/*` or `DataDomains.kt`).

### 7. TESTS to add
- **Rules** (`functions/scripts/test-firestore-rules.mjs`, mirror usage/budget tests at `:3125-3152`): (a) sealed write succeeds — doc with `sealedScope`+`sealedErrorMessage` (validCloudSealedText shape) and NO plaintext; (b) `assertFails` when both `scopeJSON` + `sealedScope` present; (c) `assertFails` when both `errorMessage` + `sealedErrorMessage` present; (d) legacy plaintext-only doc still succeeds (migration safety).
- **iOS** (`OpenBurnBarCore/Tests/OpenBurnBarCoreTests/HermesSquarePhaseCTests.swift` — currently has NO scopeJSON/seal coverage): round-trip `encodeRequest` → seals `scope`→`sealedScope`; `decodeRequest` opens `sealedScope`, falls back to legacy `scopeJSON`; same for `errorMessage`/`sealedErrorMessage`.
- **Android** (`android/app/src/test/java/com/openburnbar/data/missions/RollbackServiceTest.kt`): seal `asJson`→`sealedScope`, decode-with-legacy-fallback; assert plaintext `scopeJSON` absent when sealed present.

### Change points (copy-pasteable)
1. **iOS writer** `RollbackService.swift:138-150` — in `encodeRequest`, seal `scopeJSON` string via `CloudVaultCrypto.sealText(_, keyData:)` (key from `MobileCloudVaultKeyAccess`) → emit `sealedScope: CloudVaultSealedText`, DROP plaintext `scopeJSON`. (Phone never writes `errorMessage`.)
2. **iOS reader** `RollbackService.swift:114-136` `decodeRequest` — read `data["sealedScope"]` → `openText`; fallback to legacy `data["scopeJSON"]` if absent. Same fallback for `sealedErrorMessage` → legacy `errorMessage`.
3. **Android writer** `RollbackService.kt:175-185` `submit` — seal `scope.asJson` via `CloudVaultCrypto.sealText(_, vaultKey)` (key from `AndroidCloudVaultKeyAccess`) → put `"sealedScope" to sealedPayloadMap`, DROP `"scopeJSON"`.
4. **Android reader** `RollbackService.kt:228-254` `toRollbackRequestOrNull` — open `sealedScope`; fallback to legacy `scopeJSON` `:230`. Same fallback `sealedErrorMessage`→`errorMessage` `:243`.
5. **Mac claim path (future, not built):** when implemented, seal `errorMessage`→`sealedErrorMessage` via `CloudVaultCrypto.sealText` (`CloudVaultKeyAccess`); never write plaintext `errorMessage`.
6. **Rules** `firestore.rules:1628-1639` — replace `validRollbackRequest()` per §5 (add `sealedScope`/`sealedErrorMessage` to hasOnly, add two `rejectsPlaintextWhenSealed` + two `validCloudSealedText` gates).
7. **Registry** `registry.json:242` — de-exclude / re-home into `conversations_chat` (`:30-37`) with honest deviceOnly labels; regen via codegen + gradle sync.
8. **Tests** — add the four rules cases + iOS + Android round-trip/fallback tests per §7.

**NOTE on a latent (out-of-scope) bug surfaced during recon:** the Swift `RollbackRequest.Status` enum (`RollbackContracts.swift:104-109`) has no `cancelled` case and its `inFlight` raw value serializes as `"inFlight"` (camelCase), while the rule (`firestore.rules:1637`) and Android (`RollbackService.kt:69-73`) expect `"in_flight"`/`"cancelled"`. Sealing does not touch `status`; flag separately.

**SERVER-READ VERDICT: none — no Cloud Function reads `rollback_requests`; seal `scopeJSON`→`sealedScope` and `errorMessage`→`sealedErrorMessage` with the vault key (CloudVaultSealedText + legacy plaintext fallback on read). No keyed-hash required.**