# Phase 8 Device Matrix - Agent Watch

## Scope

Agent Watch mirrors a Mac agent session to paired phones with `control.surface.frame` and `control.action.log`. Phase 8 is read-only on the phone: approval controls are visual until Phase 12.

## Required Checks

| Check | Command / Evidence | Expected |
|---|---|---|
| Mac action publisher | `AgentWatchActionPublisherTests` | journal events become `control.action.log.entry` frames |
| Phone timeline reducer | `OpenBurnBarMobileTests/testAgentWatchLoopbackReflectsTenActionLogEntriesWithinTwoHundredMillisecondsEach` | 10 fake action-log entries visible within 200 ms each |
| Live iroh stream audit | `iroh_audit_events` export | `control.surface.frame` + `control.action.log` open/close, zero unexpected fallback |
| LAN/LTE run | 5 consecutive Mac -> iPhone Mail triage runs | all 5 complete with timeline visible |

## Result Log

| Date (UTC) | Device / harness | Target | Build / test | Result | Evidence |
|---|---|---|---|---|---|
| 2026-05-18T05:07:35Z | iPhone 17 Pro Max `AFB07C15-AD18-5EFA-AD1C-CADB4F286797` | iPhoneOS physical device, Debug | PASS: `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination id=AFB07C15-AD18-5EFA-AD1C-CADB4F286797 -configuration Debug -derivedDataPath /tmp/DerivedData-cu-agent-watch-loopback-device -only-testing:OpenBurnBarMobileTests/OpenBurnBarMobileTests/testAgentWatchLoopbackReflectsTenActionLogEntriesWithinTwoHundredMillisecondsEach -quiet test` exited `0` | PASS: fake inbound `control.action.log.entry` frames for 10 agent actions reached `AgentWatchState.actionTimeline` on the phone receiver path within the 200 ms per-entry budget; all 10 completed entries were counted as executed. | Result bundle: `/tmp/DerivedData-cu-agent-watch-loopback-device/Logs/Test/Test-OpenBurnBarMobile-2026.05.18_00-06-16--0500.xcresult` |
| 2026-05-18T05:07:35Z | iOS Simulator generic destination | iOS Simulator | BLOCKED: `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath /tmp/DerivedData-cu-agent-watch-loopback -quiet build-for-testing` | The current `Vendor/OpenBurnBarIroh.xcframework` has no iOS Simulator slice, so simulator build-for-testing cannot be used for this target. Physical iPhone verification is the authoritative row for this loopback proof. | Xcode error: `no library for this platform was found in 'Vendor/OpenBurnBarIroh.xcframework'` |

## Remaining Gate

- Real Mac -> iPhone/iPad/Android LAN/LTE stream rows are still open.
- `iroh_audit_events` export proof is still open.
- 5 consecutive Mac -> iPhone Mail triage runs are still open.
