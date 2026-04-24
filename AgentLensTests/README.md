# AgentLensTests

## Folder contract

The Xcode unit-test target **`OpenBurnBarTests`** is generated from [`project.yml`](../project.yml). It compiles by directory, not by an ad-hoc file list:

- `AgentLensTests/Active/` — active XCTest suites compiled in `OpenBurnBarTests`
- `AgentLensTests/Support/` — shared harnesses, helpers, and fixtures used by active suites
- `AgentLensTests/Fixtures/` — fixtures shared by active/support code

The active target compiles `Active/**` plus `Support/**`. Some suites under `Active/` are excluded in `project.yml` (see the commented excludes list) because they depend on golden fixtures, keychain isolation, or API alignment work.

## Active bundle

Run the active bundle:

```bash
./scripts/test-openburnbar-app.sh
# or
xcodebuild -scheme OpenBurnBar -project OpenBurnBar.xcodeproj -destination 'platform=macOS' test \
  CODE_SIGNING_ALLOWED=NO -only-testing:OpenBurnBarTests
```

Representative active suites now live under `AgentLensTests/Active/`, including the replay golden tests, discovery/retrieval coverage, settings secret-storage coverage, parser tests, UI tests, and the smaller standalone app test files.

## Excluded suites

Some suites under `Active/` are excluded from compilation in `project.yml`. Each exclusion has a YAML comment explaining why. To re-enable one, remove it from the excludes list and run `xcodegen generate`.
