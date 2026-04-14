# Environment

Environment variables, external dependencies, and setup notes for the Context Pack mission.

## Mission Notes

- No new external credentials required.
- No new long-running services required.
- Work is fully local to the existing OpenBurnBar macOS app/test toolchain.
- On this machine, `scripts/test-openburnbar-app.sh` can hang at `xcodebuild test` launch time with `The test runner hung before establishing connection`; `CI=true scripts/test-openburnbar-app.sh` still completes the build-for-testing fallback if you need a compile-only confirmation.

## Required Tooling

- Xcode + `xcodebuild`
- Swift toolchain
- Node + npm (existing extension lint path)
- `ripgrep` for fast source/test discovery

## Assumptions

- Existing test infrastructure remains available (`OpenBurnBar.xcodeproj`, app test target).
- Context Pack behavior is validated through deterministic tests; manual UI validation is user-opted-out for this mission.
