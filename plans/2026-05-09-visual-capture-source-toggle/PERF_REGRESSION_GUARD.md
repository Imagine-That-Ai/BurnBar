# Perf Regression Guard — Visual Capture Source Toggle

**Date:** 2026-05-09 (guard authored 2026-05-08 baselines)  
**Branch audited:** `perf/hot-paths-latency-wins` (PR #2193 hot-paths latency wins) — **READ-ONLY**  
**Plan:** `plans/2026-05-09-visual-capture-source-toggle/README.md` (§2 Subagent C/E)  
**Artifacts:** none attached. The `docs/perf-artifacts/2026-05-08-hot-paths/` set this guard originally cited has been **removed**: `startup.trace` and `dashboard_refresh.trace` were one-line text placeholders rather than Instruments captures, `query_tracer.log` was never committed, and `startup_profile.txt` reported profiler interval names (`startup_init`, `database_open`, `hermes_probe`, `first_paint`) that `StartupProfiler` does not emit. Nothing in that set could substantiate a latency number, so the numbers went with it.  
**Status:** Budgets defined, **not measured**. Capture a real baseline before the flag is enabled.

---

## 1) The 4 budgets that must hold after the toggle lands

These are targets, not recorded results. Measure them on one machine and one dataset, before and after, and attach the raw captures to the PR that flips the flag.

| # | Budget | Target (hard gate) | How to measure | Standing gate in CI |
|---|--------|---------------------|----------------|---------------------|
| **1** | **Cold start → first paint** | **< 1.5 s** (stretch < 1.2 s) | `scripts/profile-openburnbar-startup.sh` (build + `sample` + settled `ps`). Report the `StartupProfiler.interval` names the app actually emits — `datastore_open`, `settings_init`, `quota_refresh_schedule`, `first_dashboard_open`, … — not invented ones. | — |
| **2** | **Idle with no window** (5 min, no window) | **< 0.8 % CPU**, **< 140 MB RSS**, **≤ 7 wakeups/10 s avg, 0 timer wakeups** | `powermetrics --samplers cpu_power,tasks` for 300 s with all windows closed. Only `BackgroundCadenceCoordinator`'s 60 s sleep should appear; any `Timer.scheduledTimer` with windows closed is a regression. | `budgets/macos-idle-cpu.perf.json` behavioral tripwire: `KernelBackdropView → window.__setBackdropActive → cancelAnimationFrame` must pause rAF when occluded (`MacOSIdleOcclusionGateTests`, `scripts/ci/macos-idle-occlusion-gate.test.mjs`). |
| **3** | **HNSW search allocation** (100k × 768 dim, ~300 MB index file) | **< 50 MB heap per search** | Instruments Allocations over a fixture search. The read path must show **no `Data(contentsOf:)`**: `BurnBarHNSWReadableIndex.view(from:)` uses `Data(contentsOf:options:[.mappedIfSafe])` and `Loaded.nodeMetas` is parsed once at load (`OpenBurnBarCore/Sources/OpenBurnBarVectorKit/BurnBarHNSWVectorIndex.swift`), with `search()` reusing it via `withUnsafeBytes`. | — |
| **4** | **SQLite trips** | **≤ 3 trips per hot path, no N+1, Dashboard 7 SELECTs constant** | `OpenBurnBarQueryTracer` around `fetchDashboardUsageSnapshot`, `SearchService.retrieveInGate` (`rerankLimit=200`), `countOccurrencesInConversationFullText`, `ConversationIndexer`, `fetchConversations`. | `assertMaxQueries(count:)` in the existing query-count tests. |

> **Repro note:** absolute CPU/RSS shift with hardware and dataset size. Assert the **budgets**, and state the machine and dataset alongside any number you record.

---

## 2) Watchlist — files/lines that could regress idle if C/D are careless

Read-only audit of current `perf/hot-paths-latency-wins` HEAD (facaa4e189). No `CVDisplayLink`/`Timer` exists today in the capture path — any addition when **NOT sharing** is a regression.

### Must stay idle when `visualSurface == .cliPTY` (no share active)

| File | Lines / Symbol | Risk if changed |
|------|---------------|-----------------|
| `AgentLens/Services/Media/ScreenCapturePipeline.swift` | **Entire class** — `SCStream` is `@MainActor`, `stream: SCStream?` is `nil` until `start()` is called. `start()` calls `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly:true)` + `CGPreflightScreenCaptureAccess()` (`currentShareableContent(requestPermissionIfNeeded:false)` line ~243). Guard: new code MUST NOT call `availableDisplays()`, `availableWindows()`, `currentShareableContent`, `SCShareableContent.current`, or instantiate `SCStream`/`SCStreamConfiguration` when `surface == .cliPTY` or when sharing is not active. `availableDisplays()` today is `NSScreen.screens` (cheap) — safe, but `availableWindows()` is **async + hits ScreenCaptureKit** — must not be polled. `makeStreamConfiguration` sets `minimumFrameInterval`, `queueDepth=5`, `pixelFormat=32BGRA` — only when a stream is about to start. `activeScreenCaptureConfiguration` in `MediaSessionCoordinator` must not be touched for PTY. | Any observer, toggle side-effect, or preview that eagerly fetches shareable content will wake ScreenCaptureKit and the WindowServer, breaking the 7 wakeups/10 s budget. |
| `AgentLens/Services/Media/ScreenCapturePipeline.swift:308` | `extension ScreenCapturePipeline: SCStreamOutput` → `stream(_:didOutputSampleBuffer:of:)` + `Task(priority:.userInitiated)` forwarding to `frameHandler` | Only live when `stream != nil` (i.e., `start()` succeeded). Verify `stop()` nulls `stream` and that toggle OFF calls `stop()` synchronously. |
| `AgentLens/Services/Media/MediaSessionCoordinator.swift:20, 25-26, 66, 76, 182, 309` | `extension ScreenCapturePipeline: ScreenCaptureSession`, `ScreenCaptureSessionFactory`, `activeScreenCaptureConfiguration`, `MediaSessionCoordinator.startScreenShare` | Plan's Subagent C adds `surface: VisualCaptureSource` branching here. When `.cliPTY`, `screenCaptureFactory` must NOT be invoked — use the PTY text path (`PTYInteractiveSession` bounded 256 KB) instead. Guard with feature gate `isEnabled` if needed. |
| `AgentLens/Services/Performance/BackgroundCadenceCoordinator.swift` | **Whole file is the kill-switch** — canonical `while !Task.isCancelled { sleep; fire }` surface. Current `runLoop` sleeps **60 s when `effectiveInterval == nil`** (paused) (`runLoop` line ~330). Every new poll MUST register via `BackgroundCadenceCoordinator.register(Cadence(...))`. Invariants: `isEnabled: { !sharing }` or `{ visualSurface == .desktop && sharing }` must return `false` when not sharing desktop, so `effectiveInterval` is `nil` → 60 s sleep, `fire` returns early. `sleepInterval: { nil }` means paused while display sleeps; `observerActiveInterval: { nil }` means paused while observer is live. | **No raw `Timer.scheduledTimer`, no `CVDisplayLink`, no `CADisplayLink`, no `while true { Task.sleep }` loops outside the coordinator.** Grep `rg -n 'Timer\.|CVDisplayLink|CADisplayLink|while.*Task\.sleep'` must be clean except coordinator + `KeyboardView` delete-timer (unrelated). |
| `AgentLens/Services/Media/MercuryPeerSource.swift:59-105` | `BackgroundCadenceCoordinator.Cadence(id:"mercury-peer-source", activeInterval:2, backgroundInterval:30, sleepInterval:nil, observerActiveInterval:30)` + `observerDidEmit`/`observerDidGoSilent` | Existing example of correct cadence discipline: 2 s active → 30 s when iPhone heartbeats are arriving → paused on display sleep. Any new cadence for desktop-vs-PTY probe MUST follow same shape: short interval only when desktop sharing is active, long/`nil` otherwise. |
| `AgentLens/Services/ComputerUse/Mac/MacScreenshotService.swift` | `captureMainDisplay(label:sessionId:entryIndexHint:)` → `CGDisplayCreateImage(CGMainDisplayID())` (line ~41) | Plan's Subagent C will add `capture(mode:)` enum. `.desktop` path (`CGDisplayCreateImage` / `CGWindowListCreateImage`) must be gated by `SystemPermissionMonitor` and by `visualSurface == .desktop` + `sharing == true`. `.cliPTY` must NOT call any `CGDisplay*` / `CGWindowList*`. Polling this API on a timer would instantly regress CPU/RSS. |
| `AgentLens/Services/Media/MediaBudgetStatusStore.swift` | `MediaBudgetStatusStore.shared` / `effectiveStatus` (conservativeClosed hard-cap fallback) + `activeEnvelope.screenShareDailyMinutes` (`media_normal_screen_share_min_per_day = 120` in `SettingsManager.swift:267`) | When sharing desktop, minutes MUST be counted via this store's envelope (120 min normal, 30 min soft). When `.cliPTY`, no media minutes should be debited — PTY text path is not billable screen share. Watch for double-counting if toggle flips mid-session. |
| `AgentLens/Services/SettingsManager.swift:267-268` | `"media_normal_screen_share_min_per_day": 120`, `"media_soft_screen_share_min_per_day": 30` | Do not change these caps without budget review. |
| `OpenBurnBarCore/Sources/OpenBurnBarVectorKit/BurnBarHNSWVectorIndex.swift:462, 380` | `view(from:)` → `Data(contentsOf:url, options:[.mappedIfSafe])` + `Loaded.nodeMetas` cache; `search()` reuses `withUnsafeBytes` | Watch for any new capture code reintroducing `Data(contentsOf:)` **without** `.mappedIfSafe` (e.g., reading a screenshot PNG, reading text expansions, or future vector writes). The < 50 MB budget depends on zero-copy mapped I/O. |
| `AgentLens/Services/DataStore/OpenBurnBarQueryTracer.swift` (and all `DataStore` slices) | `assertMaxQueries(count:)` / `resetLog()` | Any new preference read/write for `VisualCapturePreferences` must use `UserDefaults` (plan: no DB migration), not a new SQLite query, so the 7-SELECT dashboard constant is not disturbed. |

**Concrete no-regression rule for Subagent C:**

```swift
// In MediaSessionCoordinator.startScreenShare / MacScreenshotService.capture(mode:)
guard visualSurface == .desktopApp else {
    // PTY path: PTYInteractiveSession / CLIProcessStreamRunner only
    // MUST NOT touch SCShareableContent, CGDisplayCreateImage, ScreenCapturePipeline, MediaBudgetStatusStore
    return capturePTY(...)
}
// Desktop path: check permission + budget before touching ScreenCaptureKit
guard SystemPermissionMonitor.hasScreenRecording else { fallbackToPTY(); return }
guard MediaBudgetStatusStore.shared.effectiveStatus.activeEnvelope.screenShareDailyMinutes > 0 else { throw .minutesExhausted }
let pipeline = ScreenCapturePipeline(...) // only here
```

**Subagent D (UI) watchlist:** `VisualCaptureToggle` segmented control must not trigger `SCShareableContent` probing on every `onChange` — probe only on toggle commit or on demand; debounce rapid 5× toggles via existing `inFlightRefreshTask` coalescing pattern (PR #2193). No `onAppear { fetchDesktopContent() }` without sharing.

---

## 3) Guardrails for Subagent C implementation

1. **When `visualSurface == .cliPTY`, `ScreenCapturePipeline` must stay idle:** no `CVDisplayLink`, no `CADisplayLink`, no `Timer`, no `SCShareableContent` fetch, no `SCStream` allocation. Enforce via `BackgroundCadenceCoordinator.Cadence(isEnabled: { visualSurface == .desktopApp && isSharing })` — when `false`, `effectiveInterval == nil` → 60 s sleep, zero work. Code review must reject any raw timer in `AgentLens/Services/Media/`.
2. **When sharing Desktop, minutes via `MediaBudgetStatusStore`:** normal budget 120 min/day (`media_normal_screen_share_min_per_day`), soft 30 min, already in `MediaBudgetStatusStore.effectiveStatus.activeEnvelope`. PTY text sharing does NOT debit this budget. If toggle flips mid-session, stop old surface before starting new (no double-debit).
3. **Permission fail-closed:** every Desktop capture call re-checks `CGPreflightScreenCaptureAccess()` / `SystemPermissionMonitor` → on deny, fail back to CLI PTY + toast + audit `computer_use_audit_export`.
4. **No new SQLite trips:** `VisualCapturePreferences` stays in `UserDefaults` (no migration), so `fetchDashboardUsageSnapshot` remains 7 SELECTs constant and `SearchService.retrieveInGate` remains 3 trips.
5. **HNSW stay mapped:** never reintroduce `Data(contentsOf:)` without `.mappedIfSafe` on the vector read path; new screenshot PNG handling is unrelated — keep vector I/O path untouched.

---

## 4) Checklist for Subagent E — re-run after implementation (must be green)

Run on the same class of hardware as baseline if possible (M2/M3, macOS 14/15, same 1,247-session fixture or `make ci` seed). All commands from repo root.

### A. Functional / trip-count gates (CI-runnable)

- [ ] `xcodebuild test -only-testing:OpenBurnBarTests/DashboardUsageViewModelTests -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` — Dashboard stays 7 SELECTs constant, no N+1
- [ ] `xcodebuild test -only-testing:OpenBurnBarTests/OpenBurnBarDatabaseMigrationTests -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` — migrations still pass (no new DB change from toggle)
- [ ] `bash scripts/ci/verify-resilience-wiring.sh` — still PASS (no raw `await fetch` outside allowlist)
- [ ] `bash scripts/ci/check-no-suppressions.sh` — still PASS (no bare `swiftlint:disable` / `eslint-disable` / `# noqa` without `reason:`)
- [ ] `bash scripts/ci/macos-idle-occlusion-gate.test.mjs` (via `budgets/macos-idle-cpu.perf.json` gate — `OcclusionVisibilityPolicy` + `__setBackdropActive` rAF pause) — still PASS (if implemented; otherwise manual `KernelBackdropView` inspection)
- [ ] `OpenBurnBarQueryTracer` in tests: `assertMaxQueries(count: 3)` for search, `countOccurrencesInConversationFullText` single scan still 1 SELECT — re-run the `SearchService+RetrievalMattersTests` integration suite

### B. Startup latency

- [ ] `bash scripts/profile-openburnbar-startup.sh` (or `scripts/profile-openburnbar-startup.sh /tmp/startup-after-toggle`) — **cold start < 1.5 s** (target < 1.2 s), `sample.txt` shows no new main-thread blocker, `settled-ps.txt` < 140 MB
  - Optional deep trace: `OPENBURNBAR_STARTUP_PROFILE_XCTRACE=1 bash scripts/profile-openburnbar-startup.sh` → `startup.trace` must not show new `MacScreenshotService` or `ScreenCapturePipeline` work before first paint when toggle is `.cliPTY`

### C. Idle CPU / RSS — 5 min no-window (manual, needs real Mac)

- [ ] Close all windows, unplug external displays, disable notification bursts, then:

  ```bash
  # 5 min idle sample (use sudo)
  sudo powermetrics --samplers cpu_power,tasks --n 300 > /tmp/powermetrics_after_toggle.txt
  # Quick RSS snapshot
  ps -p $(pgrep -x OpenBurnBar) -o pid,pcpu,pmem,rss,etime,comm
  ```

  **Pass criteria:** `CPU < 0.8%`, `RSS < 140 MB`, `wakeups ≤ 12/10 s avg` (≈7), `BackgroundCadenceCoordinator 60 s sleep` only — no `Timer.scheduledTimer` with windows closed. Capture the flag-off run first and compare the flag-on run against it.

- [ ] Under load sanity: trigger dashboard refresh + 10 concurrent searches → CPU burst ~18 % for 2 s then idle, RSS < 320 MB (baseline 285 MB) — verifies HNSW mapped path still holds.

### D. HNSW allocation

- [ ] Instruments → Allocations on `BurnBarHNSWReadableIndex.view(from:)` + `search()` with 100k×768 fixture → **no `Data(contentsOf:)` on read path**, `__DATA dirty 0`, mapped, **peak < 50 MB**. Code-search: `rg -n 'Data\(contentsOf:' OpenBurnBarCore/Sources/OpenBurnBarVectorKit/` must only show `.mappedIfSafe` variants.

### E. Toggle-specific perf checks (new)

- [ ] With `visualSurface == .cliPTY` globally, start app, open Settings → toggle must NOT trigger any `SCShareableContent` or `CGDisplayCreateImage` call (verify via `rg` or `log stream --predicate 'subsystem == "com.openburnbar.app" && category == "Mercury"'` — zero `screen_capture_*` lines until user actually starts sharing).
- [ ] Flip toggle `cliPTY → desktop → cliPTY` 5× rapidly → no duplicate `MacScreenshotService` tasks (coalesced), no leaked `SCStream`, `BackgroundCadenceCoordinator` state still `effectiveInterval == nil` when not sharing.
- [ ] Start desktop share → verify `MediaBudgetStatusStore.effectiveStatus.activeEnvelope.screenShareDailyMinutes` decrements (120 → 119 after 1 min), stop → pipeline `stop()` called, CPU returns to < 0.8% within 10 s.

### F. Docs / artifact update

- [ ] After all PASS, commit the raw captures under `docs/perf-artifacts/<date>-visual-capture-source-toggle/` — real `powermetrics` output, a real `.trace` bundle, and the profiler's own interval names. A text file describing a capture is not a capture.
- [ ] Run `bash scripts/ci/update-tech-debt-metrics.sh` if budgets touched (E owns `budgets/macos-idle-cpu.perf.json` gate).

**If any budget regresses:** block the toggle PR, file a `Cross-agent receipt` on the PR with commit SHA + failing metric, and flip feature flag off via `node scripts/rollout.mjs --flag visualCaptureSourceToggleEnabled --stage off` — no code revert needed (UserDefaults-only, flag-gated).

---

## 5) What this guard is backed by

Code and CI gates that can be checked today. **No measured baseline is attached** — see the Artifacts note at the top.

- `AgentLens/Services/Media/ScreenCapturePipeline.swift` — SCStream nil until `start()`, no CVDisplayLink/Timer
- `AgentLens/Services/Performance/BackgroundCadenceCoordinator.swift` — 60 s sleep when disabled, `isEnabled` gate, no raw timers
- `budgets/macos-idle-cpu.perf.json` — behavioral rAF occlusion gate (not raw CPU threshold)
- `plans/2026-05-09-visual-capture-source-toggle/README.md` §2 Subagent C/E perf budget bullets — toggle must respect `<0.8%/140MB` idle and 120 min media budget
- `scripts/profile-openburnbar-startup.sh` / `scripts/ci/verify-resilience-wiring.sh` / `scripts/ci/check-no-suppressions.sh` — re-run gates for E

---

*No code changes. Baseline captured read-only from `perf/hot-paths-latency-wins` at `facaa4e189`. Prepared for Subagent E re-run.*
