## Summary

Decomposes `AgentLens/Services/CloudSync/SessionLogSyncService.swift` from 1842 lines into single-responsibility extension files while preserving the CloudSync session-log behavior as a mechanical move.

Resulting file sizes:
- `SessionLogSyncService.swift`: 773 lines
- `SessionLogSyncService+ProjectMemorySync.swift`: 126 lines
- `SessionLogSyncService+CloudReadBack.swift`: 118 lines
- `SessionLogSyncService+VaultKeyPublishing.swift`: 302 lines
- `SessionLogSyncService+DocumentIdentity.swift`: 35 lines
- `SessionLogSyncService+CloudEncoding.swift`: 57 lines
- `SessionLogSyncService+EncryptedCloudClient.swift`: 150 lines
- `CloudSyncService+SessionLogBridge.swift`: 306 lines

## Review Map

1. Start with `SessionLogSyncService.swift`: it keeps the process gate, initializer, vault-key resolution, `sync()` ordering, manifest/body upload, tombstone GC, and facet helpers.
2. Then review the single-responsibility moves:
   - `SessionLogSyncService+ProjectMemorySync.swift`: project-memory upload/readback.
   - `SessionLogSyncService+CloudReadBack.swift`: cloud manifest/body fetch.
   - `SessionLogSyncService+VaultKeyPublishing.swift`: vault-key protocols, escrow/signal key publishers, trusted-device verification, Firebase publisher.
   - `SessionLogSyncService+DocumentIdentity.swift`: document ID and component normalization.
   - `SessionLogSyncService+CloudEncoding.swift`: JSON/ISO8601/functions-error/sealed-text helpers.
   - `SessionLogSyncService+EncryptedCloudClient.swift`: encrypted Cloud Function/Storage client and upload error.
   - `CloudSyncService+SessionLogBridge.swift`: existing `CloudSyncService` adapter/search/decode/chunking bridge.
3. `OpenBurnBar.xcodeproj/project.pbxproj` is XcodeGen output after adding the split files.
4. `AgentLens/Services/CloudSync/UsageSyncService.swift` is intentionally untouched.

## Losslessness Evidence

Source captured from the commit parent:

```bash
git show HEAD^:AgentLens/Services/CloudSync/SessionLogSyncService.swift > .lane-logs/sessionlogsync-before.swift
```

Range-by-range diff proof in `.lane-logs/losslessness.log`:

```text
PASS core-class-sync-order-and-facet-helpers
PASS project-memory-methods
PASS cloud-readback-methods
PASS vault-key-publishing-types
PASS document-id-helpers
PASS encoding-helpers-dictionary-through-normalized-terms
PASS encoding-helper-decode-sealed-text
PASS sha256-helper
PASS encrypted-cloud-client
PASS upload-error-enum
PASS cloudsync-sessionlog-bridge
```

Only visibility normalization applied in the proof is the list below; method bodies, sync ordering, catch/return paths, and error handling compare exactly.

## Minimal Visibility Relaxations

- `context` and `encryptedCloudClient`: `private let` -> internal `let`, so moved extension files can use existing stored dependencies.
- `writableVaultKey(uid:)` and `readableVaultKey(uid:)`: `private` -> internal, so moved read/write surfaces can share the same key-resolution helpers.
- `dictionary`, `jsonData`, `iso8601`, `isPermissionDeniedFunctionsError`, `decodeSealedText`: moved out of a `private extension` into an internal extension because they are used across the new files.
- `CloudSessionLogUploadError`: `private enum` -> internal `enum`, because encoding and encrypted-client helpers now live in separate files.
- `normalizedTerms` and `sha256Hex` remain `private static` in their new homes.

## Validation Matrix

- `xcodegen` -> OK; regenerated `OpenBurnBar.xcodeproj/project.pbxproj`.
- `FIREBASE_SOURCE_FIRESTORE=1 xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination platform=macOS,arch=arm64 -clonedSourcePackagesDirPath ./.spm-cache-new -disableAutomaticPackageResolution -derivedDataPath ./.lane-logs/xcodebuild-derived-data` -> OK, `** BUILD SUCCEEDED **`.
- `OPENBURNBAR_APP_TEST_FILTERS='OpenBurnBarTests/SessionLogSyncRoundTripTests\nOpenBurnBarTests/SessionLogSyncServiceMattersTests\nOpenBurnBarTests/ConversationTombstoneTests' ./scripts/test-openburnbar-app.sh` -> OK, 40 selected tests, 0 failures.
- `bash scripts/debt/check-swift-file-size-budget.sh` -> OK.
- `git diff --check` / `git diff --cached --check` -> OK.
- `git diff --cached -G'eslint-disable|@ts-|# noqa|@Suppress|swiftlint:disable|#\[allow\]' --` -> no output; no new lint/type suppressions.
- `git diff -- AgentLens/Services/CloudSync/UsageSyncService.swift` -> no output.
- New basename uniqueness checked before staging in `.lane-logs/basename-uniqueness.log`; all seven new basenames were repo-unique before add.

Notes:
- The exact xcodebuild invocation without `FIREBASE_SOURCE_FIRESTORE=1` fails package resolution because this repo requires the source Firestore graph and otherwise tries to add `grpc-binary`; `scripts/test-openburnbar-app.sh` exports that env by default.
- A shared DerivedData retry hit a third-party `abseil` dependency-file write race while sibling lanes were active; the worktree-local DerivedData path isolated the build and passed.

## Risks

- Low behavioral risk: this is a pure move plus minimal visibility needed for Swift cross-file extensions.
- Merge risk: `project.pbxproj` may conflict with sibling XcodeGen lanes; orchestrator can regenerate/reconcile.

## Rollback

Revert commit `81e5002dc7` to restore the single-file layout and previous project file.
