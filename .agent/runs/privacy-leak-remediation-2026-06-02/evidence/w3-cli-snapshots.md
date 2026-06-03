Confirmed. `grep` for the three fields in `functions/src` returned EXIT 1 (no matches) — definitive proof no Cloud Function reads them. The snapshots are written exclusively by the (not-yet-implemented) Mac claimed-device writer and read by the two mobile RollbackService listeners; `restoredAt` is only ever read by clients (no client write-back exists yet either — that's the Mac's job on rollback completion). Test helpers `sealedText()`/`sealedBlob()` exist for the rules harness.

I have full recon. Producing the design brief.

---

# cli_sessions/{id}/snapshots — Residual Private-Text Leak Recon

## Surface
`users/{uid}/cli_sessions/{sessionId}/snapshots/{snapshotId}` — Hermes Square Phase A per-session rollback snapshot index. The Mac (claimed device) writes; iOS + Android read for the rollback picker.

Private plaintext fields today: `touchedFiles: [String]` (user working-dir relative file paths), `macSnapshotPath: String?` (local Mac filesystem path token), `actionLabel: String` (e.g. `"Edit src/foo.swift"`, `"Run npm test"` — leaks file names + commands). Non-private: `id`, `sessionID`, `sequence`, `takenAt`, `restoredAt`, `schemaVersion`.

## (1) WRITERS — exact plaintext fields written
**NONE EXIST IN THE REPO.** Exhaustive grep across `AgentLens/**` (Mac), `OpenBurnBarMobile/**` (iOS), `android/app/src/main/**`, and `functions/src/**` found **no** `setData`/`set`/`addDocument`/`batch.set` to the `snapshots` subcollection and no reference to `RollbackSnapshot` outside the contract + the two readers. The doc comments assert "the Mac writes (claimed device only)" (`firestore.rules:1645-1646`; `OpenBurnBarMobile/Services/RollbackService.swift:10-13`; `RollbackContracts.swift:5-8`) but the **writer is not yet implemented** — this is a forward-declared surface (rules + contract + readers shipped ahead of the producer).
- Field contract (the plaintext shape a future writer will emit): `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/RollbackContracts.swift:20` `actionLabel`, `:23` `touchedFiles`, `:26` `macSnapshotPath`.

## (2) READERS — plaintext decode sites
- **iOS** `OpenBurnBarMobile/Services/RollbackService.swift:33-51` (listener on `cli_sessions/{id}/snapshots` ordered by `sequence`) → decode at `:92-112`: `:97` `actionLabel`, `:99` `touchedFiles`, `:100` `macSnapshotPath`.
- **Android** `android/app/src/main/java/com/openburnbar/data/missions/RollbackService.kt:103-116` (listener) → decode `toRollbackSnapshotOrNull` at `:207-226`: `:211` `actionLabel`, `:213` `touchedFiles`, `:223` `macSnapshotPath`.
- UI consumers (no Firestore access, in-memory only): `OpenBurnBarMobile/Views/Hermes/Square/RollbackCardView.swift`, `android/.../ui/square/RollbackCardView.kt`, and `RollbackPlanner.snapshotsToRestore` (`RollbackContracts.swift:137-152`, matches on `touchedFiles` **client-side** for `singleFile` scope — local plaintext, never server).

## (3) SERVER-READ REQUIREMENT — **NONE (pure store-and-forward)**
`grep -rn "touchedFiles\|macSnapshotPath\|actionLabel" functions/src` → **exit 1, zero matches**. No Cloud Function reads, matches, routes, or indexes these fields. The only server touch is **untyped recursive deletion** for the "delete my data" path, which never inspects field contents:
> `functions/src/callables/dataDeletion.ts:83` — *"Recursive delete so nested subcollections are purged too (e.g. … cli_sessions/{id}/snapshots)."* — `recursiveDelete` operates on doc paths, not fields.

`dataExport.ts` does not enumerate the snapshots subcollection in its `conversations_chat` paths (`registry.json:37`). **Verdict: SEAL everything; no keyed-hash needed.** (Even the `singleFile` path-match is purely client-side in `RollbackPlanner`, so sealing `touchedFiles` costs the server nothing.)

## (4) VAULT-KEY AVAILABILITY — every reader holds it
- **Mac writer (future):** `CloudVaultKeyStore` (Keychain, `CloudVaultCrypto.swift:614-675`) — can `sealText`.
- **iOS reader:** `MobileCloudVaultKeyAccess.keyForReading(uid:firestore:)` (`OpenBurnBarMobile/Services/MobileCloudVaultKeyAccess.swift:55`) — **not yet imported in RollbackService.swift** (today's data is plaintext); add it.
- **Android reader:** `AndroidCloudVaultKeyAccess.keyForReading(uid, firestore)` (`android/.../data/cloud/CloudVaultCrypto.kt:256`) — **not yet imported in RollbackService.kt**; add it.
- Server: never has the key (correct — it's a non-reader). No reader is keyless.

## (5) firestore.rules — current allowlist + exact change
Current block (`firestore.rules:1647-1663`) permits plaintext `actionLabel`/`touchedFiles`/`macSnapshotPath`:
```
match /users/{userId}/cli_sessions/{sessionId}/snapshots/{snapshotId} {
  function validRollbackSnapshot() {
    return request.resource.data.keys().hasOnly([
      "id", "sessionID", "sequence", "takenAt", "actionLabel",
      "touchedFiles", "macSnapshotPath", "restoredAt", "schemaVersion"
    ])
    && request.resource.data.sequence is int && ... >= 0
    && request.resource.data.actionLabel is string && ...size() <= 512
    && request.resource.data.touchedFiles is list && ...size() <= 64;
  }
  allow read: if ownsUserNamespace(userId);
  allow create, update: if ownerWritableNonSecret(userId) && validRollbackSnapshot();
  allow delete: if ownsUserNamespace(userId);
}
```
**Change** (mirror the usage/budget `rejectsPlaintextWhenSealed` + `validCloudSealedText` pattern at `firestore.rules:1013-1022`):
- `hasOnly` set becomes: `["id", "sessionID", "sequence", "takenAt", "sealedActionLabel", "sealedTouchedFiles", "sealedMacSnapshotPath", "restoredAt", "schemaVersion"]` — i.e. drop the 3 plaintext keys, add the 3 sealed keys. **Keep legacy plaintext keys in the allowlist during migration** if you want in-flight legacy docs to keep syncing; gate each with `rejectsPlaintextWhenSealed("actionLabel","sealedActionLabel")`, `rejectsPlaintextWhenSealed("touchedFiles","sealedTouchedFiles")`, `rejectsPlaintextWhenSealed("macSnapshotPath","sealedMacSnapshotPath")`. (Because there is **no live writer yet**, you can also hard-drop the plaintext keys with zero migration risk — recommended; note this in the brief below.)
- Type-validate each sealed field: `(!("sealedActionLabel" in request.resource.data) || validCloudSealedText(request.resource.data.sealedActionLabel))`, same for `sealedMacSnapshotPath`.
- For `sealedTouchedFiles` choose ONE shape (see sizing below):
  - **Recommended: single sealed JSON blob** — seal the whole `[String]` array as one `CloudVaultSealedText` (the 64×path array is well under the 8192-char ciphertext cap in `validCloudSealedText`, `:473`): `(!("sealedTouchedFiles" in request.resource.data) || validCloudSealedText(request.resource.data.sealedTouchedFiles))`. Simpler, hides count.
  - Alternative (per-element): `sealedTouchedFiles is list && size() <= 64 && all-elements validCloudSealedText` — Firestore rules can't `forEach`, so this needs `hasAll`-style enumeration; **avoid**, prefer the blob.
- Keep `restoredAt`/`sequence`/`schemaVersion` validators; keep `allow read/create/update/delete` lines unchanged.

**Sizing → `sealText` (NOT `sealBlob`):** `actionLabel` ≤512, `macSnapshotPath` a single path, `touchedFiles` ≤64 paths serialized as JSON — all fit comfortably in `validCloudSealedText`'s 8192-char ciphertext limit. **Use `CloudVaultCrypto.sealText` everywhere** → this also sidesteps the recon-confirmed gap that **Android has no `sealBlob`** (Android is read-only here, but using `sealText`/`openText` keeps both readers on the supported Kotlin path: `CloudVaultCrypto.kt:67/88`). Do **not** use `sealBlob`/`sealedSnapshot`.

## (6) Registry domain + honesty edit
- **Owner:** `packages/data-domains/registry.json:37` — domain `conversations_chat` ("Conversations & Chat", `encryptionTier: end_to_end`) lists `"cli_sessions"` in `firestorePaths` (the subcollection inherits). `rollback_requests` is separately noted as `"Ephemeral job state."` (`:242`) — the sibling request collection carries no private text (`scopeJSON` is a scope enum), so it's out of scope.
- **Honesty status:** `deviceOnly` already claims `"CLI transcripts"` and `"project/file/command labels"` (`registry.json:36`) — **which today is a FALSE claim** for this subcollection, since `touchedFiles`/`actionLabel`/`macSnapshotPath` ship plaintext. **No registry text change is needed once sealed** — sealing makes the existing `deviceOnly` line truthful. If sealing is deferred, the honest edit is to remove `"project/file/command labels"` from `deviceOnly` and add it to `serverSees` with an `[incomplete]` note. (Recommend sealing, not relabeling.) After any registry edit: `node packages/data-domains/codegen.mjs` then `cd android && ./gradlew :app:syncGeneratedSources`; never hand-edit `gen/*` or `DataDomains.kt`.

## (7) Tests to add
- **Rules** (`functions/scripts/test-firestore-rules.mjs`, mirror T11/T12 at `:3073-3140` using existing `sealedText()` helper `:134`): new test "T13 cli_sessions snapshots seal action/files/path and reject plaintext when sealed" — (a) doc with `sealedActionLabel`/`sealedTouchedFiles`/`sealedMacSnapshotPath` = `sealedText()` **succeeds**; (b) doc carrying BOTH `sealedActionLabel` + plaintext `actionLabel` **fails** (and same for the other two); (c) malformed sealed envelope **fails** `validCloudSealedText`; (d) (if plaintext keys dropped from allowlist) any plaintext `actionLabel`/`touchedFiles`/`macSnapshotPath` **fails** `hasOnly`.
- **iOS** `OpenBurnBarMobileTests`: `RollbackService.decodeSnapshot` round-trip — seal a `RollbackSnapshot` with the test vault key, assert `actionLabel`/`touchedFiles`/`macSnapshotPath` open correctly; assert legacy-plaintext doc still decodes (fallback).
- **Android** `android/app/src/test/.../RollbackServiceSealedFieldsTest.kt` (mirror `BudgetRuleSealedFieldsTest.kt`): seal with `CloudVaultCrypto.sealText`, assert `toRollbackSnapshotOrNull` opens via `openText`; assert legacy plaintext path still parses.
- **Swift↔Kotlin interop:** add the 3 sealed fields to the cross-platform round-trip fixture so a Mac-sealed snapshot opens on Android (`CloudVaultCryptoTest.kt`).
- **Scanner** `scripts/privacy/scan-chat-cloud-plaintext.mjs`: add `cli_sessions/*/snapshots` with a `hasOnly([` semantic check rejecting `actionLabel`/`touchedFiles`/`macSnapshotPath` plaintext keys.

---

## DESIGN BRIEF

1. **Seal the 3 private fields with `CloudVaultCrypto.sealText` (NOT sealBlob).** Replace plaintext `actionLabel`→`sealedActionLabel`, `macSnapshotPath`→`sealedMacSnapshotPath`, and `touchedFiles`(serialize the `[String]` to JSON, seal as one)→`sealedTouchedFiles`, each a `CloudVaultSealedText` envelope `{algorithm,keyVersion,nonce,ciphertext,tag}`. Use `sealText` because Android has no `sealBlob` (recon-crypto-primitives §1) and every field fits `validCloudSealedText`'s 8192-char ciphertext cap. `sequence`/`takenAt`/`restoredAt`/`id`/`sessionID`/`schemaVersion` stay plaintext.

2. **WRITER (Mac, to be implemented): `RollbackContracts.swift:10-49` + new Mac snapshot writer.** No writer exists today — when the Mac claimed-device snapshot writer is built, it MUST emit the 3 sealed fields via `CloudVaultCrypto.sealText(_, keyData:)` (key from `CloudVaultKeyStore`), never plaintext. Bump `schemaVersion` to `2`. (Because no producer ships today, this surface can go sealed-only from day one with zero legacy-migration debt — strongly recommended.)

3. **READER iOS `OpenBurnBarMobile/Services/RollbackService.swift:92-112`:** add `MobileCloudVaultKeyAccess.keyForReading(uid:)` and, in `decodeSnapshot`, open `sealedActionLabel`/`sealedTouchedFiles`/`sealedMacSnapshotPath` via `CloudVaultCrypto.openText`; **keep a legacy fallback** to the plaintext `actionLabel`/`touchedFiles`/`macSnapshotPath` keys (`:97/99/100`) when the sealed field is absent.

4. **READER Android `android/.../data/missions/RollbackService.kt:207-226`:** add `AndroidCloudVaultKeyAccess.keyForReading(uid, firestore)` and open the 3 sealed fields via `CloudVaultCrypto.openText` in `toRollbackSnapshotOrNull`; **keep the plaintext fallback** at `:211/213/223`.

5. **RULES `firestore.rules:1647-1663`:** change `validRollbackSnapshot()` `hasOnly` to `["id","sessionID","sequence","takenAt","sealedActionLabel","sealedTouchedFiles","sealedMacSnapshotPath","restoredAt","schemaVersion"]`; for each sealed field add `(!("sealedX" in data) || validCloudSealedText(data.sealedX))`; mirror the usage block's `rejectsPlaintextWhenSealed("actionLabel","sealedActionLabel")` (× the 3 fields) IF retaining plaintext keys for migration — else drop the 3 plaintext keys outright (preferred, no live writer). Keep the `is int`/`>= 0` `sequence` validator and the read/create/update/delete lines. Pattern source: `firestore.rules:1013-1022`, helpers `validCloudSealedText:449` + `rejectsPlaintextWhenSealed:1013`.

6. **REGISTRY `packages/data-domains/registry.json:37` (domain `conversations_chat`):** no field-text change required — sealing makes the existing `deviceOnly` claim `"project/file/command labels"` (`:36`) honest for this subcollection (it is currently FALSE). Then regen: `node packages/data-domains/codegen.mjs` + `cd android && ./gradlew :app:syncGeneratedSources`.

7. **TESTS:** add rules T13 (mirror T11/T12, `test-firestore-rules.mjs:3073-3140`, helper `sealedText():134`); iOS + Android decode round-trip + legacy-plaintext-fallback tests; Swift↔Kotlin interop fixture for the 3 fields; scanner coverage in `scan-chat-cloud-plaintext.mjs` for `cli_sessions/*/snapshots`.

**SERVER-READ VERDICT: none** — `grep touchedFiles|macSnapshotPath|actionLabel functions/src` returns zero matches; the only server interaction is `recursiveDelete` (path-level, `dataDeletion.ts:83`), and the `singleFile` path-match in `RollbackPlanner` is client-side. Pure store-and-forward between the user's own devices → **SEAL all three with the vault key via `sealText`; no keyed-hash required.**