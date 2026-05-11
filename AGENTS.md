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

The Android app is a **read-only Firestore consumer** — it displays burn data that other clients push to Firebase.

| Command | What it does |
|---|---|
| `cd android && ./gradlew assembleDebug` | Build debug APK (Java 21, `ANDROID_HOME=$HOME/Library/Android`) |
| `cd android && ./gradlew clean assembleDebug --no-daemon 2>&1 \| grep "^e:\\|BUILD"` | Clean build, errors only |

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
export JAVA_HOME="/opt/homebrew/opt/openjdk@21"
export ANDROID_HOME="$HOME/Library/Android"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
```
