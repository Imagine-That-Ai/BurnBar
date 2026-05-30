# Development workflow

## Branch

Branch from `main`. Use a descriptive name that reflects the change (e.g. `fix/claude-parser-empty-sessions`, `feat/hermes-mode-toggle`).

## Code

Follow `how-to-contribute/patterns-and-conventions.md` for naming, actor isolation, error handling, and schema conventions.

## Build

| Platform | Command |
|---|---|
| macOS app | Open `OpenBurnBar.xcodeproj` in Xcode, or `xcodebuild` |
| Daemon (Swift package) | `swift build --package-path OpenBurnBarDaemon` |
| Core package | `swift build --package-path OpenBurnBarCore` |
| Android debug APK | `cd android && ./gradlew assembleDebug` |

## Test

```bash
make test                                       # all suites
swift test --package-path OpenBurnBarDaemon     # daemon only
swift test --package-path OpenBurnBarCore       # core only
cd android && ./gradlew :app:testDebugUnitTest  # Android JVM
```

## XcodeGen

If you edited `project.yml`, regenerate the Xcode project before building:

```bash
brew install xcodegen   # first time only
xcodegen generate
```

## Stale caches

After large `OpenBurnBarCore` migrations, DerivedData may hold outdated module hashes:

```bash
./scripts/clear-xcode-caches.sh --dry-run   # preview what would be removed
./scripts/clear-xcode-caches.sh             # full clear
```

## Pull request

- Describe what changed and why.
- Include test evidence (screenshot, test output, or log snippet).
- Keep scope tight — one logical change per PR.

## Merge

Squash merge to `main`. The PR title becomes the commit message; make it clear.
