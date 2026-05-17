# Phase 11 Device Matrix - Mac System Computer Use

## Scope

Mac System Computer Use uses Accessibility, AX inspection, and CGEvent dispatch. It ships only in direct-download builds and is compiled out of Mac App Store builds with `DISTRIBUTION_MAS`.

## Required Checks

| Check | Command / Evidence | Expected |
|---|---|---|
| MAS compile guard | `#if canImport(AppKit) && !DISTRIBUTION_MAS` on Mac input/AX files | Path C absent from MAS build |
| Accessibility prompt | Settings -> Computer Use -> Open Accessibility | System Settings opens Privacy & Security -> Accessibility |
| Mac build | `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -configuration Debug -quiet build` | exit `0` |
| Core Mac input tests | `cd OpenBurnBarCore && swift test --filter MacInputCoreTests` | all tests pass |

## Manual Smoke

1. Grant Accessibility to OpenBurnBar.
2. Open Settings -> Computer Use.
3. Confirm readiness shows Accessibility granted.
4. Start a Manual trust session.
5. Approve a benign click/type action in a disposable app.
6. Trigger panic halt from the Mac and verify no further events dispatch.

## Failure Rules

- Missing Accessibility must deny Mac input.
- Off-screen coordinates must be rejected before CGEvent posting.
- Secure/auth regions must deny before approval.
- Trusted mode must never carry across a new session.
