# Visual Capture Source Toggle — Comprehensive Subagent Plan

**Date:** 2026-05-09
**Status:** PLAN ONLY — awaiting review before implementation
**Branch:** `perf/hot-paths-latency-wins` (will fork to `feat/visual-capture-source-toggle`)
**Owners:** Prime Agent + 5 subagents (A–E)
**Related:** `docs/PERFORMANCE_SCALABILITY_REVIEW.md` §6, `AgentLens/Services/ComputerUse/Mac/MacScreenshotService.swift`, `AgentLens/Services/Media/ScreenCapturePipeline.swift`, `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/TokenUsage.swift` (`UsageExecutionSourceKind`), `AgentLens/Services/ManagedAgentRuntime/HermesRuntimeLauncher.swift`, `ProjectCodeMemory`, `ProviderQuota`

> **Goal:** Let users choose, per-provider, whether BurnBar visually shares the **CLI terminal (PTY)** or the **Desktop app / IDE window** — the same screen-share infra Codex and Hermes use — via a simple toggle. Persist the choice, default sensibly, and fall back gracefully when the chosen surface isn’t installed or permission-denied.

---

## 0) TL;DR for reviewers

* **Which CLIs have a desktop twin?** Confirmed `Both` set = **Codex (codex-cli ↔ codex-desktop), Claude (claude-code ↔ Claude Desktop), Cursor (cursor-agent CLI ↔ Cursor IDE), Windsurf, Cline, Kilo Code, Roo Code, Augment, Junie, Warp (warp CLI ↔ Warp Terminal), OpenCode, Hermes (hermes CLI ↔ Hermes Dashboard TUI)**. CLI-only = Antigravity, Factory/Droid, Gemini CLI, Kimi, MiniMax, Z.ai, Copilot CLI, Aider, Goose, OpenClaw, Prime Agent, Muse, Ollama (service), etc.
* **Toggle lives in two places:** (1) **Settings > Providers > [Provider] > Visual Surface** and (2) **Live session header / Screen Share viewer** (inline override). Global default in `SettingsManager` + per-provider override in `ProviderVisualCapturePreferences`.
* **Capture stays on existing engines:** PTY path = `PTYInteractiveSession` + `CLIProcessStreamRunner` + `BufferedLineSequence` (already streams line-by-line, 256KB bounded). Desktop path = `MacScreenshotService.CGDisplayCreateImage` + `ScreenCapturePipeline` (ShareableContent display/window) + `MercuryRouter`/`MercuryLinuxCaptureEngine` over iroh (already peer-to-peer, not through our servers). No new daemon socket, no new Firestore collection.
* **5 subagents, 5 coherent PRs** (each reviewable alone) — see §2.

---

## 1) Research: Which CLIs have desktop apps?

Derived from **canonical source** `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/TokenUsage.swift:78-245` (`UsageExecutionSourceKind`: `.cli`, `.desktopApp`, `.ide`, `.automation`, `.service`) + `AgentProvider.swift` + `docs/PROVIDERS.md` + filesystem probes.

| Provider (BurnBar `AgentProvider`) | CLI surface (what we parse today) | Desktop / IDE twin (what we can visually share) | `UsageExecutionSourceKind` | Detection today | Visual twin to add |
|---|---|---|---|---|---|
| **Codex** (`codex`) | `codex-cli` (`~/.codex/sessions/rollout-*.jsonl`, `codex` binary) | `codex-desktop` / “ChatGPT Desktop” (Electron) | `.cli` vs `.desktopApp` (dual) | ✅ `session_meta.source` distinguishes; file probes for `~/Library/Application Support/Codex` | **YES — toggle** |
| **Claude** (`claudeCode`) | `claude-code` (`~/.claude/projects/**/*.jsonl`, `claude` binary) | Claude Desktop (`/Applications/Claude.app`, `/Applications/Claude Code.app` if present) | `.cli` (today); needs `.desktopApp` sibling | ✅ `claude` binary probe; **add** `/Applications/Claude*.app` `mdfind`/`FileManager` probe | **YES — toggle** |
| **Cursor** (`cursor` + `cursorAgent`) | `cursor-agent` (`~/.cursor-agent/sessions/`, `cursor-agent` binary) | Cursor IDE (`/Applications/Cursor.app`, bundle `com.todesktop.230313mzl4w4u92`) | `.ide` for both (today conflated) — split to `.cli` for agent, `.ide` for IDE | ✅ `cursor-agent` probe; **add** `Cursor.app` bundle check | **YES — toggle** |
| **Hermes** (`hermes`) | `hermes` CLI (`~/.hermes/sessions/*.jsonl`, `hermes` binary) | Hermes Dashboard TUI (`hermes dashboard --tui`, `hermes gateway run`) via `HermesRuntimeLauncher` | `.cli` (today) — Dashboard is TUI not GUI, but visually capturable as OS window | ✅ `resolveHermesExecutable` + `probeGateway` | **YES — toggle (PTY vs Dashboard window)** |
| **Warp** (`warp`) | `warp` CLI (GraphQL) | Warp Terminal (`/Applications/Warp.app`) | `.cli` (today) — Warp is desktop terminal, so visual twin is the Warp window | ✅ GraphQL probe; **add** `Warp.app` | **YES — toggle** |
| **Windsurf** (`windsurf`) | local SQLite `~/.windsurf/...` | Windsurf IDE (`/Applications/Windsurf.app`) | `.ide` | ✅ install detection | **YES — toggle (PTY unused, but IDE window vs headless)** |
| **Cline** (`cline`) | `~/.cline` | VS Code + Cline extension (host is `/Applications/Visual Studio Code.app`) | `.ide` | ✅ install detection | **YES — toggle (extension host window)** |
| **Kilo Code** (`kiloCode`) | install detection only | Kilo Code IDE (`/Applications/Kilo Code.app` if exists, else VS Code host) | `.ide` | ✅ `KiloCodeQuotaAdapter` | **YES — toggle** |
| **Roo Code** (`rooCode`) | install detection | Roo Code IDE (`/Applications/Roo Code.app` / VS Code) | `.ide` | ✅ | **YES — toggle** |
| **Augment** (`augment`) | install detection | Augment IDE (VS Code) | `.ide` | ✅ | **YES — toggle** |
| **Junie** (`junie`) | `~/.junie/...` (JetBrains) | Junie / IntelliJ with Junie plugin (`/Applications/IntelliJ IDEA.app`) | `.ide` | ✅ `JunieParser` | **YES — toggle** |
| **OpenCode** (`openCode`) | `opencode` CLI (`~/.local/share/opencode/opencode.db`) | OpenCode TUI/Desktop (`opencode` TUI window) | `.cli` (today) — has TUI capturable | ✅ | **YES — toggle (CLI vs TUI window)** |
| **Ollama** (`ollama`) | `ollama` service + cloud routing | Ollama Desktop (`/Applications/Ollama.app`) | `.service` | ✅ `GET localhost:11434` + bundle check | **YES — toggle (service logs vs Desktop window)** |
| **Factory/Droid, Antigravity, Gemini CLI, Kimi, MiniMax, Z.ai, Copilot CLI, Aider, Goose, OpenClaw, Prime Agent, Muse, OMP, etc.** | CLI / local file only | **No desktop twin** | `.cli` / `.automation` | — | **NO toggle** — CLI-only chip, hide toggle, show “CLI only” |

**Source of truth:** `TokenUsage.swift:160` already has `known("codex-desktop", "Codex Desktop", .desktopApp)` and `known("codex-cli", "Codex CLI", .cli)` — we extend the same `UsageExecutionSourceResolver`/`ProviderBrand` pattern for Claude/Cursor/Warp etc., not a new registry.

**Detection strategy (per provider):**
* CLI: `CLIExecutableResolver().resolveExecutable(named:)` (already in `HermesRuntimeLauncherDependencies.resolveHermesExecutable`) + `FileManager` probe of `~/.<provider>/` directory (already in `ParserRegistry`).
* Desktop: `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` + `FileManager.fileExists(atPath: "/Applications/<App>.app")` + `mdfind "kMDItemCFBundleIdentifier == '<id>'"` fallback (sandbox-safe). Map in one place: `OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources/catalog.json` already has `catalog.json` — extend, don’t duplicate.

---

## 2) Subagent decomposition — 5 parallel plans (each is one PR)

### SUBAGENT A — RESEARCH & REGISTRY (no code, JSON+docs only)

**Goal:** Produce the canonical “Both vs CLI-only” table as code, not docs, so B–E can branch off without re-researching.

**Scope:**
* Extend `OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources/catalog.json` with per-provider `visualSurfaces: ["cli","desktop"]` or `["cli"]`.
* Extend `TokenUsage.swift` `UsageExecutionSourceResolver` to add missing `desktopApp` siblings: `claude-desktop`, `cursor-ide` split (currently `cursor` conflates), `warp-desktop`, `windsurf-ide` (already), etc. Add `claude-desktop` `known("claude-desktop","Claude Desktop",.desktopApp)`.
* Add `ProviderBrand.swift` icons for new desktop variants (reuse `PrimeAgentLogo` pattern).
* Update `docs/PROVIDERS.md` Execution-Source table.

**Files:**
* `OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources/catalog.json`
* `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/TokenUsage.swift` (+ `AgentProvider.swift` if splitting Cursor)
* `AgentLens/Models/ProviderBrand.swift` + `AgentLens/Resources/Assets.xcassets/*`
* `docs/PROVIDERS.md`

**Contract:**
```swift
enum VisualCaptureSource: String, Codable, Sendable, CaseIterable {
  case cliPT Y = "cli_pty"          // terminal PTY
  case desktopApp = "desktop_app"   // OS window/display
}
struct ProviderVisualSurfaces: Sendable {
  let provider: AgentProvider
  let surfaces: [VisualCaptureSource] // [] never, ["cli"] = CLI-only, ["cli","desktop"] = toggle eligible
}
```

**Validation:** `swift test --filter TokenUsageTests` + manual `catalog.json` JSONSchema validation + `docs/PROVIDERS.md` renders.

**Risks:** Splitting `cursor`’s `executionSourceID` changes historical rows — mitigate via `MigrationV57`-style backfill that preserves `unknown` unless evidence present (same pattern as `codex-desktop`).

---

### SUBAGENT B — DATA MODEL & PERSISTENCE

**Goal:** Where does the toggle live and survive?

**Scope:**
* `SettingsManager` (or new `ProviderVisualCapturePreferences` actor) — `@MainActor @Observable`:
  ```swift
  var visualCaptureGlobalDefault: VisualCaptureSource = .cliPT Y
  var visualCapturePerProvider: [AgentProvider: VisualCaptureSource] = [:] // nil = use global
  func visualCaptureSource(for provider: AgentProvider) -> VisualCaptureSource {
    // if provider is CLI-only → .cliPT Y regardless of pref
  }
  ```
* Persist in `UserDefaults` (key: `visualCaptureSource.<providerID>`) + `Codable` JSON blob for atomicity; migrate on launch.
* No new SQLite table — this is a local UX pref, not a usage row. Firestore opt-in replication via existing `ProviderAccountDeviceLinksObserver` pattern is out of scope for v1 (local-first).
* Feature flag: `SettingsManager.visualCaptureSourceToggleEnabled` bool (default `false` until B+C+D land) — reusable for phased rollout via `node scripts/rollout.mjs`.

**Files:**
* `AgentLens/Services/SettingsManager.swift` (or new `AgentLens/Services/Settings/Stores/VisualCapturePreferences.swift`)
* `AgentLens/Services/DataStore/OpenBurnBarDatabase+MigrationV58.swift` — **no migration needed** (UserDefaults), but add a comment referencing `V57 executionSource` pattern for future if we move to DB.
* `AgentLens/Services/CloudSync/RoamingProfileSyncService.swift` — stub (commented) for future sync.
* Tests: `AgentLensTests/Active/VisualCapturePreferencesTests.swift` (new)

**Validation:**
* Unit: set/get per provider, CLI-only override, global default, persistence round-trip, defaults to `.cliPT Y` on fresh install.
* `bash scripts/ci/check-no-suppressions.sh` — no new `UserDefaults` lint escape without `reason:` if needed.

**Risks:** Two settings stores (`SettingsManager` giant) — if review prefers, split to dedicated `VisualCapturePreferences` actor (ADR 001 naming `*Store`/`*Service`). Keep init small either way.

---

### SUBAGENT C — CAPTURE ENGINE (platform — Mac + Linux)

**Goal:** Make screen capture respect the toggle, without adding latency to the hot path fixed in PR #2193.

**Scope:**

* **Mac:**
  * `AgentLens/Services/ComputerUse/Mac/MacScreenshotService.swift` — add
    ```swift
    enum VisualCaptureMode { case cliPTY(pid: pid_t?, ptyFD: Int32?), case desktop(displayID: CGDirectDisplayID, windowID: CGWindowID?) }
    func capture(mode: VisualCaptureMode, label: String, sessionId: ComputerUseSessionID, entryIndexHint: Int) throws -> Capture
    ```
    * `.cliPTY` → reuse existing `PTYInteractiveSession`/`CLIProcessStreamRunner` frame (already bounded 256KB, line-by-line) — add optional PNG snapshot of the PTY view (`NSTextView` render) for visual viewers that expect an image.
    * `.desktop` → `CGDisplayCreateImage(displayId)` or `CGWindowListCreateImage(windowID)` filtered to the provider’s bundle (`com.anthropic.claudefordesktop`, `com.todesktop.230313mzl4w4u92` Cursor, `com.warp.Warp`, etc.) via `NSWorkspace` + `CGWindowListCopyWindowInfo`.
  * `AgentLens/Services/Media/ScreenCapturePipeline.swift` — add `surface: VisualCaptureSource` param; when `.cliPT Y` use PTY text path, when `.desktopApp` use `shareableContent` display/window path (already has `.screen` vs `.window` picker — wire toggle to it). Keep existing bandwidth caps (`media_normal_screen_share_min_per_day`).
  * `AgentLens/Services/ManagedAgentRuntime/HermesRuntimeLauncher.swift` — expose `visualSurface` so `HermesSquareRoot` knows whether to show PTY or Dashboard window chrome.

* **Linux:**
  * `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/MercuryLinuxCaptureEngine.swift` + `MercuryLinuxCaptureAdapter.swift` — same `VisualCaptureSource` branch: CLI → `PTYInteractiveSession` read, Desktop → PipeWire `xdg-desktop-portal` `ScreenCast` (already proven in `linux-port/evidence/mission-001/...`).

* **No new codec:** Reuse `MercuryRouter`/`HermesTransportSelector` iroh peer-to-peer; reuse `BurnBarConnectionGate` 128 cap.

**Files:**
* `AgentLens/Services/ComputerUse/Mac/MacScreenshotService.swift`
* `AgentLens/Services/Media/ScreenCapturePipeline.swift`
* `AgentLens/Services/Media/MediaSessionCoordinator.swift`
* `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/MercuryLinuxCapture*.swift`
* `AgentLens/Services/ManagedAgentRuntime/ManagedRuntimeProcessRunner.swift`

**Validation:**
* Manual: Hermes CLI vs Dashboard toggle — both produce PNGs under `~/Library/Application Support/OpenBurnBar/computer-use/<session>/screenshots/` with correct SHA256 audit chain.
* Perf: `BackgroundCadenceCoordinator` not woken; `MediaBudgetStatusStore` minutes counted correctly for both surfaces.
* `xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` green.

**Risks:** Desktop capture requires Screen Recording permission (`SystemPermissionMonitor` already gates) — if denied, fallback to CLI PTY + toast “Screen Recording denied — showing terminal”. CLI PTY capture must sanitize ANSI escapes before PNG render.

---

### SUBAGENT D — UI/UX

**Goal:** A toggle a user finds in 2 seconds, doesn’t break when the desktop app isn’t installed.

**Scope:**

* **Settings > Providers > [Provider row] > Visual Surface** (only for `Both` providers from A):
  ```
  [ ProviderLogo | Codex — Factory Droid ]   [ CLI Terminal ● | Desktop App ○ ]
                                             “Desktop app not installed — using terminal”
  ```
  * Component: `VisualCaptureToggle` (segmented control, 44pt hit target, VoiceOver label “Visual surface for Codex”, `accessibilityHint` “Shares terminal or desktop window when you start screen share”)
  * Disabled state: if `Both` but desktop bundle not found → segmented control disabled, caption shows fallback, `help` tooltip links to provider install guide (`docs/PROVIDERS.md`).
  * CLI-only providers → no toggle, shows `Badge("CLI only")` (same row, avoids layout shift).

* **Live session header / Screen Share viewer** (`ScreenShareViewer.swift`, `HermesSquareRoot.swift`, `ComputerUseSessionCoordinator.swift`):
  * Inline pill toggle next to “Screen Share” button — overrides Settings for this session only (writes back to `VisualCapturePreferences` on close if user taps “Remember”).
  * Empty state: before sharing, preview thumbnail shows PTY transcript vs Desktop window thumbnail.

* **Onboarding:** `SwitcherOnboardingScanAddStep.swift` already scans CLI accounts — add one line: “You can switch to Desktop app view anytime in Settings.”

**Files:**
* `AgentLens/Views/Settings/ConnectionsSettingsView.swift` + `AgentLens/Views/Settings/AccountSwitcher/AccountSwitcherSettingsView+Rendering.swift` (provider row)
* New: `AgentLens/Views/Settings/Components/VisualCaptureToggle.swift`
* `AgentLens/Views/Media/ScreenShareViewer.swift` + `OpenBurnBarMobile/Views/Hermes/Square/HermesSquareRoot.swift`
* `AgentLens/Views/Onboarding/Switcher/SwitcherOnboardingScanAddStep.swift`
* `AgentLens/Theme/DesignSystem.swift` (segmented style if needed)

**Validation:**
* Visual QA on macOS 14/15 light/dark, iPhone 17 Pro Max simulator (already parity gate), Linux desktop Tauri (`apps/linux-desktop/src/surfaces/settings/SettingsSurface.test.tsx`).
* A11y: VoiceOver reads both segments, focus order Settings → provider row → toggle, no keyboard trap.
* Interaction: rapid toggle 5× → no duplicate `MacScreenshotService` tasks (coalesce via existing `inFlightRefreshTask` pattern from PR #2193).

**Risks:** Settings row proliferation (10+ toggles) — mitigate with search in `SettingsManifest` (`visual surface` keywords already there) + collapsed “Advanced” disclosure for CLI-only bulk.

---

### SUBAGENT E — QA, TELEMETRY & ROLLOUT

**Goal:** Ship without regressing perf wins, and know which surface users actually prefer.

**Scope:**

* **Tests:**
  * Unit: `VisualCapturePreferencesTests` (B), `ProviderVisualSurfacesTests` (A), `MacScreenshotServiceTests.test_captureMode_branch` (C, with mocked `CGDisplayCreateImage`).
  * Integration: `SearchService+RetrievalMattersTests` already proves ≤3 trips — re-run after C touches `ScreenCapturePipeline` to ensure no extra wakeups.
  * E2E: `scripts/e2e/android-mercury-call.sh` + `scripts/e2e/android-iroh-chat.sh` already cover Mercury/iROH — add one `visual-surface=cli|desktop` param to each.

* **Telemetry (privacy-preserving, no screen contents):**
  * `AnalyticsEvent.visualCaptureSurfaceSelected = "visual_capture.surface_selected"` with `provider`, `surface` (cli|desktop), `trigger` (settings|session header), `fallbackUsed` (bool).
  * `LocalMetricsAggregator` — `visualCaptureSwitchCount` (1h window) — feeds `retrieval_health` pattern, not PII.

* **Perf budget:**
  * Desktop share must not breach PR #2193 idle budget (`<0.8% CPU / <140MB RSS` with no window) — when not sharing, `ScreenCapturePipeline` stays idle (no `CVDisplayLink`/`Timer`). When sharing, budget is `media_normal_screen_share_min_per_day` (120 min) — already in `SettingsManager`.

* **Rollout:**
  * Flag `visualCaptureSourceToggleEnabled` off by default on `main`. Advance via `node scripts/rollout.mjs --flag visualCaptureSourceToggleEnabled --stage ring-1` (internal), then `ring-2` (beta), then GA.
  * Rollback: `git revert` one PR per subagent; no DB migration to unwind (UserDefaults only). If capture regresses, flip flag off — no code revert needed.

* **Security:**
  * Screen Recording permission re-checked via `SystemPermissionMonitor` before every Desktop capture; if denied, fail closed to CLI PTY + audit log `computer_use_audit_export` (same chain as PR #2193).

**Files:**
* `AgentLensTests/Active/VisualCapturePreferencesTests.swift` + `OpenBurnBarCore/Tests/*`
* `functions/src/logging.ts` + `AgentLens/Services/Analytics/AnalyticsEvent.swift`
* `budgets/macos-idle-cpu.perf.json` + `scripts/ci/update-tech-debt-metrics.sh` (re-run)
* `docs/runbooks/rollback-automation.md` (one line for new flag)

**Validation:**
* `make ci` + `.github/workflows/fast-feedback.yml` + `xcodebuild build/test` green.
* `bash scripts/ci/verify-resilience-wiring.sh` + `bash scripts/ci/check-no-suppressions.sh` still pass.
* 5-min idle `powermetrics` re-run: still `<0.8% / <140MB` with toggle off.

**Risks:** Telemetry cardinality (`provider × surface`) could be high — cap to `visualCaptureSwitchCount` only, not per-frame.

---

## 3) Sequencing & dependencies

```
A (registry) ─┬─> B (prefs) ─┬─> C (engine) ─┬─> D (UI) ─┬─> E (qa/rollout)
              └──────────────┘              └───────────┘
```

* Week 1: A (+ B start) — no conflicts, JSON + UserDefaults only
* Week 2: C + D in parallel after A merges (both need `VisualCaptureSource` enum)
* Week 3: E + perf re-measure (uses artifacts from #2193 as baseline)
* Each is one PR, each has its own review map + rollback note per `AGENTS.md` factory loop.

---

## 4) What “done” looks like

* User opens Settings > Providers > Codex → sees “Visual Surface: CLI Terminal | Desktop App” — picks Desktop — starts screen share → sees Codex Desktop window, not terminal. Closes, reopens → preference remembered. Uninstalls Codex Desktop → toggle shows “Desktop not installed — using terminal” and auto-falls back.
* Same for Claude, Cursor, Windsurf, Cline, Warp, Hermes (Dashboard vs PTY), OpenCode, Ollama.
* CLI-only providers (Factory/Droid, Prime Agent, Muse, etc.) show “CLI only” badge, no toggle — no layout shift.
* Idle with no window still `<0.8% CPU / <140MB RSS` (perf wins from #2193 preserved).
* All existing tests + new `VisualCapturePreferencesTests` green, `check-no-suppressions.sh` green.

---

## 5) Open questions for review (block B/C/D if not answered)

1. Should `cursor` be split into `cursor-cli` (`.cli`) + `cursor-ide` (`.ide`) with distinct `executionSourceID`s, or keep conflated `cursor` with `surface` toggle? **Proposal:** split (matches `codex-cli`/`codex-desktop` precedent in `TokenUsage.swift:236-237`), migrate historical `cursor` rows to `cursor-ide` unless `session_meta` says otherwise.
2. Claude Desktop bundle ID: `com.anthropic.claudefordesktop` — confirm on 2-yr MBA that actually exists, or use `com.anthropic.claude-code` + `/Applications/Claude.app` path probe?
3. Warp: treat `warp` CLI probe (GraphQL) as sufficient to show toggle, or require `Warp.app` bundle? **Proposal:** require bundle for Desktop segment, else disabled with “Install Warp — brew install warp” link.
4. Hermes: is “Desktop App” for Hermes actually the Dashboard TUI window, or should Hermes be CLI-only? **Proposal:** treat Dashboard TUI as `desktopApp` visually (it’s an AppKit window via `SwarmWallpaperRuntime`), so toggle is meaningful — PTY = raw `hermes` log, Desktop = Dashboard chrome.

> **Decision needed before B:** Q1 (Cursor split) — affects `catalog.json` + `MigrationV58` wording.

---

## 6) File tree after all 5 PRs

```
OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources/catalog.json  (A)
OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/TokenUsage.swift (A, B)
AgentLens/Models/ProviderBrand.swift (A)
AgentLens/Services/Settings/Stores/VisualCapturePreferences.swift (B)  // NEW
AgentLens/Services/ComputerUse/Mac/MacScreenshotService.swift (C)
AgentLens/Services/Media/ScreenCapturePipeline.swift (C)
OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/MercuryLinuxCaptureEngine.swift (C)
AgentLens/Views/Settings/Components/VisualCaptureToggle.swift (D)  // NEW
AgentLens/Views/Media/ScreenShareViewer.swift (D)
OpenBurnBarMobile/Views/Hermes/Square/HermesSquareRoot.swift (D)
AgentLensTests/Active/VisualCapturePreferencesTests.swift (E)  // NEW
docs/PROVIDERS.md (A) + docs/perf-artifacts/ (E) + budgets/macos-idle-cpu.perf.json (E)
```

**No new lint suppressions, no new Firestore collection, no new daemon socket.**

---

*End of plan — awaiting your review. No code will be written until you approve.*
