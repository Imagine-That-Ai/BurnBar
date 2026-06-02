# Getting started

## Prerequisites

- macOS 14 Sonoma or later
- Xcode 16+ with command line tools
- Swift 5.10
- Node + npm (only for the editor extension)
- Java 21 + Android SDK (only for Android builds)

## Quick start

### 1. Clone and build the macOS app

```bash
git clone https://github.com/Imagine-That-Ai/BurnBar.git
cd BurnBar
make preflight   # verify tooling
make build       # build Release .app into .derived-data/
make install     # copy to /Applications
```

### 2. Run tests

```bash
make test        # all test suites
make ci          # lint + tests (full CI parity)
```

### 3. Build the daemon and CLI

```bash
swift build --package-path OpenBurnBarDaemon
swift run --package-path OpenBurnBarDaemon OpenBurnBarCLI -- help
```

### 4. Build the VS Code extension (optional)

```bash
cd extensions/openburnbar
npm install
npm run build
```

### 5. Build the Android app (optional)

```bash
cd android
./gradlew assembleDebug
```

## Daily development workflow

1. Edit `project.yml` if you add/remove Swift files, then run `xcodegen generate`.
2. Use `make build` for fast iteration; `make install` only when testing the full app bundle.
3. Run `./scripts/test-openburnbar-app.sh` before pushing changes that touch `AgentLens/`.
4. Run `make ci` before any PR that touches multiple surfaces.

## Clearing stale caches

After large `OpenBurnBarCore` migrations, Xcode may hold stale binary artifacts. If you see ghost errors like *"value of type 'X' has no member 'Y'"*, run:

```bash
./scripts/clear-xcode-caches.sh
```

## Useful scripts

| Script | Purpose |
|--------|---------|
| `scripts/test-openburnbar-swift.sh` | Swift package tests |
| `scripts/test-openburnbar-app.sh` | macOS app tests |
| `scripts/test-openburnbar-mobile.sh` | iOS mobile tests |
| `scripts/test-openburnbar-android.sh` | Android JVM tests |
| `scripts/build-iroh-android-aar.sh` | Build `Vendor/openburnbar-iroh.aar` |
| `scripts/e2e/android-iroh-chat.sh` | Android iroh chat instrumented suite |
| `scripts/ci/inject-firebase-config.sh` | iOS CI: inject `GoogleService-Info.plist` |

## Related pages

- [Patterns and conventions](../how-to-contribute/patterns-and-conventions.md) — coding style and conventions
- [Testing](../how-to-contribute/testing.md) — test frameworks and patterns
- [Tooling](../how-to-contribute/tooling.md) — build system and CI
