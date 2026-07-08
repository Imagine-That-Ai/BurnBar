## Review map
- `AgentLens/Services/DataStore/ControlPlaneStore+Memory.swift` now retains the memory model declarations, gate IDs, and `addChatMemoryAuthorityRecord` entrypoint.
- `ControlPlaneStore+MemoryExtractionJobs.swift` holds extraction enqueue/claim/status/reap/job decoding helpers.
- `ControlPlaneStore+MemoryRecall.swift` holds fetch/open/search/recall read paths.
- `ControlPlaneStore+MemoryWrite.swift` holds update, review status, delete, pagination, and entity listing paths.
- `ControlPlaneStore+MemoryEmbeddings.swift` holds embedding version/upsert/match logic.
- `ControlPlaneStore+MemorySupport.swift` holds shared snapshot, scope, scoring, dedup, citation, and audit helpers.
- `ControlPlaneStore+MemoryExtractionWorker.swift` holds the admission controller, extraction worker actors, and `ChatExtractionTranscriptReading` conformance.
- `OpenBurnBar.xcodeproj/project.pbxproj` was regenerated with `xcodegen generate --spec project.yml`.

## Losslessness evidence
- Read the full 1,935-line source before splitting.
- Pure move reconstruction proof: `.lane-logs/gf8-controlplane-memory/normalized-diff-proof.log` reports `LOSSLESS_OK reconstructed split matches git show HEAD after normalizing private-to-internal helper relaxations`.
- The reconstruction proof reassembles the split files in original source order and compares against `git show HEAD:AgentLens/Services/DataStore/ControlPlaneStore+Memory.swift`; normalization only restores the helper `private` modifiers that had to become same-module-visible after the file split.
- This covers SQL and migration-adjacent strings byte-for-byte because the reassembled source matches `HEAD` after only those access modifiers are normalized.
- New basename uniqueness: `.lane-logs/gf8-controlplane-memory/new-basename-uniqueness.log` shows each new basename has `count=1` in `git ls-files`.
- File sizes after split: `ControlPlaneStore+Memory.swift` 283, `+MemoryExtractionJobs` 302, `+MemoryRecall` 248, `+MemoryWrite` 226, `+MemoryEmbeddings` 164, `+MemorySupport` 466, `+MemoryExtractionWorker` 285 lines; all are <=800.

## Visibility relaxations
Minimal `private` to internal relaxations required because moved extension files can no longer access same-file-private helpers:
- `MemoryBodySnapshot`
- `memorySnapshotSlug(_:)`
- `memorySnapshotRef(_:)`
- `memoryStorageProjectID(for:)`
- `memoryBodySnapshotJSON(memoryID:body:bodyHash:citations:createdAt:)`
- `memoryProvenanceID(memoryID:citationID:)`
- `sha256Hex(_:)`
- `memoryTokenEstimate(_:)`
- `memoryTextScore(query:text:)`
- `memory(from:citations:)`
- `memoryCitation(from:)`
- `appendScopePredicates(_:tableAlias:to:arguments:)`
- `chatMemoryDuplicateCandidates(db:bodyHash:storageProjectID:kind:scope:excludingID:)`
- `memoryDedupWinnerID(...)`
- `mergeDuplicateChatMemories(...)`
- `appendMemoryAuditEvent(...)`

## Validation matrix
- PASS `xcodegen generate --spec project.yml`
- PASS `xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination platform=macOS,arch=arm64 -clonedSourcePackagesDirPath ./.spm-cache-new -disableAutomaticPackageResolution`
- PASS `OPENBURNBAR_APP_TEST_FILTERS='AgentLensTests/OpenBurnBarDatabaseMigrationTests; AgentLensTests/MemoryExtractionEngineTests; AgentLensTests/MemoryExtractionExtractorTests; AgentLensTests/MemoryDropTelemetryTests; AgentLensTests/MemoryActivationEndToEndTests; AgentLensTests/MemoryCloudSyncDomainTests' ./scripts/test-openburnbar-app.sh` (`91 tests, 0 failures`)
- PASS `bash scripts/debt/check-swift-file-size-budget.sh`
- PASS `bash scripts/ci/check-no-suppressions.sh`
- PASS `git diff --check` and `git diff --cached --check`
- PASS new basename uniqueness check against `git ls-files`

## Risks
- This is datastore-adjacent and touches SQL-heavy code, but the normalized reconstruction proof confirms the moved SQL text is unchanged.
- Internal helper visibility is wider than same-file-private, but remains module-internal and is limited to split-file access.
- `project.pbxproj` may conflict with sibling decomposition lanes; orchestrator is expected to resolve landing conflicts.

## Rollback
Revert commit `dec1d67` to restore the single-file layout and generated project file entries.
