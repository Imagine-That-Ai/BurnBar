Confirmed: codegen only consumes `reg.domains` (not `excludedCollections`), so the honesty label fix is a documentation-only registry.json edit with no generated downstream. Recon is complete. Here is the design brief.

---

# RECON: `approval_policies` private-text leak

**Surface:** `users/{uid}/approval_policies/{policyId}` — class-based "yes always for X" approval rules (Hermes Square §6.9), synced cross-device via Firestore.

## (1) WRITERS — exact plaintext private fields

- **iOS** `OpenBurnBarMobile/Services/ApprovalPolicyStore.swift` — the ONLY cloud writer.
  - `cloudUpsert(_:)` → `setData(payload, merge: false)` at `:198-201`.
  - `encode(_:)` at `:227-245` writes plaintext: **`displayLabel`** (`:230`), **`targetProject`** (`:240`), **`fileGlob`** (`:238`). Also writes non-private discriminators `missionKind`/`toolName`/`runtimeID` and `id` (the class hash, which itself bakes `glob=`+`project=` in cleartext — see below), `decision`, `createdAt`, `expiresAt`, `matchCount`, `schemaVersion`.
- **Mac (AgentLens):** NONE. Grep of `AgentLens/**` for `approval_policies` / `ApprovalPolicyStore` / `ApprovalPolicy(` returns empty. The Mac compiles the shared model `OpenBurnBarCore/.../ApprovalPolicy.swift` only as a type; `InsightMissionApprovalPolicy` (`CLIAgentMissionRequestListener.swift:1323`) and `targetProject` (`:538`) belong to the separate `cli_agent_mission_requests` collection, NOT this one.
- **Android** `android/app/src/main/java/com/openburnbar/data/missions/ApprovalPolicyStore.kt` — writes ONLY to `SharedPreferences` (`save()` `:116-136`); comment `:19-20` confirms "Cloud mirror is omitted on Android." No cloud write today → no Android cloud change required, but its codec must gain a sealed-read branch when the cloud path is added (note as [follow-up], not this pass).

**HIDDEN LEAK — the document ID:** `ApprovalPolicy.classHash` (`OpenBurnBarCore/.../ApprovalPolicy.swift:79-96`) builds the `id` as `"decision=…|mk=…|tool=…|glob=<fileGlob>|runtime=…|project=<targetProject>"` in cleartext, and `cloudUpsert` uses `safeDocumentID(policy.id)` (`:200`, only swaps `/`→`_`) as the Firestore document name. So `targetProject` and `fileGlob` leak **in the doc ID itself**, not just the fields. Sealing the fields alone does NOT close the leak. The ID must become an opaque keyed hash.

## (2) READERS

- **iOS** `ApprovalPolicyStore.decode(documentID:data:)` `:247-269`, called from the snapshot listener `restartCloudListener` `:120-136`. Reads `displayLabel`/`targetProject`/`fileGlob` back as plaintext.
- **Matcher (client-side only):** `ApprovalAskClassifier.resolve(against:)` → `ApprovalPolicy.matches(...)` (`OpenBurnBarCore/.../ApprovalPolicy.swift:103-123`) compares `targetProject == targetProject` and `matchGlob(fileGlob, path)` **entirely in-memory on the iOS device** after decode. Callers: `HermesSquareRoot.swift:65`, `HermesSquareSplitLayout.swift:615`, `ApprovalPolicyStore.resolve` `:76-86`. No server involvement.
- No web/console reader, no Android cloud reader.

## (3) SERVER-READ REQUIREMENT — **NONE (pure store-and-forward)**

- Repo-wide grep: `approval_policies` appears in `functions/**` **zero** times. No callable, no `onDocumentWritten`/`onDocumentCreated`/`onDocumentUpdated` trigger references this path.
- The lone `functions/src/types/legacy.ts:3034 targetProject?: string` is field `CLIAgentMissionRequestDoc.targetProject` (`:3027-3034`), a different collection — **not** `approval_policies`.
- Matching is provably client-side (§2). **Proof quote** (`ApprovalPolicy.swift:120-121`): `if let r = self.runtimeID, r != runtimeID { return false }` / `if let p = self.targetProject, p != targetProject { return false }` — comparison runs in the Swift model on-device.
- **Verdict: SEAL everything. The server never reads these fields.** A `projectKeyHash` trapdoor is **not required** for server logic — but include it (and a `fileGlobHash`) so the client/document-ID can stay collision-stable without decrypt; see §5.

## (4) VAULT-KEY AVAILABILITY (every reader)

- Only reader is iOS. iOS holds the key via `OpenBurnBarMobile/Services/MobileCloudVaultKeyAccess.swift` — `keyForWriting(uid:)` `:26` (async, write path), `keyForReading(uid:)` `:55` (async, returns `nil` if not yet escrowed), and synchronous `CloudVaultKeyStore().loadKey(uid:)` (used by `BudgetRulesStore.cachedVaultKey()` `:367`) for the snapshot-listener decode that cannot `await`. `MobileCloudVaultResolvedKey` exposes `.keyData`/`.vaultKeyID`. All three are usable from `ApprovalPolicyStore` (same `@MainActor` actor). The server (only non-key-holder) is never a reader → store-and-forward sealing is correct.

## (5) FIRESTORE.RULES — current allowlist + exact change

**Current** (`firestore.rules:1603-1623`): `validApprovalPolicy()` `hasOnly(["id","displayLabel","decision","missionKind","toolName","fileGlob","runtimeID","targetProject","createdAt","expiresAt","matchCount","schemaVersion"])` with `displayLabel is string && <=256`, `fileGlob is string && <=256`, `targetProject is string && <=512`.

**Change** (mirror the `usage`/`budgetRules` `rejectsPlaintextWhenSealed` pattern at `:1013-1038`; reuse `validCloudSealedText` `:449`):

```
function validApprovalPolicy() {
  return request.resource.data.keys().hasOnly([
    "id", "displayLabel", "decision", "missionKind", "toolName",
    "fileGlob", "runtimeID", "targetProject",
    "sealedDisplayLabel", "sealedFileGlob", "sealedTargetProject",
    "projectKeyHash", "fileGlobHash",
    "createdAt", "expiresAt", "matchCount", "schemaVersion"
  ])
  && request.resource.data.decision in ["approve", "deny"]
  // sealed-migration gate: reject plaintext once its sealed copy is present
  && rejectsPlaintextWhenSealed("displayLabel", "sealedDisplayLabel")
  && rejectsPlaintextWhenSealed("fileGlob",     "sealedFileGlob")
  && rejectsPlaintextWhenSealed("targetProject","sealedTargetProject")
  // legacy plaintext stays bounded while present
  && (!("displayLabel"  in request.resource.data) || (request.resource.data.displayLabel is string && request.resource.data.displayLabel.size() <= 256))
  && (!("fileGlob"      in request.resource.data) || (request.resource.data.fileGlob is string && request.resource.data.fileGlob.size() <= 256))
  && (!("targetProject" in request.resource.data) || (request.resource.data.targetProject is string && request.resource.data.targetProject.size() <= 512))
  && (!("missionKind"   in request.resource.data) || request.resource.data.missionKind is string)
  && (!("toolName"      in request.resource.data) || request.resource.data.toolName is string)
  && (!("runtimeID"     in request.resource.data) || request.resource.data.runtimeID is string)
  // sealed envelopes are well-formed when present
  && (!("sealedDisplayLabel"  in request.resource.data) || validCloudSealedText(request.resource.data.sealedDisplayLabel))
  && (!("sealedFileGlob"      in request.resource.data) || validCloudSealedText(request.resource.data.sealedFileGlob))
  && (!("sealedTargetProject" in request.resource.data) || validCloudSealedText(request.resource.data.sealedTargetProject))
  && (!("projectKeyHash" in request.resource.data) || request.resource.data.projectKeyHash.matches("^[a-f0-9]{32}$"))
  && (!("fileGlobHash"   in request.resource.data) || request.resource.data.fileGlobHash.matches("^[a-f0-9]{32}$"))
  && (!("matchCount"     in request.resource.data) || request.resource.data.matchCount is int);
}
```
(`displayLabel` becomes optional since it's no longer always plaintext; keep `read`/`delete` lines unchanged at `:1620,1622`.)

## (6) REGISTRY DOMAIN OWNER + honesty edit

`approval_policies` is in `packages/data-domains/registry.json:241` under **`excludedCollections`** with the label **`"Local policy config."`** — this is **dishonest**: the collection is mirrored to Firestore (iOS `cloudUpsert`) carrying plaintext project/glob/label. Codegen consumes only `reg.domains`, never `excludedCollections` (`codegen.mjs:42-49`), so this is a documentation-only edit with no generated downstream — but it must be corrected:

```
"approval_policies": "Cross-device approval rules (the 'yes always for X' learning). Synced to Firestore from iOS; project paths, file-glob patterns, and the user label are sealed with the per-user vault key (sealedTargetProject/sealedFileGlob/sealedDisplayLabel) and the document ID is an opaque keyed hash. Server never sees plaintext or runs matching.",
```
Per CONTRACT §8, run `node packages/data-domains/codegen.mjs` after editing registry.json (no-op for this label, but keeps the pipeline clean). Owned by stream **SE (Honesty)**.

## (7) TESTS TO ADD

- **Rules** (`functions/scripts/test-firestore-rules.mjs`, mirror T12 `:3110-3163`): "approval_policies rejects plaintext private text when sealed copy present" — legacy plaintext-only doc `succeeds`; sealed doc (`sealedTargetProject`/`sealedFileGlob`/`sealedDisplayLabel` = `sealedText()`, `projectKeyHash`/`fileGlobHash` = 32-hex, opaque doc ID) `succeeds`; doc carrying both `sealedTargetProject` + `targetProject` `fails`; same for `fileGlob`/`displayLabel`; bad hash (`!= ^[a-f0-9]{32}$`) `fails`; unknown extra key `fails` (hasOnly).
- **iOS** (`OpenBurnBarCoreTests`, alongside `HermesSquarePhaseBTests.swift`): round-trip — `encode` seals fields and emits opaque doc ID; `decode` opens via `openSealedProjectName(...,sealedField:"sealedTargetProject",legacyField:"targetProject",...)`; legacy plaintext-only doc still decodes (fallback); sealed-but-no-key returns `nil` (no leak); `ApprovalPolicy.matches` still resolves after seal→open round-trip (matcher unaffected).
- **Migration test:** writing a sealed policy deletes the legacy cleartext-ID doc when the new opaque ID differs (mirror project_memory client-side delete intent).

---

## DESIGN BRIEF

1. **iOS writer** `OpenBurnBarMobile/Services/ApprovalPolicyStore.swift` `encode(_:)` `:227-245`: replace plaintext `displayLabel`(`:230`)/`targetProject`(`:240`)/`fileGlob`(`:238`) with sealed envelopes using the EXISTING extension helpers (`OpenBurnBarMobile/Services/FirestoreRepository.swift:1020-1059`): `data["sealedDisplayLabel"] = try CloudVaultCrypto.dictionary(CloudVaultCrypto.sealText(label, keyData: vaultKey))`; same for `sealedTargetProject` (from `targetProject`) and `sealedFileGlob` (from `fileGlob`). Add `data["projectKeyHash"] = CloudVaultCrypto.projectKeyHash(for: targetProject, keyData: vaultKey)` and a sibling `fileGlobHash` via `CloudVaultCrypto.tokenHashes(for:normalized fileGlob, keyData:, limit:1).first`. `encode` must become instance/async-fed so it receives a `vaultKey: Data` (thread it like `BudgetRulesStore.encodeRule(_:vaultKey:)` `:202`). NO new crypto — reuse `sealText`/`tokenHashes` only.

2. **Opaque document ID** `ApprovalPolicyStore.cloudUpsert` `:200` + `cloudDelete` `:212`: stop using `safeDocumentID(policy.id)` (the cleartext `glob=…|project=…` hash). Derive an opaque ID from the keyed trapdoor — `CloudVaultCrypto.tokenHashes(for: policy.id, keyData: vaultKey, limit:1).first` (32-hex), prefixed e.g. `"ap_"`. On upsert, also delete the legacy cleartext-ID doc when it differs (client-side migration, mirror CONTRACT §2 project_memory pattern). Keep `id` field inside the doc sealed-irrelevant or drop it from the payload (it is the class hash and itself leaks — prefer dropping the top-level `id` field, keeping only the opaque doc name).

3. **iOS reader** `ApprovalPolicyStore.decode(documentID:data:)` `:247-269`: open with legacy fallback via the generic helper — `let label = CloudVaultCrypto.openSealedProjectName(from: data, sealedField:"sealedDisplayLabel", legacyField:"displayLabel", keyData: vaultKey)`; same for `sealedTargetProject`/`targetProject` and `sealedFileGlob`/`fileGlob`. Thread `vaultKey: Data?` into `decode` from the listener using the synchronous `CloudVaultKeyStore().loadKey(uid:)` (copy `BudgetRulesStore.cachedVaultKey()` `:367`). Sealed-but-no-key → `nil` field (helper already does this at `FirestoreRepository.swift:1055-1056`).

4. **firestore.rules** `:1603-1623`: replace `validApprovalPolicy()` with the block in §5 — add 5 keys to `hasOnly` (`sealedDisplayLabel`,`sealedFileGlob`,`sealedTargetProject`,`projectKeyHash`,`fileGlobHash`), make `displayLabel` optional, add three `rejectsPlaintextWhenSealed(...)` gates (helper already at `:1013`), `validCloudSealedText` checks on each sealed field, and `^[a-f0-9]{32}$` on both hashes. Reuse existing helpers — no new rule functions.

5. **registry.json** `:241`: rewrite the `excludedCollections.approval_policies` label from `"Local policy config."` to the honest string in §6 (it IS cloud-synced + now sealed). Run `node packages/data-domains/codegen.mjs` after (no-op downstream, but per CONTRACT §8).

6. **Tests** per §7: rules harness T-block (mirror `test-firestore-rules.mjs:3110`), iOS seal/open round-trip + matcher-unaffected test, migration doc-ID-swap test.

7. **Android** `ApprovalPolicyStore.kt`: no cloud writer today (local-only), so no leak from Android. When the deferred cloud-sync path lands, its codec must mirror items 1–3 using `CloudVaultCrypto.kt sealText`/`openText` + `CloudVaultCryptoSearch.kt tokenHashes`. Flag as [follow-up], out of scope this pass.

**SERVER-READ VERDICT: none** — `approval_policies` has zero references in `functions/**`, no trigger, no callable; matching runs client-side in `ApprovalPolicy.matches()`. Seal all three private fields with the vault key AND make the document ID an opaque keyed hash (the cleartext class-hash ID is the larger leak). `projectKeyHash`/`fileGlobHash` are included for stable client-side bucketing only, not for any server logic.