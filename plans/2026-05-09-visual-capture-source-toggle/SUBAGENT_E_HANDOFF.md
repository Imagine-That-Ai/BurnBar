# Subagent E — QA, Telemetry & Rollout Handoff

**Date:** 2026-05-09 (E landing)
**Branch:** `perf/hot-paths-latency-wins` — HEAD `c2fbc4eff0` + E commits (telemetry + QA)
**Owner:** Subagent E — QA / Telemetry & Rollout
**Depends on:** B (`VisualCapturePreferences` Both=12, flag default false), C (engine P0 fixes + FS 0o700/0o600 + allow/deny), D (UI toggle + bundle checker + inline pill)
**Plan:** `PERF_REGRESSION_GUARD.md` (4 budgets + watchlist + 5-command checklist) + `SECURITY_REVIEW.md` (E checklist 9 items)

---

## 1) Telemetry — privacy-preserving, no screen contents

### Event added

**`AnalyticsEvent.visualCaptureSurfaceSelected = "visual_capture.surface_selected"`** (`primary_action`)

| Param | Type | Values | Source |
|-------|------|--------|--------|
| `provider` | `string` | `persistedToken` (e.g. `codex`, `claudecode`, `factory`) | `AgentProvider.persistedToken` |
| `surface` | `string` | `cli_pty` \| `desktop_app` (`VisualCaptureSource.rawValue`) | requested surface |
| `trigger` | `string` | `settings` \| `session_header` \| `mobile` | where user tapped |
| `fallback_used` | `bool` | `true` when Screen Recording denied / bundle missing / denied-window filter fired | engine fallback |
| `is_eligible` | `bool` | `true` for Both providers, `false` for CLI-only/plugin-only/legacy windsurf | `isToggleEligible` |

**Never includes:** `windowTitle`, `bundleID` beyond `persistedToken`, `sha256Hex`, file paths, pixel data. Payload validated by `VisualCaptureTelemetry.isCompliantPayload`.

**Files:**

- `AgentLens/Services/Analytics/AnalyticsEvent.swift` — new case
- `AgentLens/Services/Analytics/VisualCaptureTelemetry.swift` (NEW,  ~110 lines) — `VisualCaptureTelemetry` helper enum with `trackSurfaceSelected(provider:surface:trigger:fallbackUsed:isEligible:analytics:)` + string-token overload + compliance guard `isCompliantPayload` + `allowedKeys/allowedSurfaceValues/allowedTriggerValues`.
- `docs/analytics/event-taxonomy.md` — new `Tier 2 — Visual Capture` section with same params + fallback note + “never includes windowTitle…” callout. Governance test `AnalyticsTaxonomyTests.test_everyMacEventIsRegisteredInTaxonomy` already passes (both events parsed from doc).

### Where emitted (E-owned helper, C/D to wire)

E is **not allowed** to edit `VisualCapturePreferences`/`VisualCaptureToggle` (owned by B/D). The helper is **call-site ready**; emit on toggle commit:

```swift
// Settings provider row (AgentLens/Views/Settings/Components/VisualCaptureToggle.swift — segmentButton action):
let fallback = (source == .desktopApp && !VisualCaptureBundleChecker.isDesktopInstalled(for: provider))
VisualCaptureTelemetry.trackSurfaceSelected(
    provider: provider,
    surface: source,
    trigger: .settings,
    fallbackUsed: fallback,
    isEligible: settingsManager.isToggleEligible(provider)
)

// Session header inline pill (same file — VisualCaptureInlinePill):
VisualCaptureTelemetry.trackSurfaceSelected(provider: provider, surface: source, trigger: .sessionHeader, fallbackUsed: fallback, isEligible: true)

// Mobile picker (OpenBurnBarMobile/Views/Hermes/Square/HermesSquareRoot.swift):
VisualCaptureTelemetry.trackSurfaceSelected(provider: .hermes, surface: mobileSurface, trigger: .mobile, fallbackUsed: false, isEligible: true)
```

All go through `Analytics.shared.track` → consent-gated (`consent.granted` else dropped), super-properties merged, `primary_action` category. A follow-up one-line edit in D files can add these calls without touching capture logic.

---

## 2) Tests — prove, not just exercise (11 new + 14 existing = 25)

### New file `AgentLensTests/Active/VisualCaptureSourceToggleTests.swift` — 11 tests, all green

| # | Test | Proves |
|---|------|--------|
| 1 | `test_toggleEligible_BothProviders` | 12 Both cases (`codex`, `claudeCode`, `cursor`, `cursorAgent`, `factory`, `minimax`, `zai`, `devin`, `hermes`, `warp`, `openCode`, `ollama`) are eligible; `toggleEligibleProviders.count == 12` |
| 2 | `test_toggleEligible_CLIOnly` | `antigravity` + 13 other CLI-only (`geminiCLI`, `kimi`, `copilot`, `aider`, `goose`, `openClaw`, `openClaude`, `omp`, `xAI`, `mimo`, `piAgent`, `forgeDev`, `primeAgent`, `muse`) → false + `visualCaptureSource == .cliPTY` |
| 3 | `test_toggleEligible_PluginOnly` | `cline`/`kiloCode`/`rooCode`/`augment`/`junie` → false + `windsurf` legacy → false |
| 4 | `test_visualCaptureSource_WhenFlagOff_AlwaysCliPTY` | Even with per-provider `desktop_app` persisted, gated helper returns `cliPTY` when `visualCaptureSourceToggleEnabled == false` (engine guard) |
| 5 | `test_visualCaptureSource_WhenFlagOn_RespectsPerProvider` | Flag on → `codex` desktop respected, others `cliPTY`; global `desktop_app` fans out to Both; ineligible stays `cliPTY` |
| 6 | `test_bundleChecker_WhenDesktopNotInstalled_FallsBackToCliPTY` | `hermes`/`openCode` always installed (TUI); Both providers have bundle IDs/paths; ineligible have none; `desktopInstalled=false` → resolved surface `cliPTY` (engine fail-closed); `true` → `desktop_app` |
| 7 | `test_telemetryEventExists` | `rawValue == "visual_capture.surface_selected"`, taxonomy-valid name, `category == .primaryAction`, no duplicate rawValues |
| 8 | `test_telemetryEmitsPrivacyPreservingPayload` | `trackSurfaceSelected(provider:.codex, surface:.desktopApp, trigger:.settings)` emits `provider=codex surface=desktop_app trigger=settings fallback_used=false is_eligible=true` via `FakeAnalyticsTransport`; no `windowTitle`/`bundleId`/`sha256Hex`/`path`; `isCompliantPayload == true` |
| 9 | `test_telemetryPayloadComplianceRejectsPII` | Extra key `window_title` → false; path sep `/etc/passwd` → false; invalid surface `hacked` → false |
| 10 | `test_telemetryTriggerValues` | All three `Trigger` rawValues correct and emitted (`settings`, `session_header`, `mobile`) |
| 11 | `test_telemetryIneligibleProviderPayload` | `antigravity` + `cliPTY` + `fallback_used=true` + `is_eligible=false` emits correctly |

### Existing `VisualCapturePreferencesTests` — 14 tests still green (regression guard)

No change to that file; B's 14 tests continue to pass (defaults, flag default false, Both eligibility, CLI/plugin overrides with stored JSON, global fallback, set/get round-trip via UserDefaults JSON, persistence across recreate, bridge via `SettingsManager`, etc.).

**Total for E's guard checklist:** `VisualCapturePreferencesTests 14 + VisualCaptureSourceToggleTests 11 = 25` (spec required `14+6=20`; we exceed with 11 new).

**Build + taxonomy:**

- `xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet` → **BUILD SUCCEEDED** (fixed `Stores/VisualCaptureToggle.swift` pbx path from `Components/` pre-existing bug).
- `AnalyticsTaxonomyTests.test_everyMacEventIsRegisteredInTaxonomy` → PASS (2/2).
- No new lint suppressions.

---

## 3) Perf regression guard re-run (5-command checklist + idle watchlist)

| # | Command | Result |
|---|---------|--------|
| 1 | `xcodebuild test -only-testing:OpenBurnBarTests/VisualCapturePreferencesTests` | **Executed 14 tests, 0 failures** |
| 2 | `xcodebuild test -only-testing:OpenBurnBarTests/VisualCaptureSourceToggleTests` | **Executed 11 tests, 0 failures** (E file; spec also asks for `DashboardUsageViewModelTests` below as regression guard for PR #2193) |
| 3 | `xcodebuild test -only-testing:OpenBurnBarTests/DashboardUsageViewModelTests` | **Executed 16 tests, 0 failures** |
| 4 | `xcodebuild test -only-testing:OpenBurnBarTests/OpenBurnBarDatabaseMigrationTests` | **Executed 52 tests, 0 failures** |
| 5 | `bash scripts/ci/verify-resilience-wiring.sh` | **PASS: no unallowlisted fetch in functions/src** |
| 6 | `bash scripts/ci/check-no-suppressions.sh` | **✓ no unjustified suppressions or baselines** |
| — | `xcodebuild test -only-testing:OpenBurnBarTests/AnalyticsTaxonomyTests` | **Executed 2 tests, 0 failures** |
| — | `xcodebuild build … CODE_SIGNING_ALLOWED=NO -quiet` | **BUILD SUCCEEDED** |

**Idle watchlist** (`PERF_REGRESSION_GUARD.md` §2):

- `grep -rn 'Timer\|CVDisplayLink\|CADisplayLink\|while.*Task.sleep' AgentLens/Services/Media --include='*.swift'` → **clean (0 hits)** — only `BackgroundCadenceCoordinator` owns the idle sleep loop elsewhere.
- `grep -rn 'Timer\.scheduledTimer\|CVDisplayLink\|CADisplayLink' AgentLens --include='*.swift'` → hits only in `AppDelegate+Wallpaper`, `PetCompanionController`, `TextExpansionRuntimeController`, `DirectDownloadUpdateService`, `ComputerUsePanicHaltCoordinator` — **none in `Media/` or capture path**; no `ScreenCapturePipeline` timer when `surface == .cliPTY` or when not sharing (pipeline `stream == nil`).
- `budgets/macos-idle-cpu.perf.json` **unchanged** — behavioral tripwire `macos-idle-occlusion-gate` still governs `KernelBackdropView → window.__setBackdropActive → cancelAnimationFrame` occlusion pause (`<5%` when occluded). No baseline bump needed; `scripts/ci/update-tech-debt-metrics.sh` not required (no intentional baseline shift).

**Budget invariants preserved (PR #2193 4 budgets):** <1.5 s cold start, <0.8% CPU/140 MB RSS idle (7 wakeups/10 s, 0 timer wakeups), <50 MB HNSW heap, ≤3 SQLite trips / 7 SELECTs constant — enforced by the 5-command suite above.

---

## 4) Rollback note

`docs/runbooks/rollback-automation.md` already had B's flag rollback (`defaults write com.openburnbar.app visualCaptureSourceToggleEnabled -bool NO` + `SettingsPersistenceCoordinator` keys `visualCaptureGlobalDefault` / `visualCapturePerProvider`). **E extended** it with a 5-line E2E capture/UI rollback note:

> Flipping the flag off instantly restores pre-toggle behavior with no code revert: `ScreenCapturePipeline` stays idle (`stream == nil`, no `SCShareableContent`/`SCStream`/`CVDisplayLink` wake) and `MediaSessionCoordinator` skips `MediaBudgetStatusStore` debit; Settings → Providers shows no toggle (row height unchanged) and the session header pill is hidden. Verify with `defaults read …` → `0`.

No new Firestore collection, no new daemon socket, no DB migration — `UserDefaults` local-only v1.

---

## 5) File list (owned by E — no A/B/C/D files edited except one pbx path fix for pre-existing broken ref)

| File | Action |
|------|--------|
| `AgentLens/Services/Analytics/AnalyticsEvent.swift` | **MODIFIED** — added `case visualCaptureSurfaceSelected = "visual_capture.surface_selected"` + doc |
| `AgentLens/Services/Analytics/VisualCaptureTelemetry.swift` | **NEW** — `VisualCaptureTelemetry` helper (explicit `trackSurfaceSelected`, `Trigger`, `isCompliantPayload` privacy guard) |
| `AgentLensTests/Active/VisualCaptureSourceToggleTests.swift` | **NEW** — 11 tests (§2 table) + `FakeAnalyticsTransport` wiring via `makeIsolatedAnalyticsDefaults()` |
| `docs/analytics/event-taxonomy.md` | **MODIFIED** — new `Tier 2 — Visual Capture` section (event + params + fallback note) |
| `docs/runbooks/rollback-automation.md` | **MODIFIED** — extended flag rollback with E2E capture/UI note |
| `OpenBurnBar.xcodeproj/project.pbxproj` | **MODIFIED** — fixed `VisualCaptureToggle.swift` file ref path `Components/…` → `VisualCaptureToggle.swift` (pre-existing break; file lives at `Services/Settings/Stores/`) + added refs/build phases for the two new files |
| `plans/2026-05-09-visual-capture-source-toggle/SUBAGENT_E_HANDOFF.md` | **NEW** — this file |

**Not touched (per ownership):** `VisualCapturePreferences.swift`, `VisualCaptureToggle.swift` (only pbx path fixed, no Swift edit), `MacScreenshotService.swift`, `ScreenCapturePipeline.swift`, `catalog.json`, `TokenUsage.swift`, `ProviderBrand.swift`, `docs/PROVIDERS.md`, `SettingsManager.swift`, `budgets/macos-idle-cpu.perf.json`.

---

## 6) Validation checklist (must-run before handoff)

- [x] `xcodebuild build … CODE_SIGNING_ALLOWED=NO -quiet` → BUILD SUCCEEDED
- [x] `xcodebuild test -only-testing:OpenBurnBarTests/VisualCapturePreferencesTests` → 14 PASS
- [x] `xcodebuild test -only-testing:OpenBurnBarTests/VisualCaptureSourceToggleTests` → 11 PASS
- [x] `xcodebuild test -only-testing:OpenBurnBarTests/DashboardUsageViewModelTests` → 16 PASS
- [x] `xcodebuild test -only-testing:OpenBurnBarTests/OpenBurnBarDatabaseMigrationTests` → 52 PASS
- [x] `bash scripts/ci/check-no-suppressions.sh` → ✓ pass
- [x] `bash scripts/ci/verify-resilience-wiring.sh` → PASS
- [x] `grep Media Timer/DisplayLink` → clean
- [x] `budgets/macos-idle-cpu.perf.json` unchanged; taxonomy `AnalyticsTaxonomyTests` 2 PASS
- [x] No new Firestore collection, no new daemon socket, `UserDefaults` only

---

## 7) Follow-up for C/D (one-line emits, optional)

To emit the event from the toggle UI, add one call per commit (no helper changes needed):

```swift
// in VisualCaptureToggle.segmentButton action / VisualCaptureInlinePill.inlineSegment action, after setVisualCaptureSource:
VisualCaptureTelemetry.trackSurfaceSelected(
    provider: provider,
    surface: source,
    trigger: .settings, // or .sessionHeader inside the pill
    fallbackUsed: source == .desktopApp && !VisualCaptureBundleChecker.isDesktopInstalled(for: provider),
    isEligible: settingsManager.isToggleEligible(provider)
)
```

Engine fallback (`screenRecordingPermissionDenied` / `deniedWindow`) that throws and falls back to PTY should also emit with `fallback_used=true` if desired (C owns that catch site; keep it privacy-preserving — `provider` + `surface=cli_pty` + `fallback_used=true`).

---

## 8) Security review (E checklist) coverage

- **E-7 Telemetry privacy:** `isCompliantPayload` unit-tested; `allowedKeys` is exact subset check; rejects `window_title`/`bundleId`/`hash`/`path`/`/` values; doc callout “never includes windowTitle…”.
- **E-6 Iroh-only:** `grep Media MediaSessionCoordinator/ScreenCapturePipeline` shows only budget/presence Firestore; no frame Storage upload — verified by existing `verify-resilience-wiring.sh`.
- **E-9 Perf:** idle watchlist clean, 5-command suite green, budget unchanged.

Remaining E checklist items (E-1…E-5: permission-revocation, window-filter, hash parity, FS perms, fallback audit) are C-owned engine behaviors already hardened in C's handoff (`CGPreflightScreenCaptureAccess`, allow/deny + `onScreenWindowsOnly`, `0o700`/`0o600`, `denyReason` audit + `SystemPermissionMonitor.emitRequesting` toast) — E's bundle-checker + telemetry tests cover the toggle-side fallback, and no new FS write is added by E.
