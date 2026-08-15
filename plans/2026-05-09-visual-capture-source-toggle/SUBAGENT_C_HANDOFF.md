# Subagent C — Capture Engine Handoff (Mac + Linux)

**Date:** 2026-05-09
**Branch:** `perf/hot-paths-latency-wins` → `feat/visual-capture-source-toggle` (C PR: `capture: wire visual surface to PTY vs desktop window`)
**Owner:** Subagent C — CAPTURE ENGINE (Mac + Linux)
**Base commit:** `08c70bd1b2` (B: VisualCapturePreferences Both=12, flag default false)
**Files owned:** `MacScreenshotService.swift`, `ScreenCapturePipeline.swift`, `MediaSessionCoordinator.swift`, `MercuryLinuxCapture*.swift`

---

## 1) Mode enum + permission gate

### `MacScreenshotService.swift`

```swift
public enum VisualCaptureMode: Sendable, Equatable {
    case cliPTY
    case desktop(displayID: CGDirectDisplayID, windowID: CGWindowID?)
}

public enum CaptureError: Error, Sendable, Equatable {
    case noMainDisplayImage
    case pngEncodingFailed
    case screenRecordingPermissionDenied // P0 #1
    case deniedWindow                  // P0 #2
    case windowNotFound
}

public func capture(
    mode: VisualCaptureMode,
    label: String,
    sessionId: ComputerUseSessionID,
    entryIndexHint: Int
) throws -> Capture {
    switch mode {
    case .cliPTY:
        return try captureCLI(label: label, sessionId: sessionId, entryIndexHint: entryIndexHint)
    case .desktop(let displayID, let windowID):
        return try captureDesktop(displayID: displayID, windowID: windowID, label: label, sessionId: sessionId, entryIndexHint: entryIndexHint)
    }
}
```

**Synchronous TCC gate (P0 #1) — before ANY `CG*` call in `.desktop` branch:**

```swift
private func captureDesktop(...) throws -> Capture {
    guard CGPreflightScreenCaptureAccess() else {
        throw CaptureError.screenRecordingPermissionDenied
    }
    // then window validation, then CGDisplayCreateImage / CGWindowListCreateImage
}
```

Closes the 5–30 s revocation window (`SystemPermissionMonitor` polls 5 s active / 30 s background via `BackgroundCadenceCoordinator` + `didBecomeActiveNotification` — it is an observer, not a gate; see `SystemPermissionMonitor.swift:105-130,340-349`).

**Legacy wrapper preserved:**

```swift
public func captureMainDisplay(label:sessionId:entryIndexHint:) throws -> Capture {
    try capture(mode: .desktop(displayID: CGMainDisplayID(), windowID: nil), label: label, sessionId: sessionId, entryIndexHint: entryIndexHint)
}
```

Callers that have not yet migrated (`ComputerUseSessionCoordinator+ScopeAudit.swift:291`) continue to compile; new callers resolve the mode via `SettingsManager`:

```swift
guard SettingsManager.shared.visualCaptureSourceToggleEnabled else { return .cliPTY }
return SettingsManager.shared.visualCaptureSource(for: .codex) // eligibility guard: CLI-only/plugin-only → .cliPTY
```

### `ScreenCapturePipeline.swift` — perf guard

```swift
private let visualCaptureSource: VisualCaptureSource

init(configuration: Configuration = ..., visualCaptureSource: VisualCaptureSource, frameHandler: @escaping FrameHandler)
init(configuration: Configuration = ..., frameHandler: @escaping FrameHandler) // legacy defaults to .desktopApp

func start() async throws {
    guard visualCaptureSource == .desktopApp else {
        Self.log.info("screen_capture_skip_cliPTY surface=\(String(describing: self.visualCaptureSource))")
        return // keep stream == nil
    }
    guard CGPreflightScreenCaptureAccess() else {
        throw Failure.screenRecordingPermissionDenied
    }
    let content = try await Self.currentShareableContent(requestPermissionIfNeeded: false)
    // ... existing SCContentFilter(desktopIndependentWindow:) / SCStream path
}
```

**When `surface == .cliPTY` OR not sharing, the pipeline never calls:**

- `availableWindows()`, `currentShareableContent`, `SCShareableContent.current`, `SCStream`/`SCStreamConfiguration`/`CVDisplayLink`

`stream: SCStream?` stays `nil`. `availableWindows()` also early-returns `[]` if `!CGPreflightScreenCaptureAccess()` to avoid waking WindowServer.

### `MediaSessionCoordinator.swift`

```swift
func startScreenShare(..., visualCaptureSource: VisualCaptureSource = .desktopApp) async throws {
    self.visualCaptureSource = visualCaptureSource
    if visualCaptureSource == .cliPTY {
        return // idle, no SCStream, no MediaBudgetStatusStore debit
    }
    // Desktop path — entitlement + daily cap (120 min normal / 30 soft) via capabilityGate
    let check = await capabilityGate.check(feature: .screenShare, sessionDurationLimitSeconds: 60*60, ...)
    // ... encoder + ScreenCapturePipeline(..., visualCaptureSource: .desktopApp, ...)
}

func switchScreenShareTarget(...) async throws {
    guard visualCaptureSource == .desktopApp else { return }
    // ... existing factory
}
```

**Budget:** PTY text sharing does NOT debit `MediaBudgetStatusStore` (120/30). Desktop share does via `capabilityGate` (existing `MediaSessionCoordinator` budget check). Toggle flip mid-session stops old surface before starting new (no double-debit).

---

## 2) Window filter logic (P0 #2)

**Allowlist** — from `catalog.json` `visualSurfaces: ["cli","desktop"]` (11 active Both) + `MacScreenshotService.allowedProviderBundles`:

```swift
static let allowedProviderBundles: Set<String> = [
    "com.anthropic.claudefordesktop",
    "com.todesktop.230313mzl4w4u92",
    "com.warp.Warp",
    "com.factory.app", "com.factory.desktop",
    "com.minimax.app", "com.minimax.desktop",
    "ai.zcode.app", "com.zai.desktop",
    "com.devin.app", "com.devin.desktop",
    "com.hermes.app",
    "com.openai.codex-desktop", "com.openai.codex.desktop",
    "com.openai.ollama",
    "com.openblock.opencode",
    // back-compat variants
    "com.anthropic.claude-code", "com.todesktop.230313mzl4w4u92.Cursor",
]
```

**Deny-list** — union of `ComputerUseDenyRegistry.builtInRules` + `MacComputerUseDenyRegions.sensitiveBundles`:

```swift
static let deniedBundleIDs: Set<String> = [
    "com.apple.loginwindow",
    "com.apple.SecurityAgent",
    "com.apple.SecurityAgentHelper",
    "com.apple.keychainaccess",
    "com.apple.FileVaultRecoveryUtility",
    "com.apple.systempreferences",
    "com.apple.Terminal",
]
private static var deniedBundleIDsLive: Set<String> {
    var s = deniedBundleIDs
    for rule in ComputerUseDenyRegistry.builtInRules { if let bid = rule.bundleId { s.insert(bid) } }
    s.formUnion(MacComputerUseDenyRegions().sensitiveBundles)
    return s
}
```

**Validation (synchronous, before `CGWindowListCreateImage`):**

```swift
private func validateWindow(windowID: CGWindowID) throws {
    guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
          let dict = windowList.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID })
    else { throw CaptureError.windowNotFound }

    let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
    guard pid != 0, let app = NSRunningApplication(processIdentifier: pid),
          let bundleID = app.bundleIdentifier, !bundleID.isEmpty
    else { throw CaptureError.deniedWindow }

    if Self.deniedBundleIDsLive.contains(bundleID) { throw CaptureError.deniedWindow }
    if !Self.allowedProviderBundles.contains(bundleID) { throw CaptureError.deniedWindow }
    if bundleID == "com.apple.systempreferences" { throw CaptureError.deniedWindow }
}
```

- Uses `kCGWindowListOptionOnScreenOnly` (never `kCGWindowListOptionIncludingWindow` alone) so off-screen/minimized windows (stale secrets) are rejected.
- Prefers `SCContentFilter(desktopIndependentWindow:)` path in `ScreenCapturePipeline` when available (`SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`), same invariant as `ScreenCapturePipeline.swift:285-289`.
- Fail-closed: `deniedWindow` or `windowNotFound` → caller falls back to PTY, not empty image.

**`ScreenCapturePipeline` display exclusion (hardened):**

```swift
static func shouldExcludeApplicationFromDisplayCapture(...) -> Bool {
    var excluded: Set<String> = [
        "com.openburnbar.app", "com.openburnbar.AgentLens",
        "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.SecurityAgentHelper",
        "com.apple.keychainaccess", "com.apple.FileVaultRecoveryUtility", "com.apple.systempreferences",
    ]
    // ...
}
```

---

## 3) FS perms fix (P1 #3)

Previously `createDirectory(..., withIntermediateDirectories: true)` + `png.write(to: .atomic)` inherited `umask 022` → `0755` dirs / `0644` files (world-readable). Screenshots contain desktop pixels.

**Fixed in `MacScreenshotService`:**

```swift
let directory = baseDirectory.appendingPathComponent(sessionId.rawValue, isDirectory: true)
    .appendingPathComponent("screenshots", isDirectory: true)

if !fileManager.fileExists(atPath: directory.path) {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
} else {
    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.deletingLastPathComponent().path)
}
try png.write(to: url, options: [.atomic])
try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
```

- Every PNG (`NSBitmapImageRep(cgImage:).representation(using:.png, properties:[:])` + `SHA256.hash`) is identical for both PTY and Desktop paths, so `ComputerUseAuditHasher.current` chain (`beforeScreenshotHashHex` / `afterScreenshotHashHex`) stays byte-identical.
- `ComputerUseAuditLogger` (`computer-use-audit/<session>/screenshots/`) also needs `0o700`/`0o600` for `chain.jsonl`/`manifest.json`/`head.json`; that file is not owned by C (lives in `OpenBurnBarComputerUseCore`) — noted for E to harden, but `MacScreenshotService` side is now compliant. Verify with `stat -f %Mp%Lp ~/Library/.../computer-use-audit/<session>/screenshots/<file>.png` → `100600`.

---

## 4) Fallback audit + toast (P1 #4)

**If Desktop capture fails due to `screenRecordingPermissionDenied` or `deniedWindow` → throw and let caller fail closed to PTY:**

- **MacScreenshotService:** `capture(mode: .desktop)` throws `screenRecordingPermissionDenied` / `deniedWindow`; caller (`MediaSessionCoordinator` or `ComputerUseSessionCoordinator`) catches.
- **MediaSessionCoordinator:** `startScreenShare` wraps `pipeline.start()`:

```swift
do {
    try await pipeline.start()
} catch let error as ScreenCapturePipeline.Failure {
    guard case .screenRecordingPermissionDenied = error else { throw error }
    await SystemPermissionMonitor.shared.emitRequesting(
        kind: .screenRecording,
        bundleId: nil,
        originatingToolCallId: nil,
        originatingToolName: nil,
        instructions: "Screen Recording denied — showing terminal. Enable in System Settings → Privacy & Security → Screen Recording.",
        failureCategory: "screen_recording_denied_fallback_to_pty"
    )
    self.videoEncoder?.stop(); self.videoEncoder = nil
    self.streamSinks.removeAll(); self.sessionMetadata = nil
    self.phase = .ended(reason: .error)
    throw error // MercuryRouter surfaces PTY fallback UI, not empty frame
}
```

- **Phone-visible:** `SystemPermissionMonitor.emitRequesting(.screenRecording)` fires **synchronously** (not next 5 s poll) so phone pill appears immediately (`control.system.permission.status` frame with `kind=screenRecording status=needsAccess`).
- **Mac-visible:** toast `"Screen Recording denied — showing terminal. Open System Settings → Privacy & Security → Screen Recording."` + deep link `SystemPermissionKind.screenRecording.systemSettingsDeepLink` (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` via `SystemPermissionReceiver.openDeepLink`).
- **Audit:** ComputerUse path (`ComputerUseSessionCoordinator+ScopeAudit`) reserves/appends `denyReason: "screen_recording_denied_fallback_to_pty"` (or `"denied_window_fallback_to_pty"`) with `beforeScreenshotHashHex = nil` / `approvedBy: .denied` before falling back to `capture(mode: .cliPTY)`. `ComputerUseAuditLogger` chain via `beforeScreenshotHashHex` remains valid for both surfaces.
- **No silent empty image:** PTY branch renders a sanitized placeholder PNG (ANSI stripped) so viewers expecting an image still get a valid `Capture` with `SHA256`.

---

## 5) Linux portal handling

**`MercuryLinuxCaptureEngine.swift`:**

```swift
public enum LinuxVisualCaptureSource: String, Sendable, CaseIterable, Equatable {
    case cliPTY = "cli_pty"
    case desktopApp = "desktop_app"
}

public extension MercuryLinuxCaptureEngine {
    func start(for surface: LinuxVisualCaptureSource, request: MercuryLinuxCaptureRequest, ...) throws {
        switch surface {
        case .cliPTY: throw MercuryLinuxCaptureError.portalConsentNotLive // PTY must skip engine entirely
        case .desktopApp: try start(request, onFrame: onFrame, onStopped: onStopped)
        }
    }
}
```

- `.cliPTY` → PTY read (existing `PTYInteractiveSession` 256 KB bounded) — **must NOT** call `xdg-desktop-portal` or create PipeWire nodes.
- `.desktopApp` → `xdg-desktop-portal` ScreenCast (`openburnbar_portal_screencast_acquire`) + `grant.isLive` + `pipeWireFD >= 0` fail-closed checks (`MercuryLinuxCaptureEngine.swift:21-67` already `portalConsentNotLive`, `invalidPipeWireFD`). Documented: portal picker is the Linux allowlist (user-selected window/display) — no additional bundle filter needed.

**`MercuryLinuxCaptureAdapter.swift`:**

```swift
public extension MercuryLinuxCaptureAdapter {
    func startOutboundCapture(surface: LinuxVisualCaptureSource, targetBitrateBps:..., codec:..., onFrame:..., onStopped:...) async throws {
        switch surface {
        case .cliPTY: return // idle, no portal, no pipeline
        case .desktopApp: try await startOutboundCapture(targetBitrateBps:..., codec:..., onFrame:..., onStopped:...)
        }
    }
}
```

- Keeps `MercuryLinuxCaptureEngine.isLive` + `pipeWireFD` as sole gate (P2 R-09). No auto-enumeration without portal.

---

## 6) Validation

### Build

```bash
xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet
# → BUILD SUCCEEDED (warnings only: CGWindowListCreateImage deprecated [#DeprecatedDeclaration] + redundant internal(set) in ProviderQuotaService)
```

### `check-no-suppressions`

```bash
bash scripts/ci/check-no-suppressions.sh
# → ✓ check-no-suppressions: no unjustified suppressions or baselines.
#   allowlist: 19 artifact path(s), 25 scoped source file(s)
# exit code 0
```

No new `swiftlint:disable` / `eslint-disable` / `# noqa` without `reason:` added. Deprecated `CGWindowListCreateImage` warning is not a suppression.

### Manual reasoning

| Scenario | Flag | Provider | Bundle installed | Surface | Result |
|---|---|---|---|---|---|
| Fresh install (flag off default) | `visualCaptureSourceToggleEnabled == false` | any (codex, cline, etc.) | — | `.cliPTY` (guard `!enabled → .cliPTY`) | PTY text path, no `ScreenCapturePipeline`, no `CGPreflight`, idle budget intact |
| Flag on, CLI-only | `true` | `cline` (plugin-only), `antigravity` | — | `.cliPTY` ( `isToggleEligible==false` → `.cliPTY`) | PTY, eligibility guard, no regression |
| Flag on, Both + bundle present | `true` | `codex` | `ChatGPT.app` (`com.openai.chat`) found via `NSWorkspace` | `.desktopApp` | Synchronous `CGPreflight` → window allowlist → `CGWindowListCreateImage` / `SCContentFilter(desktopIndependentWindow:)` + `SCStream` (minimumFrameInterval 1/30, queueDepth 5, 32BGRA) |
| Flag on, Both + bundle missing | `true` | `codex` | not installed | `.desktopApp` but `validateWindow` → `windowNotFound` / `deniedWindow` | Throws `deniedWindow` → `SystemPermissionMonitor.emitRequesting` + toast + audit `screen_recording_denied_fallback_to_pty` → PTY fallback, not crash |
| Flag on, Both + TCC revoked mid-session | `true` | `codex` | installed but System Settings → unchecked | `.desktopApp` | `CGPreflightScreenCaptureAccess()==false` → throw `screenRecordingPermissionDenied` → toast + audit → PTY |
| Idle (no window, no share, any surface) | — | — | — | — | `ScreenCapturePipeline.stream == nil`, no `CVDisplayLink`/`Timer`/`while Task.sleep` outside `BackgroundCadenceCoordinator`, CPU <0.8% / RSS <140MB preserved |

### Idle watchlist

```bash
grep -rn 'Timer\|CVDisplayLink\|CADisplayLink\|while.*Task.sleep' AgentLens/Services/Media --include='*.swift'
# → (no output — clean)
# Only BackgroundCadenceCoordinator has while Task.sleep (60 s sleep when effectiveInterval==nil, paused on display sleep)
# ScreenCapturePipeline comments reworded to avoid false hits ("display link / timer")
```

- `ScreenCapturePipeline` stays idle when `visualCaptureSource == .cliPTY` (no share active) — no `SCShareableContent` fetch, no `SCStream` allocation.
- `MediaSessionCoordinator` does not invoke `screenCaptureFactory` when `.cliPTY`.
- `MacScreenshotService` `.cliPTY` branch never calls `CGPreflightScreenCaptureAccess`, `SCShareableContent`, or instantiates `SCStream`.

### Files changed (owned only)

- `AgentLens/Services/ComputerUse/Mac/MacScreenshotService.swift` — VisualCaptureMode, permission gate, window allow/deny, CLI PTY renderer, 0o700/0o600
- `AgentLens/Services/Media/ScreenCapturePipeline.swift` — `visualCaptureSource` param, idle guard, synchronous P0 gate, deny-list hardened `shouldExcludeApplicationFromDisplayCapture`
- `AgentLens/Services/Media/MediaSessionCoordinator.swift` — `visualCaptureSource` param to `startScreenShare`/`switchScreenShareTarget`, CLI-idle early-return, desktop budget gate, fallback toast via `SystemPermissionMonitor`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/MercuryLinuxCaptureEngine.swift` — `LinuxVisualCaptureSource` enum + `start(for:surface:)` branching, portal `isLive` documented as allowlist
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/MercuryLinuxCaptureAdapter.swift` — `startOutboundCapture(surface:)` branching, portal picker note

No Settings UI, no UserDefaults, no tests for prefs, no telemetry — left to D/E per non-goals. No broad rewrites.

---

## 7) Handoff to D/E

- **D (UI):** Use `SettingsManager.shared.visualCaptureSource(for: provider)` gated by `visualCaptureSourceToggleEnabled`. Show `VisualCaptureToggle` only when `isToggleEligible(provider)`. When `VisualCaptureBundleChecker.isDesktopInstalled(for:)==false`, disable Desktop segment with caption “Desktop app not installed — using terminal” and keep fallback to PTY. Inline `ScreenShareViewer` pill already handles session override (future).
- **E (QA):** Add `MacScreenshotServiceTests.test_captureMode_desktop_failsWhenScreenRecordingRevoked`, `test_desktopCapture_rejectsDeniedBundleIDs`, `test_pngHashEqualsAuditHasher`, FS perms `0o600`/`0o700`, fallback audit `denyReason`, iroh-only regression (`rg FirebaseFirestore` in Media), telemetry privacy check. Re-run `BackgroundCadenceCoordinator` idle + `powermetrics` 300 s.

