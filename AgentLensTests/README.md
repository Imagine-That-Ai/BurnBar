# AgentLensTests

## Folder contract

The Xcode unit-test target **`OpenBurnBarTests`** is generated from [`project.yml`](../project.yml). It compiles by directory, not by an ad-hoc file list:

- `AgentLensTests/Active/` — active XCTest suites compiled in `OpenBurnBarTests`
- `AgentLensTests/Support/` — shared harnesses, helpers, and fixtures used by active suites
- `AgentLensTests/Fixtures/` — fixtures shared by active/support code
- `AgentLensTests/Archive/` — stale suites kept as migration reference only; not compiled until fixed and moved to `Active/`

The active target compiles `Active/**` plus `Support/**`. Files should not sit under `Active/` unless they compile against current app contracts. If a suite needs API alignment work, move it to `Archive/` with a short note and a manifest entry instead of hiding it behind a target exclude.

## Active bundle

The folder is named `AgentLensTests`, but the compiled XCTest bundle is named `OpenBurnBarTests`. Use `OpenBurnBarTests/...` in raw `xcodebuild -only-testing` filters. `./scripts/test-openburnbar-app.sh` accepts the common `AgentLensTests/...` alias and normalizes it before invoking Xcode.

Run the active bundle:

```bash
./scripts/test-openburnbar-app.sh
# or
xcodebuild -scheme OpenBurnBar -project OpenBurnBar.xcodeproj -destination 'platform=macOS' test \
  CODE_SIGNING_ALLOWED=NO -only-testing:OpenBurnBarTests
```

Representative active suites now live under `AgentLensTests/Active/`, including the replay golden tests, discovery/retrieval coverage, settings secret-storage coverage, cloud-sync consent coverage, UI tests, and the smaller standalone app test files.

## Archive

`AgentLensTests/Archive/` holds stale suites outside the compiled target. To revive, fix against current production APIs, move back under `AgentLensTests/Active/`, run `xcodegen generate`, and prove with `./scripts/test-openburnbar-app.sh`.
