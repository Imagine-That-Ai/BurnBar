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

## Result Log

| Date (UTC) | Device | OS target | Build | Install | Launch / test | Evidence |
|---|---|---|---|---|---|---|
| 2026-05-17T23:49:27Z | iPad Air 11-inch (M4) `407C0B12-010B-5970-8E85-D0E43DA8F457` | iPadOS device, Debug | PASS: `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination "id=407C0B12-010B-5970-8E85-D0E43DA8F457" -configuration Debug -derivedDataPath /tmp/DerivedData-cu-current-ipad -allowProvisioningUpdates -quiet build` exited `0` | PASS on retry: `xcrun devicectl device install app --device 407C0B12-010B-5970-8E85-D0E43DA8F457 /tmp/DerivedData-cu-current-ipad/Build/Products/Debug-iphoneos/OpenBurnBarMobile.app` exited `0` | BLOCKED: `xcrun devicectl device process launch --device 407C0B12-010B-5970-8E85-D0E43DA8F457 com.openburnbar.app` failed because SpringBoard reported the device was locked | `/tmp/cu-current-ipad-build.log`, `/tmp/cu-current-ipad-install-2.log`, `/tmp/cu-current-ipad-launch.log` |
| 2026-05-17T23:55:41Z | Samsung Galaxy S24 `R3CXB0CNS0J` / `SM_S921U` | Android device, Debug APK | PASS: `cd android && ./gradlew :app:testDebugUnitTest --tests '*QuotaStore*' --tests '*ComputerUse*' --no-daemon` exited `0`; `./gradlew :app:assembleDebug --no-daemon` exited `0` | PASS: `adb -s R3CXB0CNS0J install -r app/build/outputs/apk/debug/app-debug.apk` reported `Success` | PASS: `adb -s R3CXB0CNS0J shell am start -W -n com.openburnbar/.MainActivity` reported `Status: ok`; `dumpsys window` showed `mCurrentFocus=Window{... com.openburnbar/com.openburnbar.MainActivity}` and `logcat -b crash` had no post-launch crash entries | `/tmp/cu-android-launch-after-quota.png` |

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
