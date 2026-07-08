Audit wave 4, items 15 (views must not own persistence/networking) + 16 (dependency threading). The two worst URLSession/Firestore-in-View offenders on iOS now render state and send intents only; all persistence/networking lives in Services-layer stores with initializer-injected dependencies.

## REVIEW MAP — what moved where

### Commit 1 — `AgentBrandZoneView.swift` (1516 → 865 lines)
| Moved logic | From (view file) | To |
|---|---|---|
| `AgentSubscriptionTopicStore` (Firestore reads/writes, auth listener, realtime snapshot listener, sealed-topic encode/decode, vault-key handling) | class defined inside the view file | `OpenBurnBarMobile/Services/AgentSubscriptionTopicStore.swift` — **verbatim move** into the Services file that was previously an "intentionally left blank" placeholder pointing back at the view |
| `AgentBrandQuickActionComposer` + `AgentForwardContextSnapshot` (pure prompt/topic composition) | view file | `OpenBurnBarMobile/Services/AgentBrandQuickActionComposer.swift` (same placeholder fill, verbatim) |
| `forwardContextSnapshot()` — reads `MobileChatHistoryStore` threads / refreshes `CLIAgentChatReader` and reads Mac-mirrored sessions | view helper | **NEW** `OpenBurnBarMobile/Services/AgentBrandZoneStore.swift` → `forwardContextSnapshot(for:)` |
| `performForward()` — pending-prompt stash + `MissionConsoleDispatchRequest` dispatch | view helper | `AgentBrandZoneStore.forward(source:destination:context:note:missionHost:directThreadHandoffAvailable:)` returning `AgentBrandForwardResult` (message + navigation resolution); the view performs the navigation callback and shows the message |
| `performSubscriptionAction()` — subscribe/unsubscribe/mute/delivery intents | view helper | `AgentBrandZoneStore.performSubscriptionAction(_:identity:)`; sheet's nested `Action` enum hoisted to `AgentSubscriptionAction` |
| `runtimeToken(for:)` transport gate | view helper | `AgentBrandZoneStore.runtimeToken(for:)` (pure, static) |

The view file no longer imports `FirebaseAuth` / `FirebaseCore` / `FirebaseFirestore` — it imports `SwiftUI` + `OpenBurnBarCore` only.

### Commit 2 — `CLIAgentConversationListView.swift` (1689 → 1111 lines)
| Moved logic | From (view file) | To |
|---|---|---|
| `CLIAgentMobileChatService` (thread persistence via `MobileChatHistoryStore`, relay streaming via `CLIAgentRelayChatTransporting`, `CLIAgentMissionDispatcher` fallback + observation) + `CLIAgentMobileChatSnapshotReducer` + `CLIAgentChatRoute` | defined inside the view file | **NEW** `OpenBurnBarMobile/Services/CLIAgentMobileChatService.swift` — verbatim move |
| `CLIAgentPresentationModePreferences` (UserDefaults read/write) | `private enum` in view file | same new Services file, now internal — the view layer never touches persistence directly |
| `iosSourceSurface` / `mobileDeliveryMode` presentation-mode routing | private extension in view file (only the service used them) | same new Services file (private extension there); the view keeps only the visual `shortLabel`/`systemImage` members |
| `startImport(harnesses:)` — `AgentHarnessImportJobDispatcher.shared.create/observe` (Firestore job doc + snapshot listener), import snapshot state machine, terminal `reader.refresh()` | view helper + 2 `@State` vars (`importSnapshot`, `importObservation`) | **NEW** `OpenBurnBarMobile/Services/AgentHarnessImportStore.swift` → `start(harnesses:)` / `cancelObservation()` / published `snapshot` |

## Item 16 — dependency threading
- `AgentBrandZoneStore.init(historyStore:cliReader:subscriptionTopics:pendingPrompt:)` — all injected; defaults are the existing long-lived instances (the exact `CLIAgentMobileChatService.init(historyStore:relayChatTransport:)` idiom already blessed in `AppServices.swift`).
- `AgentHarnessImportStore.init(dispatcher:sessionReader:)` — dispatcher injected behind a **new protocol seam** `AgentHarnessImportJobDispatching` (mirrors the existing `CLIAgentRelayChatTransporting` / `CLIRuntimeCatalogProviding` idiom; the production `AgentHarnessImportJobDispatcher` conforms with zero added code).
- `AgentBrandZoneStore.forward` takes the **existing** `MissionConsoleHost` protocol instead of the concrete host — no new seam invented.
- No new `.shared` reads inside method bodies; `.shared` appears only as init-parameter defaults, preserving today's instances.

## Behavior preservation
- All moved bodies are verbatim; only receiver names changed (`MobileChatHistoryStore.shared` → injected `historyStore`, etc.).
- Forward flow: same prompt composition, same stash-then-open ordering for Hermes/Pi with a thread callback, same mission request shape (`kind: .diligence`, `depth: .standard`, commands/file-edits false), same messages, same failure text. Navigation moved from inside the helper to the view switching on the returned resolution — same call order (stash → navigate → status message; dispatch → navigate → status message).
- The native stash-and-open branch fires only when the surface has an `onOpenRuntimeThread` callback, exactly as before (threaded through as `directThreadHandoffAvailable: onOpenRuntimeThread != nil`).
- Import flow: identical optimistic pending snapshot dict, identical failed-snapshot dicts on create failure ("Could not start import.") and watcher error ("Import watcher failed."), identical terminal `reader.refresh()` (same `.shared` reader instance the view renders).
- Error handling: no error is swallowed anywhere new — subscription errors still return as the status-alert message; import errors still land in the rendered snapshot. **Zero new empty catches** (CI empty-catch budget untouched).
- One deliberate lifecycle nuance: `AgentBrandZoneStore` is constructed at view init, so its four dependency singletons resolve slightly earlier than the old lazy in-method `.shared` reads. The brand zone is a deep-navigation leaf view — every one of those singletons is already alive by then. Noted under risks.

## Grep-proof (item 15 acceptance)
```
$ grep -n "URLSession\|Firestore\|Firebase\|FileManager\|UserDefaults" \
    OpenBurnBarMobile/Views/Hermes/Square/AgentBrandZoneView.swift
(no matches)

$ grep -n "URLSession\|Firestore\|Firebase\|FileManager\|UserDefaults\|AgentHarnessImportJobDispatcher\|CLIAgentMissionDispatcher" \
    OpenBurnBarMobile/Views/CLIAgents/CLIAgentConversationListView.swift
8:// mirrored sessions the macOS app has published into Firestore via   <- comment only
337:// Mac-mirrored previews arrive via Firestore as raw                 <- comment only
```
Zero imports, zero calls; the two hits are doc comments describing where mirrored data comes from.

## Validation matrix
| Check | Command | Result |
|---|---|---|
| Build @ commit 1 (standalone, pre-merge) | `FIREBASE_SOURCE_FIRESTORE=1 xcodebuild build -scheme OpenBurnBarMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -clonedSourcePackagesDirPath ./.spm-cache-new -disableAutomaticPackageResolution -derivedDataPath ./.derived-w4` | **BUILD SUCCEEDED**, 0 errors (`.lane-logs/build-commit1b.log`) |
| Build @ commit 2 (pre-merge) | same | **BUILD SUCCEEDED**, 0 errors (`.lane-logs/build-commit2.log`) |
| Unit tests @ merged HEAD | `xcodebuild test -scheme OpenBurnBarMobileUnitTests` on a dedicated simulator (`w4-views-lane`, iPhone 17 Pro Max / iOS 27.0), `-only-testing:` AgentBrandZoneStoreTests, AgentHarnessImportStoreTests, CLIAgentChatReaderTests, AgentSubscriptionTopicSealTests, HermesConversationListViewTests | **54 tests, 0 failures** (`.lane-logs/tests-final.log` in the lane worktree) |
| XcodeGen drift | `xcodegen` rerun after each file addition and after the merge; regenerated `project.pbxproj` committed alongside the files it references | each commit self-consistent |

New behavioral tests (one per new/extended store method cluster, reusing existing fakes/seams only — no new mocking framework):
- `AgentBrandZoneStoreTests` (8 tests): runtime-token resolution; forward-context read from injected `MobileChatHistoryStore` (empty-preview fallback included); forward-context read through `CLIAgentChatReader` + reused `StubCLISource`; nil context without a runtime id; forward → stash+open-thread; forward → mission dispatch + open-list (request shape asserted via a fake `MissionConsoleHost`); forward failure; unresolvable destination.
- `AgentHarnessImportStoreTests` (5 tests): optimistic pending snapshot + create/observe args; observer updates replace snapshot + terminal update refreshes the session reader; create failure → failed snapshot; watcher error → failed snapshot; cancelObservation keeps last snapshot.

## Test-run notes
- First run surfaced 2 failures — both were wrong **test expectations**, not extraction bugs: (a) the runtime token is whitespace-trimmed (matching the original in-view helper exactly); (b) `MobileChatHistoryStore.upsert` re-stamps `updatedAt`, so the forward context mirrors the store's stamp (identical to the pre-move read). Expectations corrected; production code untouched by the fix.
- Branch merged `origin/main` (68 commits, incl. the god-file-split wave) before push; only `project.pbxproj` conflicted — resolved by taking main's copy and rerunning `xcodegen` on the merged tree. Neither view file nor any moved Services file was touched on main.

## Risks
- **Store construction timing**: `AgentBrandZoneStore`'s four dependency singletons resolve at brand-zone view init instead of first quick-action use. All are already initialized long before this deep-navigation leaf view can appear; if a future cold path constructs `AgentBrandZoneView` at launch, singleton init order would shift.
- **`CLIAgentPresentationModePreferences` visibility widened** private → internal (it moved files). Two-method UserDefaults wrapper; no semantic change.
- **`AgentSubscriptionTopicStore` changed compile units**: all cross-file consumers (`HermesSquareRoot`, `HermesSquareSplitLayout+LeftColumn`, `HermesSquareSubscriptionsFolder`, seal tests) reference it by name in the same target — verified compiling and seal tests green.
- Deviation from the brief's validation recipe: `./scripts/test-openburnbar-mobile.sh` mktemps a **fresh** DerivedData per attempt → full cold Firestore-from-source rebuild exceeding this environment's 10-minute tool ceiling. Tests ran through the identical underlying invocation (`xcodebuild test`, scheme `OpenBurnBarMobileUnitTests`, same `-only-testing` filters, dedicated simulator) against the lane's warm DerivedData, after materializing `Vendor/OpenBurnBarSignalFfiIOS.xcframework` (the one prep step the script would have performed).

## Rollback / containment
- Two self-contained commits, one per view (plus a mechanical `origin/main` merge); `git revert` either refactor commit independently and rerun `xcodegen`.
- No schema, wire-format, Firestore-rules, or cross-platform changes — every moved body is byte-equivalent logic within the `OpenBurnBarMobile` target. Reverting restores the in-view definitions exactly.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
