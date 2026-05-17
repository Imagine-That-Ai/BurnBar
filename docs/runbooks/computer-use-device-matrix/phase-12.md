# Phase 12 Device Matrix - Phone As Controller

## Scope

Phone control lets iPhone/iPad watch a Mac session, approve/reject pending actions, downgrade trust mode, and send signed panic/input intents back to the Mac.

## Required Checks

| Check | Command / Evidence | Expected |
|---|---|---|
| iOS build | `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -configuration Debug -quiet build` | exit `0` |
| Receiver exists | `OpenBurnBarMobile/Services/ComputerUse/AgentWatchReceiver.swift` | ingests `control.*` frames |
| Control stream exists | `OpenBurnBarMobile/Services/ComputerUse/AgentWatchOverlayCoordinator.swift` | opens persistent iroh control stream |
| Approval responses | `AgentWatchReceiver.approve/reject` | emits `control.approval.response` |
| Panic path | `PhoneControlSender.send(.panic)` | emits signed `control.input.intent` |

## Manual Smoke

1. Pair phone with Mac via Hermes iroh relay.
2. Open You -> Computer Use on iPhone.
3. Start a Mac Computer Use session.
4. Confirm the phone sees the session/timeline.
5. Approve one pending action from phone.
6. Reject one pending action from phone.
7. Send panic halt from phone and verify Mac stops dispatching.

## Failure Rules

- Signature, stale timestamp, and replay failures must emit `control.denied`.
- Phone may downgrade trust mode; it must not silently upgrade trust.
- Rejected approvals must write audit entries.
