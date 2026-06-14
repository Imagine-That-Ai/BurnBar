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

## Repo knowledge lives in mem0 - query it first

Search the BurnBar mem0 project before reading a wiki page or scanning `docs/`. The canonical Droid wiki (`droid-wiki/`) is mirrored there verbatim as retrievable chunks, refreshed on every commit, so a query returns the exact paragraph a task needs: subsystem architecture, data schemas, the RPC surface, feature internals, Computer Use phases, and the glossary instead of a whole page.

- **Claude Code:** call `mcp__mem0-burnbar__search_memories` with a natural-language query and `filters={"AND":[{"user_id":"burnbar"}]}`. Each result carries `metadata.source_path`; open that full `droid-wiki/<path>` page only when you need the entire page.
- **Other agents (Cursor, Codex, Droid):** query the same mem0 project (user_id `burnbar`); the `mem0-burnbar` server is defined in [`.mcp.json`](.mcp.json).

Export `MEM0_BURNBAR_API_KEY` (the BurnBar mem0 project key) in your shell to read and write the mirror, then run `bash scripts/wiki/install-hooks.sh` once. The sync engine is [`scripts/wiki/mem0-sync.mjs`](scripts/wiki/mem0-sync.mjs); the post-commit hook keeps mem0 current and a nightly job reconciles drift.

---

## Working in this repo

- **Search the codebase** before adding new types, parsers, or UI; extend what exists unless the task explicitly requires greenfield work.
- **Tests:** add or update tests in the active `AgentLensTests` source tree / `OpenBurnBarDaemon` test targets for behavior changes. The macOS app XCTest bundle is named `OpenBurnBarTests`, even though its sources live under `AgentLensTests/`; raw `xcodebuild` filters must use `-only-testing:OpenBurnBarTests/...`. Prefer `./scripts/test-openburnbar-app.sh` for app tests; it also normalizes the common `AgentLensTests/...` alias. Long-lived stale suites belong under `AgentLensTests/Quarantine/` and are not compiled by default — see [`AgentLensTests/README.md`](AgentLensTests/README.md).
- **Docs:** user-facing or architectural changes belong in `docs/` and, when appropriate, [`CHANGELOG.md`](CHANGELOG.md) — follow existing doc voice and cross-links in [`README.md`](README.md).
- **Architecture ADRs:** cross-cutting decisions live in [`docs/ARCHITECTURE/`](docs/ARCHITECTURE/README.md) (naming, actor isolation, errors, schema, sync).
- **Ops SLOs:** [`docs/runbooks/slos.md`](docs/runbooks/slos.md) is the operator runbook for latency/availability/error budgets.
- **Tech debt trends:** run `./scripts/ci/update-tech-debt-metrics.sh` before monthly debt reviews; commit updated [`docs/TECH_DEBT_METRICS.md`](docs/TECH_DEBT_METRICS.md) when baselines shift intentionally.
- **Scope:** every line in a change should serve the request; avoid drive-by refactors and unrelated files.
- **Mac CLI session paths (quota parsers):** Codex `~/.codex/sessions/`, Claude Code `~/.claude/projects/`, Grok Build `~/.grok/sessions/` (see [`GrokParser.swift`](AgentLens/Services/LogParser/GrokParser.swift) and [docs/PROVIDERS.md](docs/PROVIDERS.md)).
- **Database schema:** SQLite schema reference lives in [`docs/SCHEMA_SQLITE.sql`](docs/SCHEMA_SQLITE.sql); update it alongside any GRDB migration.
- **Feature rollouts:** use `node scripts/rollout.mjs --status` to see current ring status; `node scripts/rollout.mjs --flag <flag> --stage ring-N` to advance. Runbook: [`docs/runbooks/rollback-automation.md`](docs/runbooks/rollback-automation.md).
- **N+1 query detection:** `OpenBurnBarQueryTracer` in `AgentLens/Services/DataStore/OpenBurnBarQueryTracer.swift` — configure via `configure(in: &configuration)` before opening a database, then call `resetLog()` / `assertMaxQueries(count:)` in tests.
- **Sentry:** Callable errors auto-capture via `wrapCallableHandler` → `withCallableLogging` → `captureException()` in `functions/src/logging.ts`. Set `SENTRY_DSN` for production.
- **Circuit breakers:** Use `functions/src/resilienceHelpers.ts` (`stripeWithResilience`, `firestoreWithResilience`, `pushWithResilience`, `resilientFetch`, etc.). New provider HTTP must use `providerFetch` from `functions/src/providers/httpClient.ts`. CI enforces no raw `await fetch` in `functions/src`: `bash scripts/ci/verify-resilience-wiring.sh`.
- **Production callables:** Prefer `onCallProduction(name, options, handler)` from `logging.ts` for new exports (logging + Sentry).
- **Ops readiness:** `bash scripts/ci/verify-ops-readiness.sh` before release; production plane: `bash scripts/ops/verify-production-ops-plane.sh`; tag deploy runs `.github/workflows/deploy-production.yml`.
- **Fast CI:** `.github/workflows/fast-feedback.yml` runs lint + typecheck + unit tests in <5 min on every PR. The full macOS build runs separately. Fix fast-feedback failures first.
- **Automated review:** `.github/workflows/pr-review.yml` posts a structured review comment on every internal PR. Check the comment before merging.
- **Extension alerting:** import from `extensions/openburnbar/src/alerting.ts` — `alertDaemonUnreachable()`, `alertRunFailed()`, etc. Never use `vscode.window.showError*` directly.
- **Profiling functions:** `npm run profile --prefix functions` generates a `.cpuprofile` file for Chrome DevTools analysis.

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
| `./scripts/test-openburnbar-mobile.sh` | iOS mobile unit tests (`OpenBurnBarMobileTests`) on a connected physical iPhone locally; CI uses Simulator fallback — CI-gated |
| `./scripts/test-openburnbar-android.sh` | Android JVM unit tests (app + iroh-relay modules) — CI-gated |
| `make ci` | Full local CI parity (Functions, evals, Firestore rules, supply chain, all test surfaces) |
| `scripts/build-iroh-android-aar.sh` | Build `Vendor/openburnbar-iroh.aar` (auto-installs NDK + cargo-ndk + Rust targets) |
| `scripts/build_opus_android.sh` | Build `Vendor/opus-android.aar` from libopus 1.5 (4 ABIs) |
| `scripts/e2e/android-iroh-chat.sh` | Install debug APK + run the iroh chat instrumented suite via `adb` |
| `scripts/e2e/android-mercury-call.sh` | Install debug APK + run the Mercury call instrumented suite via `adb` |

**Schema sync:** canonical Firestore contracts live in [`tools/schema-sync/`](tools/schema-sync/) (TypeSpec → TS/Swift/Kotlin). Run `./tools/schema-sync/check-drift.sh` before changing shared models. Legacy hand-maintained types remain in `functions/src/types.ts` during migration.

### Firebase config

- **Real config:** `android/app/google-services.json` — **never committed** (the template `google-services.json.template` is safe in git).
- **CI injection:** base64-encoded into `GOOGLE_SERVICES_JSON_BASE64` GitHub secret; injected by `scripts/ci/inject-firebase-config-android.sh` (mirrors the iOS `scripts/ci/inject-firebase-config.sh` pattern).
- **Local dev:** download from Firebase Console → `cp ~/Downloads/google-services.json android/app/`. Full instructions in `android/app/AGENTS.md`.

### Data layer: schema alignment

**`functions/src/types.ts` IS THE CANONICAL SCHEMA** (migrating to [`tools/schema-sync/`](tools/schema-sync/) TypeSpec emitters). Every Android model, parser, and store MUST match it.

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
| `scripts/ci/update-tech-debt-metrics.sh` | Regenerates `docs/TECH_DEBT_METRICS.md` trend snapshot |

Environment variables for Android:
```bash
export JAVA_HOME="$HOME/.homebrew/opt/openjdk@21" # or /opt/homebrew/opt/openjdk@21 on system Homebrew installs
export ANDROID_HOME="$HOME/Library/Android"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
```

---

## Computer Use (Phases 8–13)

**Master plan:** [`plans/2026-05-16-computer-use-master-plan.md`](plans/2026-05-16-computer-use-master-plan.md) · **Wire reference:** [`docs/HERMES_COMPUTER_USE.md`](docs/HERMES_COMPUTER_USE.md) · **Rollout log:** [`docs/runbooks/computer-use-rollout-status.md`](docs/runbooks/computer-use-rollout-status.md)

Query mem0 for the phase matrix (phases 8–13, capabilities, feature flags), the 13 tool kinds, the Playwright bridge path, and the budget caps — `features/computer-use.md` and `reference/configuration.md` carry the full, current detail.

**Key safety invariants (always in force):**
- Approval is the only ground truth at v1. No silent auto-pilot.
- Trust mode is per-session; the phone can only downgrade trust (Trusted → Step → Manual), and elevation requires the Mac.
- The audit chain is content-addressed (SHA-256 today, BLAKE3-swappable). Tamper detection covers every entry including the terminal one when `head.json` is supplied.
- Three independent panic-kill paths halt a session — `⌃⌥⌘.` global hotkey, phone three-finger long-press, the NSWorkspace auth gate (loginwindow / SecurityAgent / screen sleep) — alongside the Remote Config `computer_use_kill_switch`.
- Path C (Mac System) ships only via direct download with notarization. The MAS build compiles it out via `#if DISTRIBUTION_MAS`.

---

## Cursor Cloud specific instructions

Cursor Cloud agents run on a **Linux** VM (Node 22 + Java 21 + pnpm preinstalled). **Purpose of this environment:** Cursor automation — inspecting GitHub CI logs (`gh`), editing code, running the npm/node test surfaces, opening PRs, and iterating on CI-failure fixes. It is **not** meant to need secrets or production Firebase access; do not block on those. The Swift/macOS/iOS clients (`AgentLens/`, `OpenBurnBar*`, `OpenBurnBarMobile/`) and the Android app (`android/`) **cannot build or run on Linux** and are out of scope here.

The primary PR gate is [`.github/workflows/fast-feedback.yml`](.github/workflows/fast-feedback.yml); reproduce a failing job locally by running that job's commands in the matching directory. The startup update script runs `npm ci` for every Node surface that workflow installs: `functions`, `extensions/openburnbar`, `website`, `apps/console`, `services/hermes-realtime-relay`, `services/hosted-mcp`, `tools/openburnbar-mcp-remote`, `tools/schema-sync`, and `packages/{libsignal-bridge,libsignal-protocol,signal-envelope-contracts,entitlements,design-tokens}`. (`packages/data-domains` and `packages/e2ee-backend-policy` have no lockfile and use pure-`node` codegen — no install.) Per-surface lint/test/build commands live in each `package.json`.

Non-obvious caveats:

- **`functions`/services build runs prebuild scripts** (`scripts/build-signal-envelope-contracts.sh`, `scripts/build-entitlements.sh`) that `tsc`-build `packages/signal-envelope-contracts` and `packages/entitlements`. `npm ci` alone does not build those, so run `npm --prefix functions run build` (or the service's build) before commands that need `functions/lib` or those compiled contracts. Several CI jobs run the two `scripts/build-*.sh` steps explicitly before tests.
- **`apps/console` dev server** is auth-gated: without real Firebase config it renders only a loading spinner (the dev server is still healthy — title shows "BurnBar Console"). `predev`/`prebuild`/`pretest` run `sync:domains` codegen from `packages/data-domains` + `packages/design-tokens`.
- **Firebase emulator (optional, not required for CI work).** If you do start it: there is no global `firebase-tools` and the CLI is not logged in — use the local binary `functions/node_modules/.bin/firebase` from the repo root with `--project burnbar`. It prompts for `defineString` params (e.g. `OPENBURNBAR_OTS_VERIFY_URL`, `APNS_VOIP_TOPIC`) one at a time, and in firebase-tools 15 the prompt is NOT suppressed by `--non-interactive`, `CI=true`, or `</dev/null`; auto-accept defaults with `yes "" | ./functions/node_modules/.bin/firebase emulators:start --only functions,firestore --project burnbar`. The `MetadataLookupWarning ... 169.254.169.254` lines are harmless. A dev-only `functions/.env` is not required (and `.env` keys with reserved prefixes `FIREBASE_`/`FUNCTION_`/`X_GOOGLE_`/`EXT_` are rejected by the Functions `.env` loader).
