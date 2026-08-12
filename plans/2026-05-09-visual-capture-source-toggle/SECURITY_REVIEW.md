# Visual Capture Source Toggle — Security & Privacy Review
**Reviewer:** Subagent — Security & Privacy (read-only)
**Date:** 2026-05-09 (audit of plan at `perf/hot-paths-latency-wins:plans/2026-05-09-visual-capture-source-toggle/README.md`)
**Branch audited:** `perf/hot-paths-latency-wins` (commit `facaa4e189`)
**Plan commit:** plan READ-ONLY; no code edited
**Files inspected:** `MacScreenshotService.swift`, `ScreenCapturePipeline.swift`, `SystemPermissionMonitor.swift`, `SystemPermissionReceiver.swift`, `MercuryRouter.swift`, `MercuryLinuxCaptureEngine.swift`, `MercuryLinuxCaptureAdapter.swift`, `ComputerUseSessionCoordinator.swift`, `ComputerUseAuditLogger.swift`, `ComputerUseAuditChain.swift`, `ComputerUseDenyRegistry.swift`, `MacComputerUseDenyRegions.swift`, `MediaSessionCoordinator.swift`, `MacMediaCapabilityGate.swift`, `OpenBurnBarIdentity.swift`, `docs/security/BurnBar-threat-model.md`

---

## Executive Summary — HOLD (conditional)

**Verdict: HOLD — fix 2× P0 + 3× P1 before Subagent C merges.**

The plan is architecturally sound (re-uses existing `CGDisplayCreateImage` / `ScreenCaptureKit` / `MercuryRouter` iroh / audit-SHA256 paths) and its claimed privacy properties are largely defensible. **It may NOT ship as written** because:

1. **Permission re-check is underspecified (P0).** The plan says “re-checked via `SystemPermissionMonitor` before every Desktop capture.” `SystemPermissionMonitor` is a *polling observer* (5 s active / 30 s background via `BackgroundCadenceCoordinator` + `didBecomeActiveNotification`), not a synchronous gate. Neither `MacScreenshotService.captureMainDisplay` nor the proposed `capture(mode:)` currently calls `CGPreflightScreenCaptureAccess()` synchronously on each capture. TCC can be revoked mid-session via System Settings; a toggle-time check or next poll (up to 30 s) leaves a window where Desktop pixels are captured without permission.
2. **Desktop capture exfiltration surface is unbounded (P0).** Full-display `CGDisplayCreateImage` without window-level filtering and without `SecurityAgent`/`LoginWindow` deny-list captures other apps, password dialogs, and Keychain windows. `ScreenCapturePipeline.shouldExcludeApplicationFromDisplayCapture` today only excludes `com.openburnbar.app` / `com.openburnbar.AgentLens` (`ScreenCapturePipeline.swift:253-268`), not `com.apple.SecurityAgent`, `com.apple.loginwindow`, `com.apple.SecurityAgentHelper`, `com.apple.keychainaccess`, `com.apple.FileVaultRecoveryUtility` that already live in `ComputerUseDenyRegistry.swift:9-33` / `MacComputerUseDenyRegions.swift:22-29`.

Both are fixable in one small diff each (synchronous `CGPreflightScreenCaptureAccess()` + `SCShareableContent.onScreenWindowsOnly + windowID allowlist + deny-list`). The audit-chain / iroh / fallback items are P1/P2 and do not block if the two P0s are addressed. **After fixes, recommendation flips to SHIP.**

---

## 1. Permission Gates — What Must Be Checked (Desktop capture)

| Gate | macOS API | Current code | Plan claim | Gap |
|------|-----------|--------------|------------|-----|
| **Screen Recording** (TCC) | `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()` / `SCShareableContent.excludingDesktopWindows(onScreenWindowsOnly:true)` | `ScreenCapturePipeline.currentShareableContent(requestPermissionIfNeeded:)` checks `CGPreflightScreenCaptureAccess()` synchronously and throws `Failure.screenRecordingPermissionDenied` (`ScreenCapturePipeline.swift:273-284`). `MacScreenshotService.captureMainDisplay` calls `CGDisplayCreateImage` directly **with no pre-flight check** (`MacScreenshotService.swift:48-52`). `SystemPermissionMonitor.readScreenRecordingStatus()` polls via same `CGPreflight…` but only on cadence (`SystemPermissionMonitor.swift:340-345`, `refreshAll` → `checkBucket(kind:.screenRecording)`). | Plan § Subagent C “Desktop capture requires Screen Recording permission (`SystemPermissionMonitor` already gates)” and § E “Screen Recording permission re-checked via `SystemPermissionMonitor` before every Desktop capture.” | **Plan overstates `SystemPermissionMonitor`.** Monitor is observer, not gate. `MacScreenshotService` has zero permission logic. **Fix:** `capture(mode:)` must call `CGPreflightScreenCaptureAccess()` *synchronously* before every `CGDisplayCreateImage` / `CGWindowListCreateImage` / `SCStream.startCapture`, not rely on `Monitor.snapshots[.screenRecording]`. See checklist C-1. |
| **Accessibility (AX)** | `AXIsProcessTrusted()` | `SystemPermissionMonitor.readAccessibilityStatus()` polls `AXIsProcessTrusted()` (`SystemPermissionMonitor.swift:346-349`). `MacAccessibilityPermissionRequester` + `MacInputController` gate actual input. | Plan does not list Accessibility for Desktop *capture* (correct — capture needs only Screen Recording). | No gap for capture. If Subagent C later drives pointer/keystrokes from Desktop surface, Accessibility becomes a *separate* pre-condition for input, not capture. Document separately so reviewers do not conflate the two (see checklist C-2). |
| **Automation** (per-bundle A11y automation) | `AEDeterminePermissionToAutomateTarget(bundleID)` | `SystemPermissionMonitor.trackAutomation(bundleId:)` + `SystemPermissionReceiver.runPrompt(kind:.automation)` (`SystemPermissionReceiver.swift:178-188`, `Monitor.trackAutomation`). | Not needed for Desktop capture. | None — but recommend Subagent C not add an `automation` bundle check for window capture; it is prompt-only, not a capture gate. |
| **PipeWire portal (Linux)** | `xdg-desktop-portal ScreenCast` | `MercuryLinuxCaptureEngine.request.source = .portal(MercuryLinuxScreenCastGrant)` with `grant.isLive` check (`MercuryLinuxCaptureEngine.swift:21-24, 65-67, 220-225`) + `MercuryLinuxCaptureAdapter.openburnbar_portal_screencast_acquire` (`MercuryLinuxCaptureAdapter.swift:48-66`). | Plan § Subagent C: “Linux … PipeWire `xdg-desktop-portal` `ScreenCast` (already proven…)” | Correct. Portal consent is already fail-closed (`portalConsentNotLive`, `invalidPipeWireFD`). Recommend mirroring macOS deny-list on Linux (`com.apple.*` → portal’s own Safety? Linux has no equivalent, but document that portal picker already limits to user-selected window, which is the Linux allowlist — see Task 2). |

**Required invariant for Subagent C (to write into PR description):**

```swift
// Pseudocode — must be in capture(mode:) before ANY CG* call
guard CGPreflightScreenCaptureAccess() else {
    // fail closed, do NOT fall through to CGDisplayCreateImage which would return nil or stale
    throw CaptureError.screenRecordingPermissionDenied // or map to existing Failure.screenRecordingPermissionDenied
}
// Then branch:
switch mode {
case .desktop: // window/display
    guard allowedBundleIDs.contains(window.owningApplication.bundleIdentifier),
          !deniedBundleIDs.contains(window.owningApplication.bundleIdentifier) else {
        throw CaptureError.deniedWindow
    }
    // then CGWindowListCreateImage / SCContentFilter(desktopIndependentWindow:)
case .cliPTY:
    // no Screen Recording check needed; PTY path is text-only
}
```

**Why “once at toggle set” is wrong:** TCC can be revoked at any time via System Settings → Privacy & Security → Screen Recording (user unchecks OpenBurnBar). If C checks only when the user flips Settings > Providers > Visual Surface, then revocation mid-session is missed until the next `SystemPermissionMonitor` tick (5 s foreground, 30 s background via `BackgroundCadenceCoordinator.register(id:"system-permission-monitor", activeInterval:5, backgroundInterval:30)` — `SystemPermissionMonitor.swift:105-130`) or until `didBecomeActiveNotification`. That 5-30 s window is enough to exfiltrate a screen. Per-capture synchronous check closes it.

**Also required:** `SystemPermissionMonitor` should *remain* as the observer that drives the phone pill / retry dispatcher (`SystemPermissionMonitor.emitRequesting`, `SystemPermissionRetryDispatcher`), but it is not the gate.

---

## 2. New Data Exfiltration Surface — Desktop Window vs PTY

### PTY baseline (safe)
- Bounded to one PTY’s stdout/stderr (`PTYInteractiveSession` / `CLIProcessStreamRunner` + `BufferedLineSequence` 256 KB, line-by-line — `Plan §0`).
- Text-only; no other app pixels; ANSI escapes sanitized (plan notes “must sanitize ANSI escapes before PNG render” — not yet implemented but low-risk for exfiltration vs pixels).

### Desktop capture delta (what the plan adds)

| Surface | What is captured | Privacy impact | Plan coverage |
|---------|------------------|----------------|---------------|
| **`CGDisplayCreateImage(CGMainDisplayID())` unfiltered** | Entire display: dock, menu bar, notifications, other app windows, browser tabs, password-reveal eye, 1Password overlay | **High.** Incidental capture of secrets outside provider window. Violates least-privilege. | Plan § C says “`CGDisplayCreateImage(displayId)` or `CGWindowListCreateImage(windowID)` filtered to the provider’s bundle via `NSWorkspace + CGWindowListCopyWindowInfo`” — filtering is described, but not mandated to be *exclusive* (allowlist) and not tied to a deny-list. Risk P0 if inner branch defaults to display path when `windowID == nil`. |
| **`CGWindowListCreateImage(windowID)` without flags** | May capture offscreen/minimized windows (stale sensitive data) if flags wrong | Medium | Plan mentions `CGWindowListCopyWindowInfo` but not `CGWindowListOption` flags. Needs `kCGWindowListOptionOnScreenOnly \| kCGWindowListOptionIncludingWindow` (`CGWindowListOptionOnScreenOnly | kCGWindowListOptionIncludingWindow`) to limit to composited on-screen pixels. Existing `ScreenCapturePipeline.currentShareableContent` already uses `excludingDesktopWindows(false, onScreenWindowsOnly: true)` (`ScreenCapturePipeline.swift:285-289`) — same invariant must apply to CG path. |
| **ScreenCaptureKit display filter** | Today `ScreenCapturePipeline.start()` does `SCContentFilter(display:excludingApplications:exceptingWindows:)` with `shouldExcludeApplicationFromDisplayCapture` only excluding own bundle (`ScreenCapturePipeline.swift:253-268`). No SecurityAgent/LoginWindow exclusion. | Medium | Gap. Display capture path shares same exclusion; must be hardened (see below). |
| **Window chrome / secure text field pixels** | Even within provider window, a password field rendered as `••••••••` is still a signal that a secret is on screen; window title may leak secret (`"my password is …"`). | Low-Medium | Already mitigated for *input* via `MacComputerUseDenyRegions.isSecureTextField` (`AXSecureTextField` + `AXDialog`/`authKeywords`) (`MacComputerUseDenyRegions.swift:42-62`) and `ComputerUseDenyRegistry.builtin.securityagent / loginwindow / keychainaccess` (`ComputerUseDenyRegistry.swift:9-33`). Must be extended to *capture* — i.e., refuse to capture a window whose AX focused element is a secure text field or whose bundle is sensitive. |
| **Linux PipeWire portal** | User picks window/display in portal picker | Lower risk — picker itself is the consent + allowlist. | Adequate if `MercuryLinuxScreenCastGrant.isLive` is re-validated each frame (already done). No extra bundle filtering needed. |

### Recommended windowing filter (normative for Subagent C)

```swift
// Allowlist — from plan §1 audit-corrected Both set (11 active)
let allowedProviderBundles: Set<String> = [
    "com.anthropic.claudefordesktop",           // Claude Desktop — verify on MBA, else probe /Applications/Claude.app (Plan Q2)
    "com.todesktop.230313mzl4w4u92",             // Cursor — plan §1
    "com.warp.Warp",                            // Warp — plan §1
    "com.factory.desktop",                      // placeholder — confirm actual Factory Desktop bundle
    "com.minimax.desktop",                      // placeholder — confirm actual MiniMax bundle
    "com.zai.desktop",                          // ZCode — confirm
    "com.devin.desktop",                        // Devin Desktop (successor to Windsurf — devin.ai/blog/windsurf-is-now-devin-desktop)
    "com.openai.codex.desktop",                 // Codex Desktop / ChatGPT Desktop
    // Hermes/Ollama/OpenCode: TUI windows have no bundle — treat as CLI-only unless AX bundle resolves
]

// Deny-list — from ComputerUseDenyRegistry + MacComputerUseDenyRegions (never capture, even if allowlisted)
let deniedBundleIDs: Set<String> = [
    "com.apple.loginwindow",
    "com.apple.SecurityAgent",
    "com.apple.SecurityAgentHelper",
    "com.apple.keychainaccess",
    "com.apple.FileVaultRecoveryUtility",
    "com.apple.systempreferences", // when windowTitleRegex "Privacy.*Security" — see ComputerUseDenyRegistry builtin.privacy_pane
]

// Hard filter before any CG* call:
guard let bundleID = window.owningApplication.bundleIdentifier,
      allowedProviderBundles.contains(bundleID),
      !deniedBundleIDs.contains(bundleID),
      !MacComputerUseDenyRegions().isSensitiveBundle(bundleID) else {
    throw CaptureError.deniedWindow // fail closed → fallback to PTY
}
// CG flags:
let image = CGWindowListCreateImage(
    .null, // screenBounds of window? prefer window rect
    .optionOnScreenOnly, // kCGWindowListOptionOnScreenOnly
    windowID,
    [.boundsIgnoreFraming, .nominalResolution] // or .bestResolution
)
// Prefer ScreenCaptureKit path when available: SCContentFilter(desktopIndependentWindow: window) where
// window comes from SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).
```

Additional non-code controls:
- **User consent per session:** Toggle is global + per-provider (`VisualCapturePreferences` — Plan § B). Desktop capture should require an explicit per-session “Share Desktop” confirmation (reuse `MercuryRouter` ringing/consent sheet — `MercuryRouter.Phase.ringing` already gates screen-share). Do not auto-capture on toggle flip alone.
- **Visual indicator:** When Desktop surface is active, Mac must show a persistent indicator (menu bar icon / `ScreenCapturePipeline` is Streaming phase, or macOS’s own orange Screen Recording dot — which System Settings already provides). Plan does not mention this; recommend documenting it so users know they are sharing pixels.
- **Leak notice in docs:** `docs/PROVIDERS.md` and Settings help tooltip must state that Desktop surface shares *pixels* (screenshots + video frames) over iroh to the paired phone, and may incidentally include desktop background/other windows if the provider is windowed. User must position the provider window to be occlusive or use window-only capture.

---

## 3. Audit Chain & PNG Write Location

### Hash continuity — PASS (with one implementation contract)

- Chain primitive: `ComputerUseAuditHasher.current` is SHA-256, canonical-JSON (`sortedKeys`, `withoutEscapingSlashes`, Date → ms int) (`ComputerUseAuditChain.swift:117-160`), `genesisParentHashHex = "0"*64` (`ComputerUseAuditChain.swift:137`). No BLAKE3 in production (plan correctly notes “SHA-256 today, BLAKE3-swappable” — accurate).
- `MacScreenshotService.Capture.sha256Hex = SHA256.hash(data: png).map { String(format:"%02x",$0) }.joined()` (`MacScreenshotService.swift:61-64`) equals `PlatformCrypto.sha256Hex(data)` used by `ComputerUseAuditHasher.hash(data:)` (`ComputerUseAuditChain.swift:132-136` via `PlatformCrypto`). Byte-identical digest.
- Chain entry stores `beforeScreenshotHashHex` / `afterScreenshotHashHex` as the `Capture.sha256Hex` (`ComputerUseAuditLogger.makeEntry(... beforeScreenshotHashHex:beforeCapture?.sha256Hex ...)` — `ComputerUseAuditLogger.swift:158-198` and `ComputerUseSessionCoordinator+Approvals.swift:387, 431, 456, 505, 558, 591, 624` all thread the same field).
- **Contract for Subagent C:** The new PTY PNG render (`NSTextView` snapshot) and the Desktop PNG (`CGDisplayCreateImage` / `CGWindowListCreateImage` → `NSBitmapImageRep` → PNG) **must both** go through `MacScreenshotService` (or a shared helper that produces identical `sha256Hex` + chain plumbing). Do not hash PTY PNG with a different encoder (JPEG, different PNG properties `[:]`) or store it outside the chain. If PTY path ever emits text frames without PNG, the chain must still record a consistent `beforeScreenshotHashHex = nil` vs `sha256Hex` — document which surfaces are PNG-audited.
- Validation is hash-agnostic: `ComputerUseAuditChain.validate(... hasher: .current ...)` re-derives (`ComputerUseAuditChain.swift:189-280`), plus `head.json` tamper detection (`ComputerUseAuditLogger.writeHeadMarker` + `ComputerUseAuditChain.validate(... expectedHeadHashHex ...)`).

**Result:** No new hash divergence if Subagent C follows the existing `MacScreenshotService` path. Recommend adding a unit test `MacScreenshotServiceTests.test_desktopPNG_hashEqualsHasher` (new in Subagent E) asserting `Capture.sha256Hex == ComputerUseAuditHasher.current.hash(data: pngData)`.

### Write location — PLAN PATH IS STALE (P1 doc fix)

- **Plan claims:** `~/Library/Application Support/OpenBurnBar/computer-use/<session>/screenshots/` (`Plan §2 Subagent C Validation`, `Plan § C Scope`).
- **Actual code:** `~/Library/Application Support/OpenBurnBar/computer-use-audit/<session>/screenshots/`  
  Evidence: `ComputerUseRuntimeController.makeCoordinator` → `supportDirectory.appendingPathComponent("computer-use-audit", isDirectory:true)` (`ComputerUseRuntimeController.swift:413-414`), `OpenBurnBarAppPaths.live().supportDirectory` is `applicationSupportRoot/OpenBurnBar` (`OpenBurnBarIdentity.swift:80-81`), `ComputerUseAuditLogger.directory = baseDirectory / sessionId / screenshots` (`ComputerUseAuditLogger.swift:45-64`, `MacScreenshotService.directory = baseDirectory / sessionId / screenshots` — `MacScreenshotService.swift:51-55`), `ComputerUseService` defaults to `supportDirectoryURL/computer-use-audit` (`ComputerUseService.swift:111, 168`).

**Fix:** Update Plan, `SUBAGENT_C_ENGINE.md`, and any future user docs to `computer-use-audit`. No data loss — actual path is correct, doc is wrong.

### World-readable — P1 (fix in C)

- `ComputerUseAuditLogger.ensureDirectoryExists` calls `fileManager.createDirectory(at:withIntermediateDirectories:true)` **without** `attributes: [.posixPermissions: 0o700]` (`ComputerUseAuditLogger.swift:178-186`). `MacScreenshotService.createDirectory` same (`MacScreenshotService.swift:54`).
- Contrast with hardening elsewhere: `OpenBurnBarChatWorkspaceConfigurator.createDirectory ... setAttributes([.posixPermissions:0o700], ofItemAtPath: directoryURL.path)` (`OpenBurnBarChatWorkspaceConfigurator.swift:24-25`), `OpenBurnBarStartupRecovery.createDirectory ... attributes:[.posixPermissions:0o700]` (`OpenBurnBarStartupRecovery.swift:100-105`), `ComputerUseLocalQuotaLedger.setAttributes([.posixPermissions:0o600/0o700])` (`ComputerUseLocalQuotaLedger.swift:297, 311`), `BurnBarDaemonManager` (`OpenBurnBarDaemonManager+Lifecycle.swift:594-601`).
- By default, `createDirectory` without attributes inherits umask `022` → `0755` dirs / `0644` files, i.e., readable by other local users on a shared Mac. Screenshots contain desktop pixels — sensitive.

**Fix (Subagent C checklist items C-3 / C-4):**
```swift
try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
// after write:
try png.write(to: url, options: [.atomic])
try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
// Also harden ComputerUseAuditLogger chain.jsonl / manifest.json / head.json writes to 0o600
```
Optionally set `FileProtectionType.completeUntilFirstUserAuthentication` via `fileManager.setAttributes([.protectionKey: FileProtectionType.complete],…)` for defense-in-depth (macOS FileProtection is weaker than iOS but harmless). Verify with `ls -l ~/Library/Application\ Support/OpenBurnBar/computer-use-audit/` after fix.

---

## 4. Iroh Peer-to-Peer Claim — VERIFIED (with control-plane caveat)

**Claim in plan:** “Desktop path = … `MercuryRouter`/`MercuryLinuxCaptureEngine` over iroh (already peer-to-peer, not through our servers). No new daemon socket, no new Firestore collection. Reuse `MercuryRouter`/`HermesTransportSelector` iroh peer-to-peer.” (`Plan §0`, `Plan § C`)

**Evidence that screen-share frames use iroh, not Firestore:**

- `HermesTransportSelector` is *only* a relay-selection / Hermes chat routing policy (relay candidate filtering, `relayConnections`, `suggestedRelayConnection` — `OpenBurnBarMobile/Services/Hermes/HermesTransportSelector.swift:70-120`). It does **not** carry media frames — correct that it is not the data plane for Mercury.
- `MediaSessionCoordinator` is documented as `capture pipeline → encoder → packetizer → iroh stream → BWE feedback → teardown` (`MediaSessionCoordinator.swift:10-12`) and `extension ScreenCapturePipeline: ScreenCaptureSession` (`MediaSessionCoordinator.swift:20-24`). Its `streamSinks: [String: MediaStreamSink]` are `MercuryControlStreamMediaSink` (`MacFileTransferService.swift:729-753`) which encodes via `MediaPacketCodec` / `MediaFrameV2Codec` and writes via `MediaFrameAEAD` (OBMFA1) sealed envelopes (`MacFileTransferService.swift:751-832`). Comment: “per-GOP iroh stream the Mac opens against the paired iPhone via the … blob/control endpoint” (`MediaSessionCoordinator.swift:471-474`).
- `MercuryRouter` injection: `MirrorSinkFactory = @MainActor (…) async throws -> MediaStreamSink` “once the per-GOP iroh dial is available. When `nil`, accept emits `unsupported` ack” (`MercuryRouter.swift:124-133`), `ScreenShareStarter` similarly takes `MediaStreamSink` (`MercuryRouter.swift:134-142`). `MercuryRouter.debugTrace` logs `iroh NodeId` for remote peer (`MercuryRouter.swift:73-78`). `MacFileTransferService` comment: “the blob backend, exactly as screen-share/video sessions are admitted” (`MacFileTransferService.swift:432, 511, 617`).
- Firestore in `AgentLens/Services/Media` is **only** for capability/budget/presence, not for pixels: `MacMediaCapabilityGate` reads `MediaBudgetStatusStore.shared` + `MacCloudEntitlementStore` + `MacMediaQuotaUsageStore` (Firestore `ops/media_budget_status`, `hosted_media_sync`, `media_quota_usage`) via `Firestore.firestore().addSnapshotListener` (`MacMediaCapabilityGate.swift:9, 45, 338, 359`; `MediaBudgetStatusStore.swift:45`; `MediaSessionCoordinator` imports `OpenBurnBarIrohRelay` not `FirebaseFirestore`). `rg Firestore AgentLens/Services/Media` hits only `MercuryRouter.swift:276` trust resolver (not media) + `MacMediaCapabilityGate`/`MediaBudgetStatusStore` budget paths.
- Linux: `MercuryLinuxCaptureEngine.MercuryLinuxCaptureRequest.source = portal(MercuryLinuxScreenCastGrant)` with `isLive` + `pipeWireFD` validation (`MercuryLinuxCaptureEngine.swift:21-36, 65-77, 220-234`), then hands to same `MediaSessionCoordinator` → iroh sink. Portal consent is the Linux allowlist; no Firestore frame transport.

**Caveat to document (not a bug):** The *control plane* still touches Firebase: capability checks (`MacMediaCapabilityGate.check` → Firestore), presence (`MercuryRouter` `media.mirror.request` control frames via `HermesRealtimeRelayFrame` control stream), and trust (`FirestorePhoneControlAuthorityProvider`). Firestore sees metadata (timestamps, peerNodeIDs, display sizes, `requestID`s, budget counters) but not frame payloads. User-facing copy (“bytes go peer-to-peer over iroh, not through our servers — `HermesTransportSelector` + `MercuryRouter` blob backend, not Firestore”) is **accurate for media bytes** if this control-plane distinction is added.

**Checklist for Subagent C/E:** Keep `MediaStreamSink` as the *only* sink for `ScreenCapturePipeline.FrameHandler` output; do not add a `Storage`/`Firestore` upload path for frames. Add a regression test asserting `ScreenCapturePipeline.start` does not import `FirebaseFirestore` (mirrors existing `scripts/ci/verify-resilience-wiring.sh` “no raw fetch in functions/src” pattern).

---

## 5. Fallback When Screen Recording Denied — NEEDS HARDENING (P1)

**Plan claim:** “Desktop capture requires Screen Recording permission (`SystemPermissionMonitor` already gates) — if denied, fallback to CLI PTY + toast ‘Screen Recording denied — showing terminal’.” (`Plan § Subagent C Risks` + `Plan § E`)

**Current `MacMediaCapabilityGate` pattern is not a precedent for this:** `MacMediaCapabilityGate.check` returns `.denied(reason:)` (entitlement/budget/killSwitch) and callers surface a banner. That pattern is *async* and Firestore-backed. Permission fallback needs a *synchronous* TCC check plus synchronous UI + audit.

**Is fallback correctly audited and user-visible today? No — plan does not specify either.**

- No `MacScreenshotService` permission error maps to an audit entry today (only `noMainDisplayImage` / `pngEncodingFailed` — `MacScreenshotService.swift:18-21`).
- No toast / pill is wired in `ScreenCapturePipeline.Failure.screenRecordingPermissionDenied` beyond `errorDescription` — callers must explicitly show it. `ScreenCapturePipeline.currentShareableContent(requestPermissionIfNeeded:false)` is intentionally non-prompting at startup (`ScreenCapturePipeline.swift:136-144`: “Do not trigger the native Screen Recording prompt from automatic capture startup…”), so the fallback path must handle the UI.
- `SystemPermissionMonitor` *does* emit `control.system.permission.status` frames (`Monitor.emit` → `HermesRealtimeRelayFrame(type:.controlSystemPermissionStatus)` — `SystemPermissionMonitor.swift:300-340`) which the phone renders as a pill. But that emission only fires when the poll *detects a flip* — a first denial after toggle may not be visible until next poll.

**Recommended fail-closed behavior (normative for Subagent C):**

```swift
// 1. Synchronous gate:
guard CGPreflightScreenCaptureAccess() else {
    // 2. Audit the fallback — do NOT silently switch
    let entry = try auditLogger.makeEntry(
        for: .captureFallback(reason: .screenRecordingDenied), // or a new ComputerUseAction case
        approvedBy: .denied,
        denyReason: "screen_recording_denied_fallback_to_pty",
        beforeScreenshotHashHex: nil
    )
    try auditLogger.append(entry)
    // 3. User-visible on Mac — use existing toast infrastructure (not vscode.window.showError*)
    //    Example: NotificationCenter / Published state that ScreenShareViewer observes:
    //    caller publishes fallbackBanner = "Screen Recording denied — showing terminal. Enable in System Settings → Privacy & Security → Screen Recording."
    // 4. User-visible on phone — emit immediately, do not wait for monitor poll:
    await systemPermissionMonitor.emitRequesting(kind: .screenRecording, status: .needsAccess, ...)
    // or a dedicated HermesRealtimeRelayFrame for capture fallback
    // 5. Then branch to CLI:
    return try await capture(mode: .cliPTY(pid: ..., ptyFD: ...), label: label, sessionId: sessionId, entryIndexHint: entryIndexHint)
}
```

- `MacMediaCapabilityGate` is **not** the right template here (it gates *whether the Mac allows a session at all*). For permission fallback, follow `ScreenCapturePipeline.Failure.screenRecordingPermissionDenied` → `throw` → `catch` in `MediaSessionCoordinator`/`ComputerUseSessionCoordinator` → fallback + audit + toast. Document this mapping in the PR review so reviewers do not look for a `MacMediaCapabilityGate` call that should not exist for this path.
- Accessibility-style: Ensure fallback does not itself require Screen Recording. PTY path must succeed even when Screen Recording is denied (it does — text only).
- Re-request UX: After fallback, UI should offer a “Open System Settings” deep link (`kind.systemSettingsDeepLink` via `SystemPermissionReceiver.openDeepLink(for:.screenRecording)` — `SystemPermissionReceiver.swift:203-208`, which opens `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`). Do not auto-retry without user action — respect TCC.

---

## 6. Table of Risks

| # | Severity | Surface | Description | Impact | Plan reference | Mitigation (assignee) |
|---|----------|---------|-------------|--------|----------------|----------------------|
| **R-01** | **P0** | **Permission re-check** | Desktop capture gates only via `SystemPermissionMonitor` poll (5 s fg / 30 s bg) or toggle-time check, not per-capture `CGPreflightScreenCaptureAccess()`. Race allows capture after revocation. | TCC bypass perception, pixels shared without permission; App Review risk. | Plan § C “SystemPermissionMonitor already gates”, § E “re-checked via SystemPermissionMonitor before every Desktop capture” | **C must add synchronous `CGPreflightScreenCaptureAccess()` inside `capture(mode:)` before every `CGDisplayCreateImage` / `CGWindowListCreateImage` / `SCStream.startCapture`; Monitor remains observer-only. Test: revoke mid-session, assert next capture fails closed. (C)** |
| **R-02** | **P0** | **Window scoping / deny-list** | Unfiltered `CGDisplayCreateImage(CGMainDisplayID())` or `SCContentFilter(display:)` captures entire desktop. Current `ScreenCapturePipeline.shouldExcludeApplicationFromDisplayCapture` excludes only own bundle (`ScreenCapturePipeline.swift:253-268`), not `loginwindow`/`SecurityAgent`/`keychainaccess`/`FileVaultRecoveryUtility`. | Incidental exfil of passwords, emails, other apps; violates least-privilege; expands `desktop_system_input`/`desktop_screenshot` threat-model 5.2 “Compromised local agent” blast radius. | Plan § C “filtered to the provider’s bundle via `NSWorkspace + CGWindowListCopyWindowInfo`” (no allowlist/deny-list norm). | **C must: (a) default to `SCContentFilter(desktopIndependentWindow:)` window capture with `onScreenWindowsOnly:true`; (b) require allowlist `allowedProviderBundles` + deny-list (`ComputerUseDenyRegistry` + `MacComputerUseDenyRegions.sensitiveBundles`); (c) use `kCGWindowListOptionOnScreenOnly|kCGWindowListOptionIncludingWindow`; (d) fail closed to PTY if no matching on-screen window. Doc the filter in PR. (C)** |
| **R-03** | **P1** | **Audit FS permissions** | `ComputerUseAuditLogger.ensureDirectoryExists` + `MacScreenshotService.createDirectory` + `png.write` do not set `0o700`/`0o600`; dirs/files inherit `0755`/`0644` → world-readable on shared Macs. | Other local users can read screenshots / chain / head.json. | Plan § C Validation path `…/computer-use/<session>/screenshots/` (stale; actual `computer-use-audit`). | **C must `createDirectory(… attributes:[.posixPermissions:0o700])` and `setAttributes([.posixPermissions:0o600])` on all audit files; add parity with `ComputerUseLocalQuotaLedger.swift:297,311`. E must assert `ls -l` in test. (C, E)** |
| **R-04** | **P1** | **Fallback audit + UX** | Plan says “fail closed to CLI PTY + toast” but does not specify audit entry or synchronous phone-visible signal. Silent fallback is unauditable and confuses user (why is view terminal when Desktop selected?). | Security visibility gap; user cannot distinguish fallback from bug; chain tamper-detection blind to fallback. | Plan § C Risks, § E Security | **C must emit audit entry with `denyReason="screen_recording_denied_fallback_to_pty"` + `beforeScreenshotHashHex=nil` + `approvedBy=.denied` and emit `SystemPermissionMonitor.emitRequesting(.screenRecording)` synchronously for phone pill; Mac toast + “Open System Settings” deep link (reuse `SystemPermissionReceiver.openDeepLink`). (C, D)** |
| **R-05** | **P1** | **Stale audit path in plan** | Plan doc path `computer-use` vs code `computer-use-audit` → implementer or future doc may write to wrong dir, fragmenting chain. | Engineering confusion, QA path mismatch, evidence drift. | Plan §2 Subagent C, § E, File tree §6 | **A/B/C must fix docs to `computer-use-audit`; keep `OpenBurnBarIdentity.swift:80-81` + `ComputerUseRuntimeController.swift:413-414` as source of truth. (A, E)** |
| **R-06** | **P1** | **Provider-bundle allowlist freshness** | Plan adds 11 provider bundles but does not pin versioned bundle IDs (`com.anthropic.claudefordesktop` unverified on 2-yr MBA — Plan Q2; Factory/MiniMax/Z.ai bundle IDs are placeholders). Wrong bundle → fallback loop or wrong window captured. | Feature appears broken or captures wrong app. | Plan §5 Q2, §1 table | **A must verify bundle IDs on real apps (`mdfind kMDItemCFBundleIdentifier` + `NSWorkspace.urlForApplication(withBundleIdentifier:)`) and store them in `catalog.json` Allowlist, not hardcoded in Swift. Add probe test. (A)** |
| **R-07** | **P2** | **Iroh claim nuance** | Plan says bytes go peer-to-peer over iroh, not through servers — true for media bytes, but omits that control plane (capability/budget/presence) touches Firestore (`MediaBudgetStatusStore`, `MacCloudEntitlementStore`, `MercuryRouter` control frames). | User overestimates metadata privacy; SE may flag as overclaim. | Plan §0, § C “No new daemon socket, no new Firestore collection.” | **E + docs must qualify: “Media bytes → iroh `MediaStreamSink` (`MediaSessionCoordinator` + `MercuryRouter` blob backend); presence/budget/entitlement → Firestore (metadata only, sealed).” Add docs & rollout notes. (E)** |
| **R-08** | **P2** | **PTY PNG hash parity** | New PTY PNG snapshot (NSTextView render) could diverge from audit hasher if different PNG encoder/props, breaking `ComputerUseAuditChain.validate` and head.json check. | Chain invalid on verification; future BLAKE3 migration harder. | Plan § C “add optional PNG snapshot of the PTY view” | **C→E: Route both PTY and Desktop PNG through `MacScreenshotService` (same `NSBitmapImageRep(cgImage:).representation(using:.png, properties:[:])` + `SHA256.hash`) and assert `Capture.sha256Hex == ComputerUseAuditHasher.current.hash(data:pngData)` in tests. (C, E)** |
| **R-09** | **P2** | **Linux portal vs macOS allowlist asymmetry** | Linux uses portal picker (user-selected window) as allowlist; macOS uses bundle filter. If Linux also adds automatic window enumeration without portal, it would reintroduce P0. | Future drift. | Plan § C Linux | **C must not add Linux `CGWindowList*` equivalent; keep `MercuryLinuxScreenCastGrant.isLive` + `pipeWireFD` checks as sole gate. Document that Linux capture is *always* portal-gated. (C)** |
| **R-10** | **P2** | **Toggle state leakage** | `VisualCapturePreferences` is `UserDefaults` local-only (Plan § B). No Firestore sync — good for privacy, but support may debug wrong surface. | Support confusion, not privacy leak. | Plan § B “No new SQLite table; Firestore opt-in… out of scope for v1” | **B must ensure `visualCaptureSurfaceSelected` telemetry (`provider`, `surface`, `trigger: settings|session_header`, `fallbackUsed`) is the only sync; never sync PNG pixels or window titles. Already planned in § E — verify `AnalyticsEvent` payload excludes window titles (check before merge). (B, E)** |
| **R-11** | **P2** | **Threat-model coverage** | `BurnBar-threat-model.md` (commit `ba9e7c14`, 2026-06-12) defines `desktop_system_input`/`shell`/`shell_unrestricted`/`grant` semantics (AGENT.md `desktop_system_input, shell, grant sections`) and “Abuse broad agent capabilities” / “Compromised local agent runtime” ( §5 ), but has no `desktop_screenshot` capture-scope analysis distinct from `desktop_system_input` (input). | Reviewers may conflate screenshot capture with input. | Plan § C, Threat model §5 | **C must annotate threat model addendum: Desktop capture is `desktop_screenshot` capability, scoped by window allowlist + deny-list, not by `desktop_system_input` scope rules — but `desktop_screenshot` grant already exists (`AgentDesktopCapability.desktopScreenshot` — `AgentCapabilityGrant.swift:6`). No new grant needed; just document that toggle honors existing gate. (C)** |

---

## 7. Checklist for Subagent C (Capture Engine) and Subagent E (QA/Telemetry)

### Subagent C — MUST before review (P0/P1)

- [ ] **C-1 — Synchronous TCC gate.** In `MacScreenshotService.capture(mode:label:sessionId:entryIndexHint:)` add `guard CGPreflightScreenCaptureAccess() else { throw .screenRecordingPermissionDenied }` as the *first* statement when `mode == .desktop(...)`. Also guard `ScreenCapturePipeline.start` path (already does via `currentShareableContent` — keep and add assertion). Do NOT read `SystemPermissionMonitor.snapshots` as gate; keep `Monitor` as observer for phone pill only. Evidence: `MacScreenshotService.swift:48-62`, `ScreenCapturePipeline.swift:273-284`.
- [ ] **C-2 — Document AX vs Screen Recording.** In PR description + `MacScreenshotService` doc comment, state: capture needs `Screen Recording`; *input* needs `Accessibility` (`AXIsProcessTrusted` — `SystemPermissionMonitor.swift:346`). Toggle UI should show Screen Recording status for Desktop surface, Accessibility status only when input is also requested (separate).
- [ ] **C-3 — Window allowlist + deny-list.** Implement `allowedProviderBundles` (from `catalog.json` — A’s output) and `deniedBundleIDs` = `ComputerUseDenyRegistry.builtInRules.map(\.bundleId)` (`ComputerUseDenyRegistry.swift:9-33`) union `MacComputerUseDenyRegions.sensitiveBundles` (`MacComputerUseDenyRegions.swift:22-29`). Prefer `SCContentFilter(desktopIndependentWindow:)`; if CG fallback, use `kCGWindowListOptionOnScreenOnly | kCGWindowListOptionIncludingWindow` and assert `onScreenWindowsOnly:true` source. Fail closed to `throw .deniedWindow` → PTY fallback if no match.
- [ ] **C-4 — FS hardening.** `createDirectory(… attributes:[.posixPermissions:0o700])` for `computer-use-audit/<session>/screenshots/` and `setAttributes([.posixPermissions:0o600])` after each `png.write` / `chain.jsonl` / `manifest.json` / `head.json` write (`ComputerUseAuditLogger.swift:54-64, 72-100, 178-186` mirrors `ComputerUseLocalQuotaLedger.swift:297,311`). Verify with `stat -f %Mp%Lp`.
- [ ] **C-5 — Fallback audit + synchronous phone signal.** On `screenRecordingPermissionDenied` or `deniedWindow`, emit audit entry (`denyReason: "screen_recording_denied_fallback_to_pty"` or `"denied_window_fallback_to_pty"`, `approvedBy:.denied`) and `await SystemPermissionMonitor.shared.emitRequesting(kind:.screenRecording, …)` synchronously (not next poll) so phone pill appears immediately. Mac toast: `“Screen Recording denied — showing terminal. Open System Settings → Privacy & Security → Screen Recording.”` with deep link via `SystemPermissionReceiver.openDeepLink(for:.screenRecording)` (`SystemPermissionReceiver.swift:203-208`) / `SystemPermissionKind.screenRecording.systemSettingsDeepLink`.
- [ ] **C-6 — Route PTY + Desktop PNG through same hasher.** Both surfaces call `MacScreenshotService` → `NSBitmapImageRep(cgImage:).representation(using:.png, properties:[:])` → `SHA256.hash(data:)`. Do not introduce JPEG or different `properties`. Ensure `ComputerUseSessionCoordinator+Approvals` path stores `beforeScreenshotHashHex = capture.sha256Hex`.
- [ ] **C-7 — No new Firestore/Storage sink for frames.** Assert `ScreenCapturePipeline` + new `VisualCaptureSource` branch do not import `FirebaseFirestore`/`FirebaseStorage` for frame transport. Frames must continue to `MediaStreamSink` (`MediaSessionCoordinator.swift:474-476`, `MacFileTransferService.swift:729-832`). Add `rg FirebaseFirestore AgentLens/Services/Media/ScreenCapturePipeline.swift` to CI or unit test.
- [ ] **C-8 — Linux invariant.** Keep `MercuryLinuxCaptureEngine` portal-only (`MercuryLinuxScreenCastGrant.isLive` + `invalidPipeWireFD` guards — `MercuryLinuxCaptureEngine.swift:220-234`). Do not auto-enumerate windows without portal.

### Subagent E — MUST before ship

- [ ] **E-1 — Permission-revocation test.** Add `MacScreenshotServiceTests.test_captureMode_desktop_failsWhenScreenRecordingRevoked` — mock `CGPreflightScreenCaptureAccess` → false, assert Desktop `throw`, PTY still succeeds, monitor emits `.needsAccess` within same tick.
- [ ] **E-2 — Window-filter test.** `test_desktopCapture_rejectsDeniedBundleIDs` — fixtures with `bundleID = com.apple.SecurityAgent / com.apple.loginwindow / com.apple.keychainaccess` assert fallback; `test_allowsAllowedProviderBundle` for each of 11 providers.
- [ ] **E-3 — Hash parity test.** `test_pngHashEqualsAuditHasher` — `XCTAssertEqual(Capture.sha256Hex, ComputerUseAuditHasher.current.hash(data: capture.pngData))` for both PTY-rendered and Desktop PNG.
- [ ] **E-4 — FS-permissions test.** After capture, assert `FileManager.default.attributesOfItem(atPath: pngURL.path)[.posixPermissions] as? Int == 0o600` and directory `0o700`.
- [ ] **E-5 — Fallback audit test.** Denied Desktop capture → verify `chain.jsonl` contains entry with `denyReason == "screen_recording_denied_fallback_to_pty"` and `beforeScreenshotHashHex == nil`; verify phone frame emitted (`control.system.permission.status` with `kind=screenRecording status=needsAccess`).
- [ ] **E-6 — Iroh-only regression.** `rg -n "Firestore.firestore\|Storage.storage" AgentLens/Services/Media/MediaSessionCoordinator.swift AgentLens/Services/Media/ScreenCapturePipeline.swift` returns only budget/presence paths; `rg "write.*frame" AgentLens/Services/Media` hits only `MediaStreamSink.write(frame:)` and `MediaFrameAEAD` path (`MacFileTransferService.swift:819,847`).
- [ ] **E-7 — Telemetry privacy check.** `AnalyticsEvent.visualCaptureSurfaceSelected` (`Plan § E`) payload contains only `provider`, `surface: cli|desktop`, `trigger: settings|session_header`, `fallbackUsed: bool` — never `windowTitle`, `bundleID`, or pixel hash. Verify via unit test on `AnalyticsEvent` encoder.
- [ ] **E-8 — Docs fix.** Update `Plan §File tree` + `SUBAGENT_C_ENGINE.md` + `docs/PROVIDERS.md` path from `computer-use` → `computer-use-audit`; add iroh vs control-plane note to `docs/security/BurnBar-threat-model.md` addendum or `docs/HERMES_COMPUTER_USE.md`.
- [ ] **E-9 — Perf budget invariant.** Re-run `BackgroundCadenceCoordinator` idle + `MediaBudgetStatusStore` (`budgets/macos-idle-cpu.perf.json` — `Plan § E`) with toggle set to Desktop but no active `SCStream` — assert pipeline idle (`SCStream == nil`), CPU `<0.8%` / RSS `<140 MB` (PR #2193 budget).

### Subagent B/D — Should verify (not blocking but review-grade)

- [ ] **B-1 — BundleID source of truth.** `catalog.json` `visualSurfaces: ["cli","desktop"]` Allowlist must drive `allowedProviderBundles`; never hardcode in `MacScreenshotService`. Verify via `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` + `FileManager.fileExists(atPath:"/Applications/<App>.app")` fallback per Plan §1.
- [ ] **D-1 — UI affordance.** Settings → Providers → Visual Surface warns “Desktop shares pixels with paired phone over iroh” and shows fallback caption “Screen Recording denied — using terminal” with `Open System Settings` link (not silent). Inline session pill overrides Settings for this session only, with “Remember” opt-in, not sticky by default.
- [ ] **D-2 — Window-position guidance.** Help tooltip: “For Desktop sharing, keep the provider window front-most and occlusive; display capture may include background pixels.”

---

## 8. References (file:line)

- `AgentLens/Services/ComputerUse/Mac/MacScreenshotService.swift:48-64` — display capture + PNG + SHA256
- `AgentLens/Services/Media/ScreenCapturePipeline.swift:253-289` — `shouldExcludeApplicationFromDisplayCapture`, `CGPreflightScreenCaptureAccess`, `SCShareableContent.excludingDesktopWindows(onScreenWindowsOnly:true)`, `SCContentFilter(displayIndependentWindow:)`
- `AgentLens/Services/ComputerUse/SystemPermissionMonitor.swift:105-130, 340-360` — cadence (5 s / 30 s / `didBecomeActiveNotification`), `readScreenRecordingStatus` (`CGPreflightScreenCaptureAccess`), `readAccessibilityStatus` (`AXIsProcessTrusted`)
- `AgentLens/Services/ComputerUse/SystemPermissionReceiver.swift:178-188, 203-208` — `runPrompt(kind:)` / `openDeepLink(for:)`
- `AgentLens/Services/Media/MercuryRouter.swift:73-78, 124-142, 276` — iroh `NodeId`, `MirrorSinkFactory: … -> MediaStreamSink` (“per-GOP iroh dial”), Firestore only for trust
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/MercuryLinuxCaptureEngine.swift:21-36, 65-77, 220-234` — `pipeWireFD`, `isLive`, `portalConsentNotLive`
- `AgentLens/Services/Media/MediaSessionCoordinator.swift:10-24, 474-476` — `capture pipeline → encoder → packetizer → iroh stream` + `MediaStreamSink.write(frame:)`
- `AgentLens/Services/Media/MacFileTransferService.swift:432, 511, 617, 729-832` — `MercuryControlStreamMediaSink`, `MediaFrameAEAD` (OBMFA1), `MediaPacketCodec`, fire-and-forget `write(frame:)`
- `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseAuditLogger.swift:45-100, 158-198, 178-186` — `baseDirectory / sessionId / screenshots`, `beforeScreenshotHashHex`, `ensureDirectoryExists` (no 0700 today)
- `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseAuditChain.swift:117-160, 137` — `ComputerUseAuditHasher.current` SHA256, `canonicalJSONEncoder` (sortedKeys, ms Date), `genesisParentHashHex`
- `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseDenyRegistry.swift:9-45` — `builtin.loginwindow/securityagent/security_agent_helper/keychain/privacy_pane`
- `AgentLens/Services/ComputerUse/Mac/MacComputerUseDenyRegions.swift:22-62` — `sensitiveBundles` + `isSecureTextField` (`AXSecureTextField`) + `systemAuthSheet`
- `OpenBurnBarCore/Sources/OpenBurnBarKernel/Platform/OpenBurnBarIdentity.swift:80-81` — `supportDirectory = applicationSupportRoot / OpenBurnBar`
- `AgentLens/Services/ComputerUse/ComputerUseRuntimeController.swift:413-414` — `supportDirectory / computer-use-audit`
- `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/AgentCapabilityGrant.swift:6-12` — `AgentDesktopCapability.desktopScreenshot / desktopSystemInput / shell`
- `docs/security/BurnBar-threat-model.md:5.2, 8 (Auth/App Check), 10-11 (Residual Surfaces)` — threat model around `desktop_system_input` / `shell` / grants; note: no `desktop_screenshot` capture-scope analysis today
- `plans/2026-05-09-visual-capture-source-toggle/README.md:§0, §1, §2 Subagent C, §5 Q2-Q4, §6` — plan claims inspected

---

## 9. Open Questions for Plan Authors (from this audit)

1. **Q2 (Claude bundle) confirms P1.** Author states `com.anthropic.claudefordesktop` — do not assume; Subagent A must `mdfind` on a 2-yr MBA and probe `NSWorkspace.urlForApplication(withBundleIdentifier:)` at runtime with path fallback. If not found, toggle must be disabled with install link, not default to display capture.
2. **Q3/Q4 are not blockers** but the answer “require bundle for Desktop segment, else disabled” (Warp, Hermes) is the correct privacy posture — prevents accidental display capture when provider app not installed.
3. **Plan §5 Q1 (Cursor split)** has no privacy impact, but do not conflate execution-source split with capture-surface choice — keep `visualSurfaces` allowlist separate from `AgentProvider` case.

---

*No code was edited. Report written to `plans/2026-05-09-visual-capture-source-toggle/SECURITY_REVIEW.md` per task. Worktrees preserved read-only.*

