# Subagent D — UI/UX Handoff — Visual Capture Source Toggle

**Date:** 2026-05-09 (implementation)
**Branch:** `perf/hot-paths-latency-wins` — HEAD `08c70bd1b2` + D UI commits
**Owner:** Subagent D — UI/UX for Visual Capture Source Toggle
**Related:** `SUBAGENT_B_HANDOFF.md` (prefs API), `SUBAGENT_C_ENGINE.md` (capture engine, parallel)

---

## 1) Component API

### `VisualCaptureToggle` (Settings provider row)
**File:** `AgentLens/Views/Settings/Components/VisualCaptureToggle.swift` (NEW, 16.3kB)

```swift
@MainActor
struct VisualCaptureToggle: View {
    let provider: AgentProvider
    @Bindable var settingsManager: SettingsManager // default .shared
    init(provider: AgentProvider, settingsManager: SettingsManager = .shared)
    // Convenience overload for previews/tests that own a VisualCapturePreferences directly
    init(provider: AgentProvider, preferences: VisualCapturePreferences)
}
```

- Renders a **capsule segmented control** `CLI Terminal | Desktop App` (HStack inside `Capsule`, `DesignSystem.Colors.surfaceElevated`, `10pt .medium .rounded`, `32pt capsule + 44pt hit target`, `DesignSystem.Spacing` only).
- Reads `settingsManager.visualCaptureSource(for: provider)` and writes via `settingsManager.setVisualCaptureSource(_:for:)` on tap — no debounce, just UserDefaults (rapid 5× safe).
- Respects `accessibilityReduceMotion` (no animation when Reduce Motion is on).
- Also defines `VisualCaptureBundleChecker.isDesktopInstalled(for:)` reused by the inline pill.

### `VisualCaptureInlinePill` (live session header)
Same file, second view:

```swift
@MainActor
struct VisualCaptureInlinePill: View {
    let provider: AgentProvider
    @Bindable var settingsManager: SettingsManager
    var isCompact: Bool = true // "CLI"/"Desktop" vs "CLI Terminal"/"Desktop App"
}
```

- Compact segmented pill for `ScreenShareViewer` header (`Spacer()` + pill, `DesignSystem` capsule, `10pt`).
- Same SettingsManager store — v1 writes directly so Settings and session stay in sync. Handoff notes: future follow-up could make it session-only with `onDisappear` “Remember” write-back.

### `ScreenShareViewerInlineHeader` + `ScreenSharePreviewPlaceholder`
**File:** `AgentLens/Views/Media/ScreenShareViewer.swift` (extended, +95 lines)

```swift
struct ScreenShareViewerInlineHeader: View { let provider: AgentProvider; @Bindable var settingsManager: SettingsManager }
struct ScreenSharePreviewPlaceholder: View { let provider: AgentProvider; @Bindable var settingsManager: SettingsManager }
```

- `InlineHeader`: `Label("Screen Share")` + `VisualCaptureInlinePill` (gated by `visualCaptureSourceToggleEnabled`).
- `PreviewPlaceholder`: empty-state before sharing — `RoundedRectangle` with PTY vs Desktop copy (`"PTY terminal preview"` / `"Desktop window preview"` + `"Live transcript snippet"` / `"Window thumbnail when sharing starts"`), `ScreenCapturePipeline` preview hook point documented (use real thumbnail when available, else placeholder).

### Settings row placement

- **Connections → Accounts (`ProviderAccountGroup`)** — `AgentLens/Views/Settings/ConnectionsSettingsView+Rows.swift`:
  ```swift
  if let provider, SettingsManager.shared.visualCaptureSourceToggleEnabled {
      VisualCaptureToggle(provider: provider, settingsManager: SettingsManager.shared)
          .settingsAnchor("agents.visualSurface.\(provider.persistedToken)")
  }
  ```
  Inserted **below the header** (logo + name + subtitle) and **above the account ForEach**, so it sits directly under the provider’s subtitle/quota row per spec. Uses `VStack(spacing: DesignSystem.Spacing.sm)` — no new spacing constants.

- **Account Switcher → CLI provider sections** — `AgentLens/Views/Settings/AccountSwitcher/AccountSwitcherSettingsView+Rendering.swift` → `providerSection(_:)`:
  ```swift
  if let cliType = group.cliType, let provider = cliType.agentProvider, SettingsManager.shared.visualCaptureSourceToggleEnabled {
      VisualCaptureToggle(provider: provider, settingsManager: SettingsManager.shared)
  }
  ```
  Below `Text(providerSummary(for: group))` inside the same `VStack(alignment: .leading, spacing: 4)` that holds the label, so the toggle appears directly under the provider’s summary line.

Both placements are **gated by `visualCaptureSourceToggleEnabled`** — when flag `false`, the ForEach renders no toggle and the row looks exactly as before (no regression).

### Mobile parity
**File:** `OpenBurnBarMobile/Views/Hermes/Square/HermesSquareRoot.swift`

- New `@AppStorage("visualCaptureSource.hermes") private var mobileVisualSurfaceRaw: String = "cli_pty"` and `@AppStorage("visualCaptureSourceToggleEnabled")`.
- New `mobileVisualSurfaceToggle: some View` — `VStack` with label + `Picker(.segmented)` (`CLI Terminal | Desktop App`, `32pt + 44pt minHeight`, `MobileTheme` / `DesignSystemColors` tokens), gated by the same flag key as macOS (kept simple; iOS has no bundle check so both segments always enabled). Inserted in `mainDashboardContent` between `pinnedGridSection` and `projectMemorySection`.

### Onboarding one-liner
**File:** `AgentLens/Views/Onboarding/Switcher/SwitcherOnboardingScanAddStep.swift`

Appended after the `addedCount` HStack:

```swift
Text("You can switch to Desktop app view anytime in Settings > Providers.")
    .font(DesignSystem.Typography.caption)
    .foregroundStyle(DesignSystem.Colors.textSecondary)
```

---

## 2) Disabled / CLI-only / bundle-missing states

| State | Visual | Interaction | Caption / Tooltip |
|-------|--------|-------------|-------------------|
| **Flag off** (`!visualCaptureSourceToggleEnabled`) | `EmptyView()` — no toggle, no badge, no height change | — | Row looks exactly as before (no regression) |
| **CLI-only provider** (`!isToggleEligible(provider)`, e.g. `antigravity`, `cline`, `kiloCode`, `rooCode`, `augment`, `junie`, `windsurf` legacy) | `Badge("CLI only")` — `Capsule`, `10pt .semibold`, `DesignSystem.Colors.surfaceElevated`, same `32pt + 44pt` row height as toggle to avoid layout shift | No tap | `accessibilityValue="CLI only"`, hint "This provider has no desktop app — only the terminal can be shared" |
| **Both-eligible + Desktop bundle found** (e.g. `codex` with `/Applications/ChatGPT.app` or `com.openai.chat`, `claude` with `com.anthropic.claudefordesktop`, `cursor`/`cursorAgent` with `com.todesktop.230313mzl4w4u92`, `factory` `com.factory.app`, `warp` `com.warp.Warp`, `ollama` `com.ollama.ollama`, `minimax`, `zai`, `devin`, `hermes`/`openCode` always true) | Segmented control enabled, selected segment filled white with shadow, unselected muted | Tap writes via `setVisualCaptureSource` | Selected segment has `.isSelected` trait |
| **Both-eligible but Desktop bundle NOT found** | Segmented control **disabled** for Desktop segment (`opacity 0.45`, `.disabled(true)`), `CLI Terminal` remains tappable; `VStack` adds caption below control | CLI segment tappable, Desktop segment no-op | `HStack` with `exclamationmark.triangle.fill` (warning) + `Text("Desktop app not installed — using terminal")` (`.caption2` / `10pt`, `.secondary`) + `.help("Install the desktop app, or keep using CLI Terminal. See docs/PROVIDERS.md for download links.")`; outer `VStack` has `.help("Desktop app not installed — using terminal. See docs/PROVIDERS.md")` |

Bundle probe (`VisualCaptureBundleChecker`):
```swift
enum VisualCaptureBundleChecker {
    static func isDesktopInstalled(for provider: AgentProvider) -> Bool
    static func desktopBundleIdentifiers(for:) -> [String]
    static func desktopAppPaths(for:) -> [String]
}
```
Checks `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` first, then `FileManager.fileExists(atPath:)` for `/Applications/<App>.app` fallbacks. Reuses same IDs as engine (C): `com.anthropic.claudefordesktop`, `com.todesktop.230313mzl4w4u92`, `com.warp.Warp`, `com.factory.app`, `com.openai.chat`, `com.minimax.desktop`, `com.zai.desktop` / `com.zcode.app`, `com.devin.desktop`, `com.ollama.ollama`. `hermes`/`openCode` always return `true` (TUI/Dashboard embedded).

Screen Recording permission (C owns) is **not** handled in the toggle itself — the engine fails closed to PTY and emits via `SystemPermissionMonitor`. The toggle’s caption already covers the bundle-missing fallback; a future iteration could add a `Screen Recording denied` caption using `SystemPermissionMonitor.shared.snapshots[.screenRecording]` similar to the bundle caption.

---

## 3) A11y labels

**`VisualCaptureToggle` (segmented):**
- `accessibilityLabel("Visual surface for \(provider.displayName)")` on the capsule container
- `accessibilityHint("Shares terminal or desktop window when you start screen share")`
- `accessibilityValue` reflects current selection (`"CLI Terminal"` / `"Desktop App"`)
- Each segment `Button` has `.accessibilityAddTraits(.isSelected)` when active, `.help` tooltip
- Dynamic type via `.font(.system(...))` respects scaling; `ViewThatFits` not needed — `VStack` with `DesignSystem.Spacing` tokens keeps reflow

**`VisualCaptureInlinePill`:**
- Same `accessibilityLabel` / `accessibilityHint` / `accessibilityValue` as above, compact titles still readable by VoiceOver (`"CLI"` / `"Desktop"` map to same values)

**`CLI only` badge:**
- `accessibilityLabel("Visual surface for \(provider.displayName)")`, `accessibilityValue("CLI only")`, hint "This provider has no desktop app — only the terminal can be shared"

**Keyboard / focus:**
- Both segments are `Button(.plain)` inside `HStack` — Tab cycles Settings → provider row → toggle segments, no keyboard trap (verified via `Button` + plain style; no custom focus trap).

**Light/dark / reduced motion:**
- Colors via `DesignSystem.Colors` (adaptive `Color(editorial:light:dark:)` + `NSColor/UIColor` dynamic provider) — light (warm botanical cream) / dark (slate) correctly via `DesignSystem`.
- `@Environment(\.accessibilityReduceMotion)` read (reserved for future animation; current toggle has no spring — `Button` state change is instant, so reduced motion is already respected).

**Mobile:**
- `Picker(.segmented)` with `accessibilityLabel("Visual surface for Hermes")`, `accessibilityHint` / `accessibilityValue` same as macOS; `44pt` hit target via `.frame(minHeight: 44)`.

---

## 4) Build + check-no-suppressions output

```
$ xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/OpenBurnBar-build-D2
...
** BUILD SUCCEEDED **
```
Fresh derived data (`/tmp/OpenBurnBar-build-D2`) to avoid parallel-build DB lock (C running concurrently). Warnings are pre-existing (deprecated `CGWindowListCreateImage`, etc.), no new warnings from D files.

```
$ bash scripts/ci/check-no-suppressions.sh
✓ check-no-suppressions: no unjustified suppressions or baselines.
  allowlist: 19 artifact path(s), 25 scoped source file(s)
```

**Manual reasoning checks (required by task §7):**
- ✅ Toggle hidden when `visualCaptureSourceToggleEnabled == false` (both Settings rows return `EmptyView`, row looks exactly as before)
- ✅ Toggle visible when flag `true` and Both-eligible (`codex`, `claudeCode`, `cursor`, `cursorAgent`, `factory`, `minimax`, `zai`, `devin`, `hermes`, `warp`, `openCode`, `ollama`) — segmented control with 44pt hit target, 10pt medium, capsule style per DesignSystem
- ✅ CLI-only shows badge (`antigravity`, `cline`, `kiloCode`, `rooCode`, `augment`, `junie`, `windsurf` legacy) — same row height, no layout shift
- ✅ Bundle-missing disables Desktop segment, shows caption + help tooltip linking to `docs/PROVIDERS.md`

---

## 5) File list (owned by D — no capture engine or prefs logic touched)

| File | Action |
|------|--------|
| `AgentLens/Views/Settings/Components/VisualCaptureToggle.swift` | **NEW** — `VisualCaptureToggle` + `VisualCaptureInlinePill` + `VisualCaptureBundleChecker` (capsule segmented, 44pt, a11y, CLI-only badge, bundle-missing caption, previews) |
| `AgentLens/Views/Settings/ConnectionsSettingsView+Rows.swift` | **MODIFIED** — inserted toggle below `ProviderAccountGroup` header (inside `VStack`, gated by `visualCaptureSourceToggleEnabled`, with `.settingsAnchor`) — provider row integration (Rows file is the actual provider row for Connections) |
| `AgentLens/Views/Settings/AccountSwitcher/AccountSwitcherSettingsView+Rendering.swift` | **MODIFIED** — inserted toggle below `providerSummary` in `providerSection(_:)`, gated by flag + `cliType.agentProvider` |
| `AgentLens/Views/Media/ScreenShareViewer.swift` | **MODIFIED** — added `ScreenShareViewerInlineHeader` (inline pill) + `ScreenSharePreviewPlaceholder` (PTY vs Desktop empty state); `import OpenBurnBarCore` |
| `OpenBurnBarMobile/Views/Hermes/Square/HermesSquareRoot.swift` | **MODIFIED** — `@AppStorage` for `visualCaptureSource.hermes` + flag, `mobileVisualSurfaceToggle` Picker(.segmented) in `mainDashboardContent`, mobile parity (simple, no bundle check) |
| `AgentLens/Views/Onboarding/Switcher/SwitcherOnboardingScanAddStep.swift` | **MODIFIED** — one-line copy `You can switch to Desktop app view anytime in Settings > Providers.` after `addedCount` |
| `AgentLens/Views/Settings/Search/SettingsManifest.swift` | **MODIFIED** — new `agents.visualSurface` item + `visual surface` keywords to provider search + `visibleAnchorIDs` entry |
| `AgentLens/Views/Settings/Search/SettingsItem.swift` | **MODIFIED** — `SettingsAnchor.visualSurface = "agents.visualSurface"` |
| `OpenBurnBar.xcodeproj/project.pbxproj` | **MODIFIED** — added `VisualCaptureToggle.swift` fileRef + buildFile + `Components` PBXGroup |

**NON-GOALS respected:** No `VisualCapturePreferences` logic (B owns), no `MacScreenshotService` / `ScreenCapturePipeline` engine branching (C owns), no telemetry/budgets (E owns). Reads B’s `VisualCapturePreferences` API (`visualCaptureSourceToggleEnabled`, `visualCaptureSource(for:)`, `isToggleEligible`, `setVisualCaptureSource`) but does not modify it.

---

## 6) Design notes & follow-ups

- **Settings + session stay in sync (v1):** The inline pill writes directly to `SettingsManager` (same UserDefaults key as Settings toggle). Future follow-up could make the header pill session-only (`@State` + `onDisappear` “Remember” write-back) — documented in `VisualCaptureInlinePill` header comment.
- **Preview thumbnail:** `ScreenSharePreviewPlaceholder` is a styled placeholder; wire `ScreenCapturePipeline` real preview via `availableWindows()` / `availableDisplays()` when capture pipeline exposes a thumbnail publisher.
- **Bundle IDs:** Map is in `VisualCaptureBundleChecker`; if C adds new bundle IDs (e.g. additional Factory path `ai.factory.desktop`), keep this file in sync — single source-of-truth could be extracted to `OpenBurnBarCore` in a later PR.
- **a11y:** VoiceOver was reasoned and label/hint/value added; for full manual QA, run VoiceOver on 14/15 light/dark and verify Tab focus order Settings → provider row → toggle segments.

---

*End of handoff — D UI complete, gated by flag, premium capsule toggle, no layout shift, no engine touched.*
