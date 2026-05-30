# Getting started

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Xcode | 16+ | Required for macOS and iOS builds |
| Swift | 5.10+ | Included with Xcode |
| XcodeGen | any | `brew install xcodegen` — regenerates `OpenBurnBar.xcodeproj` from `project.yml` |
| Node.js | 18+ | Required for Firebase Functions, extension, and tooling |
| Java | 21 | Required for Android builds (`brew install openjdk@21`) |
| Android SDK | API 29+ | Set `ANDROID_HOME=$HOME/Library/Android` |
| Rust + cargo | stable | Required only when rebuilding `crates/openburnbar-iroh` |

## Clone and bootstrap

```bash
git clone https://github.com/Imagine-That-Ai/BurnBar.git
cd BurnBar
```

## Build the macOS app

```bash
# Quick build from source (debug + Release, no signing)
make build

# Build and install to /Applications
make install
```

The `Makefile` also builds the daemon helper (`OpenBurnBarDaemon`) and embeds it inside the `.app` bundle at `Contents/Helpers/OpenBurnBarDaemon`.

If `project.yml` changes since your last clone, regenerate the Xcode project first:

```bash
xcodegen generate
```

## Run the macOS app

```bash
open /Applications/OpenBurnBar.app
# or from DerivedData after a build:
open .derived-data/Build/Products/Release/OpenBurnBar.app
```

After launch, OpenBurnBar appears in the menu bar. Open Settings to configure provider log paths and optional cloud sync.

## Build and run the daemon directly

```bash
swift build --package-path OpenBurnBarDaemon -c release
./.build/release/OpenBurnBarDaemon
```

The daemon opens a Unix socket at `~/.burnbar.sock` by default.

## CLI

```bash
swift run --package-path OpenBurnBarDaemon OpenBurnBarCLI -- help
```

Available commands: `health`, `controller`, `questions`, `followups`, `missions`, `mission-approve`, `simulator-runs`, `simulator-replay`.

## Run tests

```bash
# macOS app tests
./scripts/test-openburnbar-app.sh

# Daemon Swift package tests
swift test --package-path OpenBurnBarDaemon

# Shared core tests
swift test --package-path OpenBurnBarCore

# Mobile (iOS) tests — needs Xcode Simulator or connected iPhone
./scripts/test-openburnbar-mobile.sh

# Android JVM unit tests
./scripts/test-openburnbar-android.sh

# Full CI parity
make ci
```

## Build the iOS companion app

Use Xcode (scheme `OpenBurnBarMobile`) or the cross-platform helper:

```bash
./scripts/cross-platform/run-ios
```

Defaults to iPhone 17 Pro Max Simulator. Override with:

```bash
OPENBURNBAR_IOS_DESTINATION="platform=iOS Simulator,name=iPhone 16" ./scripts/test-openburnbar-mobile.sh
```

## Build the Android app

```bash
cd android && ./gradlew assembleDebug
```

Environment variables required:

```bash
export JAVA_HOME="$HOME/.homebrew/opt/openjdk@21"
export ANDROID_HOME="$HOME/Library/Android"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
```

For a connected emulator or device:

```bash
./scripts/cross-platform/run-android
```

## Firebase local setup

```bash
cd functions && npm install
firebase emulators:start
```

For the Android app, copy `google-services.json` from the Firebase Console to `android/app/google-services.json` (never committed; see `android/app/google-services.json.template`).

## Stale build caches

After large `OpenBurnBarCore` changes, Xcode may hold stale binary artifacts. Clear them with:

```bash
./scripts/clear-xcode-caches.sh
# Preview first:
./scripts/clear-xcode-caches.sh --dry-run
```

## Next steps

- [Architecture](architecture.md) — understand the component boundaries
- [Adding a parser](../how-to-contribute/development-workflow.md) — add a new AI provider
- [Log parsers](../apps/macos-app/parsers.md) — explore the existing parsers
