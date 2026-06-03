Confirmed: `requiredIdentifier` lowercases and keeps `[a-z0-9_-]`. My `pm_` + 32-lowercase-hex docID passes through completely unchanged (underscore is allowed, all hex is `[a-z0-9]`). No server-validator change needed for the docID format.

All my owned files are complete and self-consistent. The implementation is done. Here is my changelog.

## CHANGELOG

### `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift`
Added 3 public crypto helpers + 2 private HKDF subkey derivations, mirroring the existing `searchKey`/`tokenHashes` HKDF→HMAC→hex pattern (no new AES/HKDF/HMAC):
- `projectMemoryDocID(forSlug:keyData:) -> String` — returns `"pm_" + HMAC_SHA256(docIDKey, slug).prefix(16).hex` (32 hex). Private `projectMemoryDocIDKey(from:)`: `HKDF<SHA256>` salt `"OpenBurnBar-DocID-Salt-v1"`, info `"OpenBurnBar-ProjectMemory-DocID-v1"`, 32B. Output passes the server's unchanged `requiredIdentifier` `[a-z0-9_-]` filter (verified).
- `pensieveDedupHash(_:keyData:) -> String` — full 64-hex `HMAC_SHA256` of plaintext under a per-user key from `pensieveDedupKey(from:label:"content")` = `HKDF<SHA256>` salt ∅, info `"pensieve-dedup:content"`. Byte-parity with `functions/src/__tests__/knowledgeMemoryDedupHash.test.ts:110-114`.
- `pensieveSlugHmac(_:keyData:) -> String` — same recipe with info `"pensieve-dedup:slug"`.

### `AgentLens/Services/CloudSync/SessionLogSyncService.swift`
- `uploadProjectMemorySnapshot`: now sends opaque `"docID": projectMemoryDocID(forSlug: snapshot.projectSlug, keyData: vaultKey)`; **dropped** plaintext `"projectSlug"` and `"projectDisplayName"` (both already inside `sealedSnapshot`). Adds `"legacyDocID": snapshot.projectSlug` when `projectSlug != docID` to drive the client-side migration delete of the old plaintext-slug doc.
- `fetchCloudProjectMemorySnapshot`: derives `docID` from the candidate slug + vault key and looks up by `["docID": docID]`. **LEGACY FALLBACK**: if the docID lookup returns no `sealedSnapshot`, retries with `["projectSlug": projectSlug]` so in-flight/legacy docs still render during migration. Body decode unchanged.

### `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/PensieveKnowledgeChunker.swift`
- `PensieveKnowledgeVector`: removed `contentHash` + `sourcePath`; added `dedupHash`. (init signature changed accordingly.)
- `PensieveKnowledgeBatch`: added `slugHmac`. (init signature changed.)
- `prepareBatch`: computes batch `slugHmac = pensieveSlugHmac(sourceSlug)`; per chunk computes `dedupHash = pensieveDedupHash(trimmed)`, sets `vectorId = dedupHash`, dedups within-batch on `dedupHash`. Real path still sealed into `sealedMetadata` (`source_path`) only. No cleartext side channels emitted.

### `AgentLens/Services/CloudSync/KnowledgeSyncService.swift`
- Batch `encode`: now emits `"slugHmac": batch.slugHmac` (keeps `sourceSlug` as the server-internal manifest key, per recon/contract).
- Vector `encode`: emits `"dedupHash": vector.dedupHash`; **removed** `"contentHash"` and `"sourcePath"`.

### `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/PensieveKnowledgeWatcher.swift` — **OUT-OF-ENUMERATED-OWNERSHIP EDIT (flagged)**
This file is a real production device writer (folder-watch → commit-queue) that directly constructs `PensieveKnowledgeBatch`/`PensieveKnowledgeVector` and re-encodes them. My struct change is a hard compile-break for it. It is owned by **no stream** in the CONTRACT ownership map, so editing it causes no cross-stream conflict (the exact risk the ownership rule guards against). I made it consistent with the new shape: `trimmedBatch` now passes `slugHmac: batch.slugHmac`; its private `encode` now emits `slugHmac`/`dedupHash` and drops `contentHash`/`sourcePath`. **Action for orchestrator**: confirm this file should travel with S1; if a stream is meant to own it, reassign — but it must ship together or the daemon target won't build.

### Tests
**`OpenBurnBarCore/Tests/OpenBurnBarCoreTests/CloudVaultCryptoTests.swift`** — added 3 tests:
- `test_projectMemoryDocID_isDeterministicOpaqueAndKeySensitive` — determinism, distinct-slug/distinct-key divergence, `^pm_[a-f0-9]{32}$` shape, no plaintext slug, and independent recomputation of the documented HKDF→HMAC recipe.
- `test_pensieveDedupHash_isVaultKeyedDeterministicAndNotPlaintextSHA256` — per-user divergence, 64-hex, ≠ keyless SHA-256 (no oracle), parity with the server test's derivation.
- `test_pensieveSlugHmac_isVaultKeyedDeterministicAndDistinctFromDedupHash` — determinism, key/slug sensitivity, content/slug domain separation, derivation parity.

**`OpenBurnBarCore/Tests/OpenBurnBarCoreTests/PensieveKnowledgeChunkerTests.swift`**:
- Rewrote `test_prepareBatch_sealsTextAndProducesCommitShape` to assert `vectorId == dedupHash`, `dedupHash` is the vault-keyed HMAC of the decrypted chunk (and ≠ its keyless SHA-256), and `batch.slugHmac` matches the helper. Path still only inside sealed metadata.
- Added `test_preparedBatch_carriesKeyedColumnsAndNoCleartextSideChannels` — asserts keyed columns present, the secret path absent from cleartext struct fields, present only inside `sealedMetadata`. (Operates on the public struct rather than `KnowledgeSyncService.encode`, which is in the app target and not visible to `OpenBurnBarCoreTests` — the encoder is a verbatim pass-through of these exact fields.)
- Updated the `dedupesIdenticalChunks` comment (now keys on `dedupHash`).

**`AgentLensTests/Support/CloudSyncTestSupport.swift`** (project-memory fake only — S1 scope):
- `FakeSessionLogEncryptedCloudClient.commitEncryptedProjectMemorySnapshot` now records every payload in `projectMemoryCommits` and stores the sealed snapshot under its `docID` (or legacy `projectSlug`); honors `legacyDocID` by deleting the legacy entry (mirrors the migration).
- `getEncryptedProjectMemorySnapshot` now resolves by `docID` first then legacy `projectSlug`, returning `["snapshot": ...]` (or `NSNull`), so the writer/reader docID round-trip and legacy fallback are exercisable. (Did not touch usage fakes.)

### Deviations / blockers / notes
- **Out-of-ownership edit** of `OpenBurnBarDaemon/.../PensieveKnowledgeWatcher.swift` was unavoidable (it consumes the changed shared struct; no stream owns it). Flagged above.
- **Legacy-doc delete is server-mediated** via the new `legacyDocID` field on the existing `commitEncryptedProjectMemorySnapshot` callable, keeping the delete within my owned writer file and matching the existing server-mediated-delete posture. **Dependency on SA**: the server `commitEncryptedProjectMemorySnapshot` handler (encryptedSearch.ts, SA-owned) must (a) key the doc by `docID = requiredIdentifier(data.docID)`, (b) read `slugHmac`/`dedupHash` already supported by `commitKnowledgeBatch`, and (c) honor `legacyDocID` by deleting `…/{legacyDocID}` when present. The field is additive/no-op until wired.
- **No encoder-level (AgentLensTests) wire-shape test added** for `KnowledgeSyncService.encode` because `CloudSyncServiceTests.swift` is not in my ownership (contract scopes my AgentLensTests surface to `CloudSyncTestSupport.swift`). The struct-level test above plus the now-recording fake fully cover the privacy invariant; an upload-level `docID`-present / name-absent assertion can be added by the AgentLens-test owner using `projectMemoryCommits`.
- Kept `PensieveKnowledgeChunker.sha256Hex` (still used by the daemon watcher) and `KnowledgeIngestItem.sourcePath` (input model; sealed into metadata) — neither is a cleartext wire leak.
- Did not run builds/xcodebuild/swift (per instructions); verified by close re-read and confirmed `requiredIdentifier`/`requireHexDigest` server gates accept the new field formats unchanged.