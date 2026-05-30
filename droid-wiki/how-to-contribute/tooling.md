# Tooling

## XcodeGen

Generates `OpenBurnBar.xcodeproj` from `project.yml`. Required after any `project.yml` edit.

```bash
brew install xcodegen   # install once
xcodegen generate       # regenerate project
```

## SwiftLint

Config: `.swiftlint.yml` at repo root. Raw color or font literals are lint violations — use design system tokens instead.

```bash
make lint
```

## Firebase CLI

Used for local emulator and Functions deployment.

```bash
npm install -g firebase-tools
firebase emulators:start     # start local Firestore + Functions emulator
```

## Android

The project uses the Gradle wrapper (`android/gradlew`). No system Gradle install needed. Java 21 is required.

```bash
export JAVA_HOME="$HOME/.homebrew/opt/openjdk@21"   # adjust to your Homebrew prefix
export ANDROID_HOME="$HOME/Library/Android"
cd android && ./gradlew assembleDebug
```

## iroh AAR rebuild

Builds `Vendor/openburnbar-iroh.aar` from the Rust crate at `crates/openburnbar-iroh`. Auto-installs NDK, `cargo-ndk`, and the required Rust cross-compile targets.

```bash
scripts/build-iroh-android-aar.sh
```

## Opus AAR rebuild

Builds `Vendor/opus-android.aar` from libopus 1.5 for four ABIs (arm64-v8a, armeabi-v7a, x86, x86_64).

```bash
scripts/build_opus_android.sh
```

## TypeSpec schema sync

Canonical Firestore contracts live in `tools/schema-sync/`. Run this before changing any shared model:

```bash
./tools/schema-sync/check-drift.sh
```

## Tech debt metrics

```bash
./scripts/ci/update-tech-debt-metrics.sh
```

Regenerates `docs/TECH_DEBT_METRICS.md`. Commit the updated file when baselines shift intentionally.

## CI workflows (`.github/workflows/`)

| Workflow file | Purpose |
|---|---|
| `openburnbar-pr-harness.yml` | Main PR CI: build, test, lint, evals |
| `release.yml` | Release pipeline (macOS, iOS, Android) |
| `nightly-e2e.yml` | Nightly end-to-end tests |
| `qa.yml` | Automated QA test suite |
| `codeql.yml` | CodeQL security analysis |
| `build-iroh-android-aar.yml` | Build and cache iroh Android AAR |
| `iroh-xcframework.yml` | Build iroh iOS xcframework |
| `computer-use-loopback-test.yml` | Computer Use loopback integration test |
| `droid-wiki-refresh.yml` | Auto-refresh the Factory wiki on push to main |
| `openburnbar-app-swiftpm-lock-refresh.yml` | Refresh SwiftPM resolved lockfile |
| `website-ci.yml` | Website build check |
| `workflow-lint.yml` | Lint workflow YAML files |
