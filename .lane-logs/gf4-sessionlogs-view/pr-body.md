## Summary

Decomposes `AgentLens/Views/SessionLogs/SessionLogsView.swift` into focused files while preserving the existing rendered SwiftUI hierarchy and behavior. `SessionLogsView.swift` is now a thin shell, with model/filtering, command-center, detail/loading, and moved child view structs in separate files.

`OpenBurnBar.xcodeproj/project.pbxproj` was regenerated with `xcodegen` so the new files are present in the Xcode project.

## Review Map

1. `AgentLens/Views/SessionLogs/SessionLogsView.swift` - remaining root state, environment wiring, shell body, and lifecycle modifiers.
2. `AgentLens/Views/SessionLogs/SessionLogsView+CoreTypes.swift` - moved enums/group type only.
3. `AgentLens/Views/SessionLogs/SessionLogsView+Filtering.swift` - moved filtering, grouping, selection, retrieval health, export, and lifecycle helper methods.
4. `AgentLens/Views/SessionLogs/SessionLogsView+CommandCenter.swift` - moved left-pane command-center UI and related subviews.
5. `AgentLens/Views/SessionLogs/SessionLogsView+DetailAndLoading.swift` - moved detail pane, export pane, event helpers, loading/error UI, and data loading helpers.
6. `AgentLens/Views/SessionLogs/SessionLogsCompactSessionRow.swift` - moved existing compact row view.
7. `AgentLens/Views/SessionLogs/SessionLogsResumeConversationSheet.swift` - moved existing resume sheet and request type.
8. `AgentLens/Views/SessionLogs/SessionLogsDeviceIconPicker.swift` - moved existing device icon picker view.
9. `AgentLens/Views/SessionLogs/SessionLogsCloudConsentSheet.swift` - moved existing cloud consent sheet.
10. `OpenBurnBar.xcodeproj/project.pbxproj` - XcodeGen output only.

## Losslessness Evidence

Method:
- Reconstructed the original monolithic `SessionLogsView.swift` from the split files in original declaration order.
- Compared against `git show HEAD:AgentLens/Views/SessionLogs/SessionLogsView.swift`.
- Ignored import lines.
- Normalized only the listed cross-file visibility relaxations below.
- Reinserted the moved `substringFilteredLogs` block at the original data-loading position before diffing.
- Ran `diff -u` on the normalized original and normalized reconstruction.

Result from `.lane-logs/gf4-sessionlogs-view/losslessness.log`:

```text
OK: reconstructed AgentLens/Views/SessionLogs/SessionLogsView.swift from split files
OK: normalized non-import lines match git show HEAD:AgentLens/Views/SessionLogs/SessionLogsView.swift (1949 lines)
OK: normalization limited to listed cross-file visibility relaxations
OK: new split files <= 800 lines: SessionLogsView.swift=102, SessionLogsView+CoreTypes.swift=56, SessionLogsView+Filtering.swift=238, SessionLogsView+CommandCenter.swift=641, SessionLogsView+DetailAndLoading.swift=348, SessionLogsCompactSessionRow.swift=134, SessionLogsResumeConversationSheet.swift=251, SessionLogsDeviceIconPicker.swift=75, SessionLogsCloudConsentSheet.swift=131
OK: new file basenames absent from git ls-files before this commit: SessionLogsView+CoreTypes.swift, SessionLogsView+Filtering.swift, SessionLogsView+CommandCenter.swift, SessionLogsView+DetailAndLoading.swift, SessionLogsCompactSessionRow.swift, SessionLogsResumeConversationSheet.swift, SessionLogsDeviceIconPicker.swift, SessionLogsCloudConsentSheet.swift
OK: diff -u normalized files produced no differences
```

## Minimal Visibility Relaxations

These were required only because Swift `private` members cannot be referenced from same-type extensions in separate files:

- Root `SessionLogsView` state/cache helpers relaxed from `private` to internal: `allLogs`, `searchText`, `sourceFilter`, `groupMode`, `expandedSections`, `sectionDisplayLimits`, `selectedId`, `isLoading`, `appeared`, `dataSource`, `cloudBodyCache`, `dataSourceError`, `retrievalSearchService`, `retrievalHealthService`, `retrievalMatchedIDs`, `isRetrievalSearching`, `retrievalHealthSnapshot`, `deviceFilter`, `knownDevices`, `sessionModelMap`, `iconPickerDeviceId`, `selectedDetailLog`, `resumeRequest`, `isExporting`, `allLogsVersion`, `dayChangeTick`, `logGroupsCache`, `dashboardLiveBackdropActive`, `defaultDisplayLimit`, `hasMultipleDevices`, `hasAnyDevices`.
- Extension entry points and cache types relaxed from `private` to internal: `LogGroupsCacheKey`, `LogGroupsCache`, `filteredLogs`, `logGroups`, `visibleDegradedModes`, `selectedLog`, `commandCenter`, `detailPane`, `initializeSessionLogs`, `handleSearchTextChange`, `handleSourceFilterChange`, `handleGroupModeChange`, `handleDataSourceChange`, `handleConversationIndexingChange`, `handleEmbeddingVersionChange`, `exportAllConversations`, `handleSelectedIdChange`, `refreshRetrievalHealth`, `applyJumpTargetIfNeeded`.
- Moved child view/request structs relaxed from `private` to internal where referenced across files: `CompactSessionRow`, `SessionResumeRequest`, `ResumeConversationSheet`, `DeviceIconPicker`.

No behavior/signature changes were made beyond those access-control moves.

## Validation Matrix

| Check | Result |
| --- | --- |
| `git fetch origin main && git merge origin/main` | Fast-forwarded onto current `origin/main` before work |
| `xcodegen` | Passed; regenerated `OpenBurnBar.xcodeproj/project.pbxproj` |
| `xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination platform=macOS,arch=arm64 -clonedSourcePackagesDirPath ./.spm-cache-new -disableAutomaticPackageResolution` | Passed, `** BUILD SUCCEEDED **` |
| `OPENBURNBAR_APP_TEST_FILTERS='OpenBurnBarTests/SessionLogGroupsCacheTests,OpenBurnBarTests/SessionLogSyncServiceMattersTests,OpenBurnBarTests/SessionLogSyncRoundTripTests' ./scripts/test-openburnbar-app.sh` | Passed, 43 tests, 0 failures |
| `bash scripts/debt/check-swift-file-size-budget.sh` | Passed, no new oversized files |
| `bash scripts/ci/check-no-suppressions.sh` | Passed, no unjustified suppressions/baselines |
| `git diff --check` and `git diff --cached --check` | Passed |
| Normalized losslessness reconstruction vs `git show HEAD` | Passed, no diff |

Notes:
- Grep found SessionLogs-related suites in `AgentLensTests/Active/SessionLogGroupsCacheTests.swift`, `AgentLensTests/Active/SessionLogSyncServiceMattersTests.swift`, and `AgentLensTests/Active/SessionLogSyncRoundTripTests.swift`.
- An initial bare-filter test invocation failed because the wrapper requires `OpenBurnBarTests/...` bundle-qualified filters; the corrected command above passed.

## Risks

- This is intended as a pure decomposition. Review should focus on accidental access widening or declaration-order movement, not behavioral changes.
- `SessionLogDetailPane.swift` remains over 800 lines, but it is an existing separate file and not part of the requested `SessionLogsView.swift` decomposition target.
- The moved child view structs keep their existing bodies and call sites; the PR does not intentionally change the SwiftUI layout.

## Rollback

Revert this single commit to restore the monolithic `SessionLogsView.swift` and the previous generated Xcode project file.
