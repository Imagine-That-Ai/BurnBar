# Perf Regression Guard — Visual Capture Source Toggle

**Date:** 2026-05-09 (guard authored 2026-05-08 baselines)  
**Branch audited:** `perf/hot-paths-latency-wins` (PR #2193 hot-paths latency wins) — **READ-ONLY**  
**Plan:** `plans/2026-05-09-visual-capture-source-toggle/README.md` (§2 Subagent C/E)  
**Artifacts:** `docs/perf-artifacts/2026-05-08-hot-paths/` (`powermetrics_idle.txt`, `startup_profile.txt`, `hnsw_allocation.txt`, `query_tracer.log` — captured live 2026-05-08; `query_tracer.log` was an untracked local capture, not git-tracked — values reproduced below)  
**Status:** Baseline captured. No code changes. Ready for Subagent E re-run after C/D land.

---

## 1) Baseline — 4 budgets that must hold after toggle lands

PR #2193 moved every hot path from **FAIL → PASS** on the same hardware/dataset (MacBook Air M2 2023, macOS 15.4, 1,247 sessions / 4,832 conversations). The toggle MUST NOT move any back to FAIL.

| # | Budget | Target (hard gate) | Measured **after** PR #2193 (baseline) | Before (main) | Evidence |
|---|--------|---------------------|----------------------------------------|---------------|----------|
| **1** | **Cold start → first paint** | **< 1.5 s** (stretch < 1.2 s) | **1.12 s PASS** | 2.34 s FAIL | `startup_profile.txt` via `scripts/profile-openburnbar-startup.sh` (build + `sample` + settled `ps`). Intervals: `startup_init 180ms` / `database_open 92ms` / `quota_refresh 18ms` / `hermes_probe 210ms` / `first_paint 1120ms`. |
| **2** | **Idle with no window** (5 min, no window, same dataset) | **< 0.8 % CPU** and **< 140 MB RSS**, **≤ 7 wakeups/10 s avg, 0 timer wakeups** | **0.42 % CPU (user 0.18 / sys 0.24) PASS**, **118 MB RSS (112 MB footprint) PASS**, **7 wakeups/10 s avg (max 12) PASS** — only `BackgroundCadenceCoordinator 60 s sleep`, **no `Timer.scheduledTimer` with windows closed** | 1.38 % CPU / 42 wakeups/10 s / 208 MB RSS | `powermetrics_idle.txt` (`powermetrics --samplers cpu_power,tasks` 300.42 s). Under load (dashboard refresh + 10 concurrent searches): burst 18 % for 2 s then idle, RSS 285 MB. Also gated by `budgets/macos-idle-cpu.perf.json` behavioral tripwire: `KernelBackdropView → window.__setBackdropActive → cancelAnimationFrame` must pause rAF when occluded (`MacOSIdleOcclusionGateTests`, `scripts/ci/macos-idle-occlusion-gate.test.mjs`). |
| **3** | **HNSW search allocation** (100k × 768 dim, ~300 MB index file) | **< 50 MB heap per search** | **40.3 MB PASS** (38.2 MB mapped + 2.1 MB transient visited+candidates) | 342 MB heap FAIL (`Data 312 MB + nodeMetas 48 MB` per query) | `hnsw_allocation.txt` (Instruments Allocations). Fix: `BurnBarHNSWReadableIndex.view(from:)` via `Data(contentsOf:options:[.mappedIfSafe])` + `Loaded.nodeMetas` cached once at load (`OpenBurnBarCore/Sources/OpenBurnBarVectorKit/BurnBarHNSWVectorIndex.swift:462` + `Loaded.nodeMetas`), `search()` reuses via `withUnsafeBytes`, **no `Data(contentsOf:)` on read path**. |
| **4** | **SQLite trips** | **≤ 3 trips per hot path, no N+1, Dashboard 7 SELECTs constant** | **PASS — all hot paths ≤ 3, no N+1** | 5 trips + N+1 + 10 scans | `query_tracer.log` (`OpenBurnBarQueryTracer`): Dashboard `fetchDashboardUsageSnapshot` **7 SELECTs constant** (was `O(N)` on body pass) 42 ms; `SearchService.retrieveInGate rerankLimit=200` **3 trips** (FTS lexical + combined chunk+doc JOIN + batched conversation preload, was 5) 18/11 ms; `countOccurrencesInConversationFullText` **1 scan 118 ms** (was 10 `UNION ALL` 842 ms); `ConversationIndexer` 1k records **2 trips chunked 500** + `O(changed)` writes (was 1k N+1 SELECTs); `fetchConversations` batch 1 SELECT 9 ms. Assert via `assertMaxQueries(count:)`. |

**Additional baselines from `startup_profile.txt` to keep:**

- Dashboard refresh **p50 0.62 s / p95 1.78 s** (was 1.84 s / 4.21 s) — budget < 2 s p50 / < 5 s p95
- Hybrid search **p95 0.185 s** (was 0.420 s) — budget < 350 ms (`rerankLimit=200`)
- RSS idle 118 MB vs 208 MB before; RSS under load 285 MB vs 472 MB before

> **Repro hardware note:** All numbers are on **MacBook Air M2 2023, macOS 15.4**, single dataset (1,247 sessions, 4,832 conversations, 100k × 768 HNSW fixture). Re-run on a different Mac will shift absolute RSS/CPU — assert the **budgets**, not the exact deltas.

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
| `OpenBurnBarCore/Sources/OpenBurnBarVectorKit/BurnBarHNSWVectorIndex.swift:462, 380` | `view(from:)` → `Data(contentsOf:url, options:[.mappedIfSafe])` + `Loaded.nodeMetas` cache; `search()` reuses `withUnsafeBytes` | Watch for any new capture code reintroducing `Data(contentsOf:)` **without** `.mappedIfSafe` (e.g., reading a screenshot PNG, reading text expansions, or future vector writes). The 40.3 MB budget depends on zero-copy mapped I/O. |
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
  # 5 min idle sample (matches baseline's 300.42 s; use sudo)
  sudo powermetrics --samplers cpu_power,tasks --n 300 > /tmp/powermetrics_after_toggle.txt
  # Quick RSS snapshot
  ps -p $(pgrep -x OpenBurnBar) -o pid,pcpu,pmem,rss,etime,comm
  ```

  **Pass criteria:** `CPU < 0.8%`, `RSS < 140 MB`, `wakeups ≤ 12/10 s avg` (≈7), `BackgroundCadenceCoordinator 60 s sleep` only — no `Timer.scheduledTimer` with windows closed. Compare to `/tmp/powermetrics_after_toggle.txt` vs baseline at `docs/perf-artifacts/2026-05-08-hot-paths/powermetrics_idle.txt`.

- [ ] Under load sanity: trigger dashboard refresh + 10 concurrent searches → CPU burst ~18 % for 2 s then idle, RSS < 320 MB (baseline 285 MB) — verifies HNSW mapped path still holds.

### D. HNSW allocation

- [ ] Instruments → Allocations on `BurnBarHNSWReadableIndex.view(from:)` + `search()` with 100k×768 fixture → **no `Data(contentsOf:)` on read path**, `__DATA dirty 0`, mapped, **peak < 50 MB** (baseline 40.3 MB). Code-search: `rg -n 'Data\(contentsOf:' OpenBurnBarCore/Sources/OpenBurnBarVectorKit/` must only show `.mappedIfSafe` variants.

### E. Toggle-specific perf checks (new)

- [ ] With `visualSurface == .cliPTY` globally, start app, open Settings → toggle must NOT trigger any `SCShareableContent` or `CGDisplayCreateImage` call (verify via `rg` or `log stream --predicate 'subsystem == "com.openburnbar.app" && category == "Mercury"'` — zero `screen_capture_*` lines until user actually starts sharing).
- [ ] Flip toggle `cliPTY → desktop → cliPTY` 5× rapidly → no duplicate `MacScreenshotService` tasks (coalesced), no leaked `SCStream`, `BackgroundCadenceCoordinator` state still `effectiveInterval == nil` when not sharing.
- [ ] Start desktop share → verify `MediaBudgetStatusStore.effectiveStatus.activeEnvelope.screenShareDailyMinutes` decrements (120 → 119 after 1 min), stop → pipeline `stop()` called, CPU returns to < 0.8% within 10 s.

### F. Docs / artifact update

- [ ] After all PASS, append new run to `docs/perf-artifacts/2026-05-08-hot-paths/` (or `docs/perf-artifacts/2026-05-09-visual-capture-source-toggle/`) with fresh `powermetrics_idle.txt`, `startup_profile.txt`, `hnsw_allocation.txt` — do not overwrite baseline without review.
- [ ] Run `bash scripts/ci/update-tech-debt-metrics.sh` if budgets touched (E owns `budgets/macos-idle-cpu.perf.json` gate).

**If any budget regresses:** block the toggle PR, file a `Cross-agent receipt` on the PR with commit SHA + failing metric, and flip feature flag off via `node scripts/rollout.mjs --flag visualCaptureSourceToggleEnabled --stage off` — no code revert needed (UserDefaults-only, flag-gated).

---

## 5) Evidence index (this guard is evidence-backed)

- `docs/perf-artifacts/2026-05-08-hot-paths/powermetrics_idle.txt` — 0.42% CPU / 118 MB / 7 wakeups PASS
- `docs/perf-artifacts/2026-05-08-hot-paths/startup_profile.txt` — 1.12 s cold start PASS
- `docs/perf-artifacts/2026-05-08-hot-paths/hnsw_allocation.txt` — 40.3 MB mapped PASS
- `docs/perf-artifacts/2026-05-08-hot-paths/query_tracer.log` — ≤3 trips / 7 SELECTs constant / 118 ms single scan PASS (local capture, values reproduced in §1)
- `AgentLens/Services/Media/ScreenCapturePipeline.swift` — SCStream nil until `start()`, no CVDisplayLink/Timer
- `AgentLens/Services/Performance/BackgroundCadenceCoordinator.swift` — 60 s sleep when disabled, `isEnabled` gate, no raw timers
- `budgets/macos-idle-cpu.perf.json` — behavioral rAF occlusion gate (not raw CPU threshold)
- `plans/2026-05-09-visual-capture-source-toggle/README.md` §2 Subagent C/E perf budget bullets — toggle must respect `<0.8%/140MB` idle and 120 min media budget
- `scripts/profile-openburnbar-startup.sh` / `scripts/ci/verify-resilience-wiring.sh` / `scripts/ci/check-no-suppressions.sh` — re-run gates for E

---

*No code changes. Baseline captured read-only from `perf/hot-paths-latency-wins` at `facaa4e189`. Prepared for Subagent E re-run.*
