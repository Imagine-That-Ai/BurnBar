# Chat Pane Tabs QA

Date: 2026-07-01
Worktree: `/Users/albertonunez/Documents/Developer/BurnBar-pane-tabs`
Branch: `feat/chat-pane-tabs`

## Automated verification

| Check | Command | Result | Notes |
| --- | --- | --- | --- |
| XcodeGen | `xcodegen generate --spec project.yml` | PASS | Refreshed `OpenBurnBar.xcodeproj/project.pbxproj` after adding pane files. |
| Focused app-host XCTest | `OPENBURNBAR_APP_TEST_ATTEMPTS=1 SIGNAL_FFI_BUILD_TARGETS=aarch64-apple-darwin ./scripts/test-openburnbar-app.sh -only-testing:AgentLensTests/PaneWorkspaceModelTests` | PASS | `PaneWorkspaceModelTests` executed 27 tests, 0 failures. |
| Debug app build, plain Xcode args | `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -configuration Debug -destination 'platform=macOS,arch=arm64' ... build` | FAIL | Final link failed before pane runtime launch: `signal_ffi` was not found and `LibSignalClient.o` had unresolved `_signal_*` symbols. No pane Swift compile failures were present. |
| Debug app build, explicit Signal FFI link path | `xcodebuild ... SWIFT_ENABLE_EXPLICIT_MODULES=NO SWIFT_COMPILATION_MODE=singlefile SWIFT_ENABLE_BATCH_MODE=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO 'OTHER_LDFLAGS=$(inherited) -L.../Vendor/OpenBurnBarSignalFfiMac.xcframework/macos-arm64 -lsignal_ffi' build` | PASS | Produced `/tmp/obb-pane-tabs-app-build-harness-flags/Build/Products/Debug/OpenBurnBar.app`. |
| Whitespace | `git diff --check` | PASS | No whitespace errors. |

## Manual visual QA

Manual visual QA was not completed in this run. The app bundle was built only
after supplying an explicit local Signal FFI linker path; the interactive
dashboard/pop-out smoke pass should be run from the built app or from the normal
maintainer build once the local `signal_ffi` linker path is wired into the
plain build path.

| Step | Expected | Result | Screenshot | Notes |
| --- | --- | --- | --- | --- |
| Single tab, single pane | Old Chat surface parity; toolbar pickers visible; `cmd+W` closes the window. | NOT RUN | | Requires interactive app launch. |
| Pane splitting | `cmd+D` and `cmd+shift+D` create nested panes; active ring follows focus; dividers resize. | NOT RUN | | Requires interactive app launch. |
| Tab controls | `cmd+T`, `cmd+shift+T`, `cmd+shift+[` / `cmd+shift+]` work. | NOT RUN | | Requires interactive app launch. |
| Digit keys are unambiguous | `cmd+1...8` reaches the dashboard's primary sections and **nothing else** while `mainRoute == .chat`; no tab selection fires. | NOT RUN | | `cmd+1...9` tab selection was **removed** (see below). Requires interactive app launch. |
| Drag and pane moves | Rail-to-pane bind, pane-header swap, move to new tab, move to existing tab. | NOT RUN | | Requires interactive app launch. |
| Background completion | Hidden-pane completion dots appear; `cmd+shift+U` focuses and clears; notification tap focuses pane. | NOT RUN | | Requires interactive app launch and notification permission state. |
| Relaunch persistence | Tabs, splits, fractions, titles, colors, zoom, active tab/pane, and bound threads restore. | NOT RUN | | Requires interactive app relaunch. |

## Shortcut inventory update — 2026-08-09 (Agent Deck PR 1)

`cmd+1...9` tab selection (`PaneWorkspaceView.swift`) has been **deleted**. It was
ambiguous against `DashboardView.swift:691`, which binds `cmd+1...8` to the app's
primary sections in the same responder chain, and the row above had been sitting
at NOT RUN since 2026-07-01 — so no verified behaviour was lost, only a coin
flip. Tabs keep `cmd+shift+[` / `cmd+shift+]` / `cmd+T` / `cmd+shift+T` /
`cmd+W`. Agent selection (`cmd+opt+1...9`) and the agent roster (`cmd+shift+A`)
are **not** registered by PR 1; they land with PR 2, and the Sigil prints no
keycap hint until they do — so nothing on screen teaches a shortcut that does not
fire.

Known duplicate registrations found by `grep -rn 'keyboardShortcut' AgentLens/`
and **not** fixed here (both live outside this PR's ownership boundary):

| Binding | Registered at | Status |
| --- | --- | --- |
| `cmd+K` | `DashboardView.swift:705` **and** `BurnBarTopRail.swift:491` | Double-bound. Spec §9.1 assigns the `BurnBarTopRail` removal to PR 1; deferred — `AgentLens/Views/Dashboard/**` was owned by a concurrent agent during this change. |
| `cmd+L` | `DashboardQuickSwitchView.swift:879` and `:907` | Double-bound. Flagged, out of scope. |
| `cmd+N` | `DashboardChatWorkspaceView.swift:187`, `MissionsLaneView.swift:166`, `AccountSwitcherSettingsView+Rendering.swift:649` | Triple-bound. Flagged, out of scope. |

## Defects / follow-ups

- Plain `xcodebuild build` still needs the existing libsignal FFI library path
  to propagate into the final app link. The explicit `OTHER_LDFLAGS` build
  proves the pane feature compiles and links when `signal_ffi` is resolvable.
- Manual visual QA screenshots remain to be captured for the dashboard and
  pop-out shared-workspace surfaces.
