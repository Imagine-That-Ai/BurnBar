# Subagent B — Data Model & Persistence Handoff

**Date:** 2026-05-09
**Branch:** `perf/hot-paths-latency-wins`
**Owner:** Subagent B — DATA MODEL & PERSISTENCE

## 1) Files

| File | Action | Description |
|------|--------|-------------|
| `AgentLens/Services/Settings/Stores/VisualCapturePreferences.swift` | **CREATED** | Dedicated `@Observable @MainActor` Store per ADR 001. Defines `VisualCaptureSource` enum + `VisualCapturePreferences` store. |
| `AgentLens/Services/SettingsManager.swift` | **MODIFIED** | Wires `let visualCapture: VisualCapturePreferences` into composition root + adds computed bridges (`visualCaptureSourceToggleEnabled`, `visualCaptureGlobalDefault`, `visualCapturePerProvider`, `visualCaptureSource(for:)`, `isToggleEligible(_:)`, `setVisualCaptureSource`, `clearVisualCaptureSource`). |
| `AgentLensTests/Active/VisualCapturePreferencesTests.swift` | **CREATED** | 14 tests, ephemeral `UserDefaults(suiteName:)` isolation, `flushDelayNanoseconds: 0`. |
| `docs/runbooks/rollback-automation.md` | **MODIFIED** | One section `Feature Flag Rollback — Visual Capture Source Toggle` with `defaults write` + key docs. |
| `OpenBurnBar.xcodeproj/project.pbxproj` | **MODIFIED** | Adds file refs + build phases for the two new files (main + test targets, lint-clean). |
| `budgets/` | **NOT TOUCHED** | Perf guard owns budgets; no change. |
| `OpenBurnBarCore/.../TokenUsage.swift` | **NOT TOUCHED** | Owned by A. |

## 2) Enum definition

```swift
public enum VisualCaptureSource: String, Codable, Sendable, CaseIterable {
    case cliPTY = "cli_pty"       // PTY terminal (safe default)
    case desktopApp = "desktop_app"
}
```

## 3) Default values

| Key | Type | Default | Persistence |
|-----|------|---------|-------------|
| `visualCaptureGlobalDefault` | `VisualCaptureSource` | `.cliPTY` | `UserDefaults` string `visualCaptureGlobalDefault` (`cli_pty`/`desktop_app`) |
| `visualCapturePerProvider` | `[AgentProvider: VisualCaptureSource]` | `[:]` (nil → use global) | JSON string `visualCapturePerProvider` = `[persistedToken: rawValue]` (e.g. `{"codex":"desktop_app"}`), removed when empty |
| `visualCaptureSourceToggleEnabled` | `Bool` | `false` (gates UI + engine branching) | `UserDefaults` bool `visualCaptureSourceToggleEnabled` |

Migration: fresh install → all `.cliPTY`; legacy JSON containing ineligible providers (e.g. `cline` → `desktop_app`) is decoded but **ignored** by `visualCaptureSource(for:)` (returns `.cliPTY`). `SettingsPersistenceCoordinator` with `objectExists` check prevents false `false` from missing keys.

## 4) Persistence keys (UserDefaults via `SettingsPersistenceCoordinator`)

- `visualCaptureGlobalDefault`
- `visualCapturePerProvider`
- `visualCaptureSourceToggleEnabled`

All writes go through `persistence.set(_:forKey:)` / `removeObject(forKey:)` with debounced flush; tests use `flushDelayNanoseconds: 0` for synchronous `UserDefaults` visibility. Suite is standard `UserDefaults.standard` in production (via `SettingsManager`).

## 5) Eligibility logic (Both list)

Hard-coded to audit-corrected `Both` = 11 active (12 `AgentProvider` cases because `cursor` splits into `cursor` + `cursorAgent`):

```swift
static let toggleEligibleProviders: Set<AgentProvider> = [
    .codex, .claudeCode, .cursor, .cursorAgent, .factory, .minimax, .zai, .devin, .hermes, .warp, .openCode, .ollama
]
```

- `windsurf` is legacy (now `devin-desktop`) → **not eligible**, always `.cliPTY`.
- Plugin-only (`cline`, `kiloCode`, `rooCode`, `augment`, `junie`) → not eligible.
- CLI-only (`antigravity`, `geminiCLI`, `kimi`, `copilot`, `aider`, `goose`, `openClaw`, `openClaude`, `omp`, `xAI`, `mimo`, `piAgent`, `forgeDev`, `primeAgent`, `muse` + catalog `openai`/`google`/`deepseek` etc.) → not eligible.
- Future: if `catalog.json` adds `visualSurfaces` for a new provider, update this set in `VisualCapturePreferences.swift` (single source of truth per plan §5 Q5; catalog is not decoded at runtime for this store).

```swift
func isToggleEligible(_ provider: AgentProvider) -> Bool
func visualCaptureSource(for provider: AgentProvider) -> VisualCaptureSource {
    guard isToggleEligible(provider) else { return .cliPTY }
    return visualCapturePerProvider[provider] ?? visualCaptureGlobalDefault
}
```

## 6) Test count + build output

**14 tests, all green:**

- `test_defaultsToCliPTYOnFreshInstall`
- `test_flagDefaultsToFalse`
- `test_toggleEligibility_BothProvidersAreEligible` (12 providers)
- `test_toggleEligibility_cliOnlyIsNotEligible` (`antigravity`)
- `test_toggleEligibility_pluginOnlyIsNotEligible` (5 plugin + `windsurf`)
- `test_cliOnlyOverrideEvenIfPerProviderPrefSaysDesktop`
- `test_pluginOnlyOverrideEvenIfPersistedJSONContainsDesktop` (legacy JSON migration)
- `test_globalDefaultFallback_nilPerProviderUsesGlobal`
- `test_setGetPerProviderRoundTripViaUserDefaults`
- `test_globalDefaultPersistsAcrossRecreate`
- `test_flagPersistsAcrossRecreate`
- `test_clearAllPerProviderPreferences`
- `test_overwritePerProviderPref`
- `test_settingsManagerBridgeRoundTrip`

**Validation:**

- `xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**
- `bash scripts/ci/check-no-suppressions.sh` → **✓ no unjustified suppressions or baselines**
- `xcodebuild test -only-testing:OpenBurnBarTests/VisualCapturePreferencesTests` → **Executed 14 tests, with 0 failures**
- `xcodebuild test -only-testing:OpenBurnBarTests/SettingsManagerTests` → **Executed 201 tests, with 0 failures** (regression guard)

No new lint suppressions, no `budgets/` changes, no Firestore collection, `UserDefaults` only (local-first v1).

## 7) How C/D should call `visualCaptureSource(for:)`

```swift
// Anywhere with a SettingsManager (AppKit main actor):
@MainActor
func captureSurface(for provider: AgentProvider) -> VisualCaptureSource {
    // Gate engine branching on the flag until rollout completes
    guard SettingsManager.shared.visualCaptureSourceToggleEnabled else { return .cliPTY }
    return SettingsManager.shared.visualCaptureSource(for: provider)
}

// Injected store (preferred for previews/tests):
@MainActor
func captureSurface(for provider: AgentProvider, prefs: VisualCapturePreferences) -> VisualCaptureSource {
    guard prefs.visualCaptureSourceToggleEnabled else { return .cliPTY }
    return prefs.visualCaptureSource(for: provider)
}

// Writing (Settings toggle or session-header pill):
SettingsManager.shared.setVisualCaptureSource(.desktopApp, for: .codex)
SettingsManager.shared.visualCaptureGlobalDefault = .desktopApp
SettingsManager.shared.visualCaptureSourceToggleEnabled = true // rollout gate

// Clear one provider (returns to global default):
SettingsManager.shared.clearVisualCaptureSource(for: .codex)
```

C should branch `MacScreenshotService`/`ScreenCapturePipeline` on this value (PTY vs `CGDisplayCreateImage`/`CGWindowListCreateImage`). D should hide the segmented control when `!isToggleEligible(provider)` (show `Badge("CLI only")`) and disable Desktop segment when bundle not installed, with caption fallback to `.cliPTY`. E can already flip the flag off via `defaults write com.openburnbar.app visualCaptureSourceToggleEnabled -bool NO` without code revert.

## 8) Notes

- `VisualCapturePreferences` is a proper domain store, not a god-object extension, per `AGENTS.md` / ADR 001 naming `*Store` (file is `*Preferences` to match task spec; class is `VisualCapturePreferences`).
- `AgentProvider.persistedToken` is used as the JSON dictionary key (lowercased, space-stripped, stable across renames).
- `Sendable` on enum, `@MainActor` isolation on store matches `SettingsManager`.
- Rollback is instant (flag off) or per-provider `defaults delete`; no DB migration to unwind.
