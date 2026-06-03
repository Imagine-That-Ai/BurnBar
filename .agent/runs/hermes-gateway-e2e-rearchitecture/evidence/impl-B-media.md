Everything is consistent and within my ownership. The implementation is complete:

- New sealing writer `MediaAttachmentManifestStore` (pure testable `encodeManifest` + async `persistManifest`).
- Wired at the `AppDelegate.onTransferCompleted` sink alongside the local-history append.
- Round-trip + allowlist + no-plaintext + entitlement-gate tests.

Let me do a final sanity check that `CloudVaultCrypto.decodeSealedText` (used in my test) is accessible — it's `static func` in the `extension CloudVaultCrypto` inside `FirestoreRepository.swift` (OpenBurnBarMobile module, accessible via `@testable import OpenBurnBarMobile`). It's `static func` with no access modifier (internal), so `@testable` exposes it. Good.

## CHANGELOG

**`OpenBurnBarMobile/Features/Mercury/Stores/MediaAttachmentManifestStore.swift`** (NEW, owned)
- Created the sealing Firestore writer-of-record for `users/{uid}/media_attachment_manifests/{id}` — no writer existed before this slice.
- New symbols (`@MainActor enum MediaAttachmentManifestStore`):
  - `static func persistManifest(_ completion: iOSFileTransferService.TransferCompletion, firestore:) async` — resolves uid, gates on media entitlement (skips silently if absent), resolves the vault key via `MobileCloudVaultKeyAccess.keyForWriting(uid:firestore:)`, encodes, and writes `setData(merge: false)` to the per-direction single-writer doc. Swallows seal/Firestore errors (best-effort audit; transfer already succeeded).
  - `static func encodeManifest(_:vaultKey:) throws -> [String: Any]` — pure, testable. Seals `filename` via `CloudVaultCrypto.dictionary(CloudVaultCrypto.sealText(completion.filename, keyData:))` into `sealedFilename`, OMITS plaintext `filename`, and emits the EXACT `hasOnly` key set: `id, blobHash, sealedFilename, mime, size, peerDeviceIdHash, direction, createdAt, schemaVersion` (expireAt not emitted by this writer).
  - `static let manifestSchemaVersion = 1`.
  - `static func peerDeviceIdHash(for connectionID:)` — SHA-256 hex of the iroh connection identity (opaque; never plaintext NodeId).
  - `static func direction(for:)` — phone-perspective map: `.sent → "iosToMac"`, `.received → "macToIos"`.
  - `static func blobHash(for:)` — SHA-256 hex of the local file when readable, else deterministic SHA-256 of `"connectionID:manifestId"` (guarantees non-empty `blobHash is string`); the manifest's BLAKE3 hash is not carried on `TransferCompletion`.
  - `static func hasActiveHostedMediaEntitlement(uid:firestore:) async` + `static func isActiveMediaEntitlement(_:)` — mirror the rule's `hasActiveHostedMediaEntitlement`/`activeMediaEntitlementData` (checks `hosted_media_sync`, `pro_max`, `burnbar_pro_max` entitlement docs; `active==true && expireAt>now`; product allowlist left to the server rule).
- Reuses existing crypto only (`CloudVaultCrypto.sealText`/`dictionary`); mirrors the `BudgetRulesStore` seal pattern.

**`OpenBurnBarMobile/App/AppDelegate.swift`** (owned)
- At the `receiver.onTransferCompleted` sink (~:59-76), added `await MediaAttachmentManifestStore.persistManifest(completion)` after the existing `MercuryTransferHistoryStore.shared.append(...)` (inside the same `Task { @MainActor in ... }`), so every completed transfer also writes the sealed cloud manifest. Local-history behavior unchanged.

**`OpenBurnBarMobileTests/Media/MediaAttachmentManifestStoreTests.swift`** (NEW, owned)
- Round-trip + hardening tests (`@MainActor final class MediaAttachmentManifestStoreTests`):
  - `test_encodeManifest_sealsFilename_writesNoPlaintext` — `sealedFilename` present (canonical `{algorithm, keyVersion, nonce, ciphertext, tag}` envelope), no `filename`.
  - `test_encodeManifest_emitsOnlyAllowlistedKeys` — asserts every emitted key is in the `firestore.rules` `validMediaAttachmentManifestKeys` allowlist; checks required invariants.
  - `test_encodeManifest_roundTripsSealedFilename` — `CloudVaultCrypto.openText(decodeSealedText(doc["sealedFilename"]), keyData:) == filename` (incl. non-ASCII filename).
  - `test_direction_mapsPhonePerspective`, `test_peerDeviceIdHash_isOpaqueSha256_neverPlaintext`, `test_blobHash_hashesLocalFileWhenAvailable`, `test_blobHash_deterministicFallbackWhenNoLocalFile`, `test_isActiveMediaEntitlement_requiresActiveAndUnexpired`.

**Deviations / notes**
- `TransferCompletion` (in `iOSFileTransferService.swift`, NOT owned by this stream) does not carry `blobHash` or the peer NodeId. I therefore derive `peerDeviceIdHash` from `completion.connectionID` (SHA-256) and `blobHash` from the local file contents / deterministic fallback rather than the manifest's BLAKE3 ticket hash. Both satisfy the rule's `is string` invariants. If a future change wants the iroh BLAKE3 `blobHash` and raw peer NodeId in the doc, those fields must first be plumbed onto `TransferCompletion` (a `B-*`/media-transport edit, outside this slice's ownership).
- The iOS sink is the single writer-of-record for BOTH directions it observes (`iosToMac` on send, `macToIos` on receive), respecting `allow update: if false` (shared `manifestId` written once).
- Entitlement gate IDs (`hosted_media_sync`, `pro_max`, `burnbar_pro_max`) mirror the rule's `hostedMediaEntitlementPath`/`burnBarProMaxEntitlementPath`; the client gate is permissive on `productID` so a paid user is never wrongly skipped, with the rule as the hard authority.
- No project.yml edit needed — both `OpenBurnBarMobile` and `OpenBurnBarMobileTests` targets glob their directories in XcodeGen, so the new files are picked up automatically.

**Cross-stream dependencies (informational, not edited here)**
- B-rules owns the flag-day rule drop in `firestore.rules:2792-2834` (remove plaintext-`filename` branch) and the T9 test flip in `test-firestore-rules.mjs` — this writer is already clean (always seals, never co-emits `filename`), so it is compatible with both the current rule and the post-drop rule.
- B-honesty owns `registry.json` media-domain `filename → deviceOnly` + scanner coverage; this writer emits no plaintext `filename`, satisfying that honesty label.
- `functions/src/types/legacy.ts:2702-2721` (`MediaAttachmentManifestDoc`) is already sealed-ready (`sealedFilename?: CloudVaultSealedTextDoc`, `filename?` deprecated) — no change required and not owned here.

No blockers. `node --check`/`py_compile` not applicable (Swift-only stream); builds/tests run centrally.