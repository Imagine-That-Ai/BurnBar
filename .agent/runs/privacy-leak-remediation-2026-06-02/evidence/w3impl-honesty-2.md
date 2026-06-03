All symbols are reachable:
- `CloudVaultProjectSealError` — target-internal (same `OpenBurnBarMobile` module).
- `generateVaultKey`/`vaultKeyID`/`sealText`/`tokenHashes`/`normalizedTokens` — `public` in Core.
- `dictionary`/`projectKeyHash`/`openSealedProjectName` — target-internal extension on `CloudVaultCrypto`.

The implementation is complete and compiles cleanly (no build run per the hard rules; symbol resolution and signature consistency verified). The test file is placed in a globbed test source dir (`OpenBurnBarMobileTests/CLIAgents/`) so XcodeGen will pick it up.

Let me write the CHANGELOG.

---

## CHANGELOG

### `OpenBurnBarMobile/Services/ApprovalPolicyStore.swift` (owned)
The iOS store is the only cloud writer for `users/{uid}/approval_policies/{docId}`. Sealed all three private-text fields and made the document ID opaque.

- **`encode(_:vaultKey:) throws -> [String: Any]`** (was `encode(_:) -> [String: Any]`): now seals the private text via `CloudVaultCrypto.sealText` + `CloudVaultCrypto.dictionary`. Emits new sealed fields and DROPS the plaintext counterparts and the top-level `id`:
  - `sealedDisplayLabel` (was plaintext `displayLabel`)
  - `sealedTargetProject` (was plaintext `targetProject`)
  - `sealedFileGlob` (was plaintext `fileGlob`)
  - `projectKeyHash` — 32-hex client-bucketing trapdoor over `targetProject` (`CloudVaultCrypto.projectKeyHash`)
  - `fileGlobHash` — 32-hex client-bucketing trapdoor over `fileGlob` (same `projectKeyHash` recipe; single-normalized-term to avoid the multi-token splitter)
  - Dropped: plaintext `displayLabel`/`targetProject`/`fileGlob` and the top-level `id` (the cleartext class hash leaked `glob=`/`project=`). Non-private discriminators `decision`/`missionKind`/`toolName`/`runtimeID`/`createdAt`/`expiresAt`/`matchCount`/`schemaVersion` stay in clear for client matching.
- **`decode(documentID:data:vaultKey:) -> ApprovalPolicy?`** (was `decode(documentID:data:)`): opens sealed fields with `CloudVaultCrypto.openSealedProjectName` (LEGACY plaintext fallback when the sealed field is absent; returns `nil`—never the legacy value—when sealed-but-no-key). The in-memory `id` is recomputed by the `ApprovalPolicy` initializer from the decoded discriminators, so client-side matching is unchanged.
- **Opaque doc ID** `opaqueCloudDocumentID(forClassHash:vaultKey:) throws -> String`: new helper returns `"ap_" + CloudVaultCrypto.tokenHashes(for: normalizedTokens(from: classHash).joined(), keyData:, limit:1).first` (32-hex). Reuses existing `tokenHashes` only.
- **`cloudUpsert`**: resolves the write key via `MobileCloudVaultKeyAccess.keyForWriting`, writes to the opaque doc id, and (client-side migration) deletes the legacy cleartext-ID doc when it differs.
- **`cloudDelete`**: resolves the read key, deletes the opaque doc (when key available) AND the legacy cleartext-ID doc.
- **`restartCloudListener`**: threads `cachedVaultKey(uid:)` (sync `CloudVaultKeyStore().loadKey(uid:)`, mirrors `BudgetRulesStore.cachedVaultKey()`) into `decode`.
- `legacyCleartextDocumentID(_:)` replaces the old `safeDocumentID`, kept only for the migration-delete path.
- `encode`/`decode`/`opaqueCloudDocumentID`/`legacyCleartextDocumentID` made `internal` (not `private`) so the matching test target can call them via `@testable import` (same pattern as `CLIAgentMissionDispatcher.cancelMissionUpdate`).

### `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/ApprovalPolicy.swift` (owned)
- **No change.** The shared model's `id`/`classHash(...)`/`matches(...)` are intentionally unchanged — matching stays fully in-memory on iOS and the in-memory class hash must remain the cleartext tuple hash (only the CLOUD doc id becomes opaque, per the brief). No sealing logic belongs in the cross-platform model.

### `OpenBurnBarMobileTests/CLIAgents/ApprovalPolicyStoreSealTests.swift` (owned, new)
Round-trip + opacity + migration + fallback coverage (mirrors `CLIAgentMissionDispatcherSealTests` style):
- `test_encode_sealsPrivateText_writesNoPlaintextFieldsOrID` — sealed envelopes present + canonical shape; no plaintext `displayLabel`/`targetProject`/`fileGlob`/`id`; `projectKeyHash`/`fileGlobHash` are 32-hex; no raw private substring (`TopSecretProject`, `glob=src`, `project=…`) survives serialization.
- `test_opaqueDocumentID_isDeterministicOpaqueHex_andNotCleartext` — `"ap_"`+32-hex, deterministic, leaks no cleartext, differs from the legacy cleartext doc id.
- `test_opaqueDocumentID_distinctClassesDoNotCollide` — two policies differing only in project name map to different ids (guards the multi-token-collapse trap).
- `test_opaqueDocumentID_differsAcrossVaultKeys`.
- `test_encodeDecode_roundTrip_preservesClassHashAndMatching` — seal→open recovers all fields, recomputes the identical `id`, and `ApprovalPolicy.matches` still resolves the same ask (matcher unaffected).
- `test_decode_legacyPlaintextDocument_stillDecodes` — pre-migration plaintext doc still decodes with key and with `nil` key (LEGACY fallback).
- `test_decode_sealedFields_withoutKey_doNotLeak` / `test_decode_sealedFields_wrongKey_doNotLeak` — sealed-but-no/wrong-key returns `nil` (no leak).

### Crypto / contract adherence
Reused existing primitives only: `CloudVaultCrypto.sealText`/`openText` (via `openSealedProjectName`), `tokenHashes`, `normalizedTokens`, `projectKeyHash`, plus the existing `dictionary`/`openSealedProjectName` extension in `FirestoreRepository.swift`. No `sealBlob`, no new crypto. Sealed envelopes are the canonical `CloudVaultSealedText {algorithm,keyVersion,nonce,ciphertext,tag}`. Every reader keeps a LEGACY plaintext fallback.

### Deviation (documented, intentional)
- **Opaque doc-id derivation differs from the brief's literal `tokenHashes(for: policy.classHash, limit:1).first`.** That literal form is **broken**: `tokenHashes` runs `normalizedTokens`, which splits the classHash (`decision=approve|mk=…|glob=…|project=…`) into many tokens and `.first` would HMAC only the first token (`"decision"`) — identical for every approve-policy → total doc-id collision, destroying the feature. I instead collapse the classHash to a single canonical term first (`normalizedTokens(from:).joined()`, exactly the established `CloudVaultCrypto.projectKeyHash` recipe) so `tokenHashes(...).first` HMACs the whole class identity. This matches the recon's explicit intent (`recon-crypto-primitives.md` lines 55/83: "feed the id string as the term"/"HMAC the id string as one term"), reuses only existing crypto, and yields a deterministic collision-free opaque `"ap_"`+32-hex id. A dedicated whole-string primitive (like `projectMemoryDocID`) would be cleaner but lives in `CloudVaultCrypto.swift`, owned by stream S1 — not mine to edit.

### Out-of-scope handoffs (other streams, per CONTRACT ownership; not edited)
- **firestore.rules `validApprovalPolicy()`** (`:1603-1623`) and **`functions/scripts/test-firestore-rules.mjs`** rules T-block → stream **SD**. Required: add `sealedDisplayLabel`/`sealedFileGlob`/`sealedTargetProject`/`projectKeyHash`/`fileGlobHash` to the `hasOnly` set, make `displayLabel` optional, add `rejectsPlaintextWhenSealed` gates + `validCloudSealedText` + `^[a-f0-9]{32}$` checks (full block in `w3-approval_policies.md` §5).
- **`packages/data-domains/registry.json:241`** honesty label (`excludedCollections.approval_policies`) + `node packages/data-domains/codegen.mjs` → stream **SE** (new honest string in §6 of the brief).
- **Android `ApprovalPolicyStore.kt`**: no cloud writer today (local SharedPreferences only) → no leak; sealed-read codec branch is a `[follow-up]` for when the cloud path lands, out of scope this pass.