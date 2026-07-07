## Summary

Finishes the `ChatSessionController+Search.swift` god-file burn-down left by the prior split. The 1189-line file is now a 119-line search-state extension, with moved bodies split into focused sibling files:

- `ChatSessionController+SearchHistoryNavigation.swift`
- `ChatSessionController+SearchMemoryContext.swift`
- `ChatSessionController+SearchSend.swift`
- `ChatSessionController+SearchAvailability.swift`

All split files are under 800 lines. `OpenBurnBar.xcodeproj/project.pbxproj` was regenerated with `xcodegen`.

## Review Map

1. `AgentLens/Views/Chat/ChatSessionController+Search.swift` - remaining sidebar search state/query lifecycle.
2. `AgentLens/Views/Chat/ChatSessionController+SearchHistoryNavigation.swift` - moved thread open/hydration/teardown and memory-citation jump navigation.
3. `AgentLens/Views/Chat/ChatSessionController+SearchMemoryContext.swift` - moved insight snapshot, fire-and-forget send entrypoint, and memory recall prompt context.
4. `AgentLens/Views/Chat/ChatSessionController+SearchSend.swift` - moved prompt assembly, `send()`, fallback query assembly, fusion receipt, and CLI profile/fallback adapters.
5. `AgentLens/Views/Chat/ChatSessionController+SearchAvailability.swift` - moved backend/CLI availability guards, assistant error persistence, and Hermes unavailable message.
6. `OpenBurnBar.xcodeproj/project.pbxproj` - XcodeGen output adding the new Swift files.

## Losslessness Evidence

Method:
- Reconstructed the original monolithic `AgentLens/Views/Chat/ChatSessionController+Search.swift` from the split files in original declaration order.
- Compared against the pre-change `git show HEAD:AgentLens/Views/Chat/ChatSessionController+Search.swift`.
- Ignored import lines and split-file extension wrappers.
- Restored declaration-boundary blank lines where an extension boundary replaced an original blank separator.
- Normalized only `validateChatBackendAvailability()` from `private` to internal because `send()` now calls it from another file.
- Ran `diff -u` on the normalized old and reconstructed files.

Result from `.lane-logs/gf12-chat-search/losslessness.log`:

```text
OK: reconstructed AgentLens/Views/Chat/ChatSessionController+Search.swift from split files in original declaration order
OK: normalized non-import lines match git show HEAD:AgentLens/Views/Chat/ChatSessionController+Search.swift (1182 lines)
OK: normalization limited to validateChatBackendAvailability private-to-internal access for cross-file send() call
OK: new split files <= 800 lines: ChatSessionController+Search.swift=119, ChatSessionController+SearchHistoryNavigation.swift=131, ChatSessionController+SearchMemoryContext.swift=83, ChatSessionController+SearchSend.swift=736, ChatSessionController+SearchAvailability.swift=161
OK: new file basenames absent from git ls-files before this commit: ChatSessionController+SearchHistoryNavigation.swift, ChatSessionController+SearchMemoryContext.swift, ChatSessionController+SearchSend.swift, ChatSessionController+SearchAvailability.swift
OK: diff -u normalized files produced no differences
```

## Visibility Relaxation

`validateChatBackendAvailability()` changed from `private` to internal so the moved `send()` body can call it from `ChatSessionController+SearchSend.swift`. Its body is unchanged. The private helper methods it calls remained private inside `ChatSessionController+SearchAvailability.swift`.

## Validation Matrix

| Check | Result |
| --- | --- |
| `git fetch origin main` and branch parity check | Passed; branch started even with `origin/main` |
| `xcodegen` | Passed; regenerated `OpenBurnBar.xcodeproj/project.pbxproj` |
| `xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination platform=macOS,arch=arm64 -clonedSourcePackagesDirPath ./.spm-cache-new -disableAutomaticPackageResolution` | Passed, `** BUILD SUCCEEDED **` |
| `OPENBURNBAR_APP_TEST_FILTERS='OpenBurnBarTests/ChatSessionControllerAttachmentTests,OpenBurnBarTests/ChatSessionControllerOMPTests,OpenBurnBarTests/ChatSessionControllerPaneModeTests,OpenBurnBarTests/ChatSessionControllerPiAgentTests,OpenBurnBarTests/ChatSessionControllerSearchStateTests' ./scripts/test-openburnbar-app.sh` | Passed, 30 tests, 0 failures |
| `bash scripts/debt/check-swift-file-size-budget.sh` | Passed, no new oversized files |
| `bash scripts/ci/check-no-suppressions.sh` | Passed, no unjustified suppressions/baselines |
| `git diff --check` and `git diff --cached --check` | Passed |
| `git ls-files \| xargs -n1 basename \| sort \| uniq -d` checked against the new basenames | Passed; new split basenames are repo-unique |
| Normalized losslessness reconstruction vs `git show HEAD` | Passed, no diff |

ChatSession suites found and run:
- `ChatSessionControllerAttachmentTests`
- `ChatSessionControllerOMPTests`
- `ChatSessionControllerPaneModeTests`
- `ChatSessionControllerPiAgentTests`
- `ChatSessionControllerSearchStateTests`

## Risks

- This is intended as a pure decomposition; review should focus on accidental movement mistakes and the single access-control relaxation.
- The selected app test wrapper performed a long dependency build path through Signal/gRPC/Firebase before the filtered suites executed.
- XcodeGen also refreshed generated package dependency temp IDs in the project file.

## Rollback

Revert this single commit to restore the previous monolithic `ChatSessionController+Search.swift` and prior generated Xcode project file.
