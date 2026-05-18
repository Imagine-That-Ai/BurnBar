# Agent instructions — OpenBurnBar

This document is the **source of truth** for AI agents (Cursor, Claude Code, Codex, and similar) working in this repository. A shorter mirror for tools that prioritize `CLAUDE.md` lives in [`CLAUDE.md`](CLAUDE.md); **edit this file first** when changing the bar.

---

## The completion bar

The marginal cost of completeness is near zero with AI. **Do the whole thing.** Do it right. Do it with tests. Do it with documentation. Do it so well that Alberto is genuinely impressed — not politely satisfied, actually impressed.

Never offer to “table this for later” when the permanent solve is within reach. Never leave a dangling thread when tying it off takes five more minutes. Never present a workaround when the real fix exists.

The standard isn’t “good enough” — it’s **“holy shit, that’s done.”**

Search before building. Test before shipping. Ship the complete thing.

When Alberto asks for something, **the answer is the finished product**, not a plan to build it.

Time is not an excuse. Fatigue is not an excuse. Complexity is not an excuse. **Boil the ocean.**

---

## Working in this repo

- **Search the codebase** before adding new types, parsers, or UI; extend what exists unless the task explicitly requires greenfield work.
- **Tests:** add or update tests in the active `AgentLensTests` / `OpenBurnBarDaemon` test targets for behavior changes; long-lived stale suites belong under `AgentLensTests/Quarantine/` and are not compiled by default — see [`AgentLensTests/README.md`](AgentLensTests/README.md).
- **Docs:** user-facing or architectural changes belong in `docs/` and, when appropriate, [`CHANGELOG.md`](CHANGELOG.md) — follow existing doc voice and cross-links in [`README.md`](README.md).
- **Scope:** every line in a change should serve the request; avoid drive-by refactors and unrelated files.

Human-oriented Cursor and product context (onboarding, architecture, threat model) remains in the [docs/](docs/) tree — start with [`docs/OPENBURNBAR_CURSOR_AGENT_ONBOARDING.md`](docs/OPENBURNBAR_CURSOR_AGENT_ONBOARDING.md) and [`README.md`](README.md) **Cursor deep dives**.

---

## Android app (`android/`)

### Build & run

The Android app reaches **full iOS parity** as of 2026-05-16 — Hermes Square, messaging, iroh transport, and Mercury Media (file transfer, screen-share viewer, 1:1 calls) all ship in the same release. Read-only Firestore consumption is still the default Firestore pattern; the new outbound write paths (iroh pairing, media analytics, FCM tokens, mission dispatch, approval policy) follow the schemas in `functions/src/types.ts`.

| Command | What it does |
|---|---|
| `cd android && ./gradlew assembleDebug` | Build debug APK (Java 21, `ANDROID_HOME=$HOME/Library/Android`) |
| `cd android && ./gradlew clean assembleDebug --no-daemon 2>&1 \| grep "^e:\\|BUILD"` | Clean build, errors only |
| `cd android && ./gradlew :app:testDebugUnitTest --no-daemon` | Run the JVM unit suite (relay + media + missions + atom parser, ~253 tests) |
| `cd android && ./gradlew :openburnbar-iroh-relay:testDebugUnitTest --no-daemon` | iroh-relay library unit tests (codec + pairing + loopback transport) |
| `scripts/build-iroh-android-aar.sh` | Build `Vendor/openburnbar-iroh.aar` (auto-installs NDK + cargo-ndk + Rust targets) |
| `scripts/build_opus_android.sh` | Build `Vendor/opus-android.aar` from libopus 1.5 (4 ABIs) |
| `scripts/e2e/android-iroh-chat.sh` | Install debug APK + run the iroh chat instrumented suite via `adb` |
| `scripts/e2e/android-mercury-call.sh` | Install debug APK + run the Mercury call instrumented suite via `adb` |

### Firebase config

- **Real config:** `android/app/google-services.json` — **never committed** (the template `google-services.json.template` is safe in git).
- **CI injection:** base64-encoded into `GOOGLE_SERVICES_JSON_BASE64` GitHub secret; injected by `scripts/ci/inject-firebase-config-android.sh` (mirrors the iOS `scripts/ci/inject-firebase-config.sh` pattern).
- **Local dev:** download from Firebase Console → `cp ~/Downloads/google-services.json android/app/`. Full instructions in `android/app/AGENTS.md`.

### Data layer: schema alignment

**`functions/src/types.ts` IS THE CANONICAL SCHEMA.** Every Android model, parser, and store MUST match it. When the TypeScript interfaces change, the Android data layer MUST be updated in lockstep.

The key interfaces and their Android counterparts:

| TypeScript (`functions/src/types.ts`) | Android (`data/models/TokenUsage.kt`) | Firestore collection |
|---|---|---|
| `UsageEventDoc` | `TokenUsage` | `users/{uid}/usage/{doc}` |
| `UsageRollupDoc` | `UsageRollups` + `RollupSummary` | `users/{uid}/usage_rollups/{today,7d,30d,90d,all_time}` |
| `QuotaSnapshotDoc` | `ProviderQuotaSnapshot` + `QuotaBucket` | `users/{uid}/quota_snapshots/{provider}_{sourceId}` |
| `ProviderAccountDoc` | `ProviderAccount` | `users/{uid}/provider_accounts/{accountId}` |

**Model conventions:**
- Every data class annotated `@IgnoreExtraProperties` to tolerate server-side additions.
- `@PropertyName` for Firestore keys that differ from Kotlin camelCase (`providerID` → `providerId`).
- Computed properties (`get()`) live in the class body, NOT the primary constructor.
- Timestamps are converted from `com.google.firebase.Timestamp` via `it.seconds * 1000 + it.nanoseconds / 1_000_000`.

**Rollup edge case:** Cloud Functions writes **5 separate documents** (`usage_rollups/today`, `/7d`, `/30d`, `/90d`, `/all_time`), not one. Android's `mergeWindowDocs()` reads all 5 and merges them into a single flat `UsageRollups` client model.

### Store layer pattern

Each screen has a `*Store` (ViewModel subclass):
- `Suspend` methods for one-shot fetch (e.g., `load()`, `refresh()`).
- `callbackFlow` + `addSnapshotListener` for real-time listen (e.g., `startListening()`, `stopListening()`).
- Listener lifecycle is managed by `viewModelScope` — cancel on `stopListening()`.

### Automated schema sync

A Droid worker skill at `.factory/skills/android-firestore-worker/SKILL.md` handles future schema drift:
- **Phase 0:** read `functions/src/types.ts` + Android models + parsers
- **Phase 1:** diff every field
- **Phase 2–3:** update models + parsers
- **Phase 5:** `./gradlew clean assembleDebug` verification

To trigger: `droid exec "Align Android models to functions/src/types.ts"` (defaults to `android-firestore-worker` skill).

---

## Cross-platform scripts (`scripts/`)

All scripts follow `set -euo pipefail`, use absolute paths with `cd "$(dirname "$0")/.."`, and are executable.

| Script | Purpose |
|---|---|
| `scripts/cross-platform/setup-ios` | Verify Xcode, iOS simulator runtime, and `GoogleService-Info.plist` |
| `scripts/cross-platform/run-ios [device]` | Build + launch OpenBurnBarMobile on iOS Simulator (default: iPhone 17 Pro Max) |
| `scripts/cross-platform/setup-android` | Verify Java 21, Android SDK, `gradlew`, `google-services.json`, and emulator AVDs |
| `scripts/cross-platform/run-android` | Build APK + install on running emulator + launch BurnBar (auto-starts emulator if needed) |
| `scripts/ci/inject-firebase-config.sh` | iOS CI: injects `GoogleService-Info.plist` from `FIREBASE_PLIST_BASE64` |
| `scripts/ci/inject-firebase-config-android.sh` | Android CI: injects `google-services.json` from `GOOGLE_SERVICES_JSON_BASE64` |

Environment variables for Android:
```bash
export JAVA_HOME="$HOME/.homebrew/opt/openjdk@21" # or /opt/homebrew/opt/openjdk@21 on system Homebrew installs
export ANDROID_HOME="$HOME/Library/Android"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
```

---

## Computer Use (Phases 8–13)

**Master plan:** [`plans/2026-05-16-computer-use-master-plan.md`](plans/2026-05-16-computer-use-master-plan.md) · **Wire reference:** [`docs/HERMES_COMPUTER_USE.md`](docs/HERMES_COMPUTER_USE.md) · **Rollout log:** [`docs/runbooks/computer-use-rollout-status.md`](docs/runbooks/computer-use-rollout-status.md)

| Capability | Direction | Phase | Flag |
|---|---|---|---|
| Agent Watch — Mac → phone read-only mirror | Mac → iOS/Android | 8 | `computer_use_watch_enabled` |
| Browser Computer Use — agent drives Playwright Chromium | Agent → daemon | 9 | `computer_use_browser_enabled` |
| Trust modes + scope rules + audit chain | Mac UI | 10 | `computer_use_trust_modes_enabled` |
| Mac System Computer Use — CGEvent + AX | Agent → Mac | 11 | `computer_use_system_enabled` |
| Phone-as-controller — Ed25519-signed intents | Phone → Mac | 12 | `computer_use_phone_control_enabled` |
| Polish — Trusted scopes, audit export, OpenTimestamps | Cross-cutting | 13 | `computer_use_polish_enabled` |

**Key invariants:**
- Approval is the only ground truth at v1. No silent auto-pilot.
- Trust mode is per-session; never sticky across sessions.
- The audit chain is content-addressed (SHA-256 today, BLAKE3-swappable). Tamper detection covers every entry including the terminal one when `head.json` is supplied.
- Three independent panic-kill paths: `⌃⌥⌘.` global hotkey, phone three-finger long-press, NSWorkspace auth gate (loginwindow / SecurityAgent / screen sleep), Remote Config `computer_use_kill_switch`.
- Path C (Mac System) ships only via direct download with notarization. The MAS build compiles it out via `#if DISTRIBUTION_MAS`.

**Tool kinds:** `BurnBarToolKind.computerUseToolKinds` (13 kinds). New cases are auto-routed through `ComputerUseRunCoordinator`.

**Bridge script:** `OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js`. The driver pins `playwright@1.49.1` via `OpenBurnBarPlaywrightLifecycle`.

**Budget governance:**
- Soft cap at projected $1500/mo (envelope tightens to 25 actions/run · 100/day).
- Hard cap at $2500/mo (Remote Config kill-switch).
- Per-user daily ceiling $5 (normal) / $2.50 (soft) / $0 (hard).
- `evaluateComputerUseBudget` Cloud Function evaluates hourly.
