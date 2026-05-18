# Computer Use Master Plan
## Watch your agent — Take it over — Hand it back

**Date:** 2026-05-16
**Owner:** Alberto
**Branch baseline:** `chore/router-brand-coherent-rail`
**Substrate baseline:** Mercury Media — Phase 3 (Mac → iOS screen share) green; `media.classify` in-band stream-class negotiation green (`AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift:81`).
**Agent baseline:** `OpenBurnBarDaemon` runs `BurnBarRunService` with `BurnBarApprovalRequest` gating today (`OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarApprovalContracts.swift`). `BurnBarBrowserToolService` already detects Playwright and dispatches `BurnBarBrowserActionKind.{openExternal,fetchDocument,extractLinks}` (`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarBrowserToolService.swift`).
**Targets:** AgentLens (macOS 14+), OpenBurnBarMobile (iOS 17+ / iPadOS 17+), Android (parity follows iOS by one phase, per `docs/ANDROID_NATIVE_PARITY_GOAL.md`).
**Status:** Approved end-to-end design. Phase 8 ready to start.
**Supersedes:** N/A — net-new feature line. Layers on `plans/2026-05-15-mercury-media-master-plan.md`.

---

## Context

OpenBurnBar already runs agents on the local Mac. The Hermes/Codex/Claude CLI bridge, the local `BurnBarRunService` agent loop, the explicit-approval flow, and an integrated Playwright probe are all in source today. Mercury Media added a Mac → iOS screen-share stream over iroh QUIC with ≤250 ms glass-to-glass latency, end-to-end peer encryption, Ed25519-signed pairing, and per-user bandwidth budgets (`docs/HERMES_MEDIA_TRANSPORT.md`).

The natural next layer is **Computer Use**: let the agent actually drive a window (Path B — browser only) or the whole Mac (Path C — system-wide), while the user **watches from their paired iPhone or iPad** (Path A) and can **tap the phone to intervene** (Path D). This master plan lays out all four paths, the transport substrate, the trust + audit model, the SKU + budget envelope, and the six-phase rollout that ships them safely.

This is the rare feature line where the substrate is already 70% built. The hard work is **the trust model, the audit chain, the deny regions, and the kill switches** — not the transport, capture, or rendering.

---

## Executive summary

Computer Use adds four capabilities layered on the existing iroh QUIC mesh + Mercury Phase 3 substrate:

1. **Agent Watch** — Mac → phone read-only mirror with an action overlay. The user sees what the agent is doing, the next planned action, the approval prompt, and live cost tally. No new transport — extends `media.screen.video` + adds `control.action.log`.
2. **Browser Computer Use** — agent gets a new family of tools (`browser.click`, `browser.fill`, `browser.goto`, `browser.key`, `browser.select`, `browser.screenshot`, `browser.extract`) that drive a managed Playwright Chromium window. Smallest blast radius — every action escapes through the Chromium sandbox.
3. **Mac Computer Use** — agent gets system-wide tools (`mac.input.click`, `mac.input.type`, `mac.input.shortcut`, `mac.input.dragdrop`, `mac.inspect.accessibility`) backed by `CGEvent` + `AXUIElement`. Larger blast radius, gated by Accessibility permission, deny regions, and explicit per-session scope.
4. **Phone-as-controller** — the phone emits *intent* (tap at normalized frame coord, type text, send shortcut, pause/resume agent, panic stop) back to the Mac over a new `control.input` stream. Mac validates Ed25519-signed authority envelope + monotonic counter, applies same deny-region matcher, translates to a `CGEvent`.

All four sit on **three trust modes** (Manual / Step / Trusted) chosen per session, **scope rules** (URL prefix + bundle-id + window-title regex with explicit deny defaults), and a **tamper-evident audit chain** (BLAKE3 hash-chain over (timestamp, action, pre/post screenshot hash)).

**No new ALPN. No new encryption hop. No WebRTC.** Adds three iroh stream classes (`control.surface.frame`, `control.action.log`, `control.input`) and one optional control frame type (`control.classify`) — mechanically identical to the Mercury Phase 3 extension.

A new **`hosted_computer_use_sync`** entitlement ($14.99/mo) gates the agent surface; **only the Mac needs the entitlement** (the phone is a viewer/controller paid for by the host). Daily envelope: 200 actions/day, 30-min session cap. Hosted-relay/vision-model budget guard: **$1500/mo soft cap** (auto-tightening), **$2500/mo hard cap** (Remote Config kill-switch). Six phases ship independently behind flags.

---

## Locked decisions (2026-05-16)

### Decision 1 — Approval is the only ground truth, no auto-pilot at v1

Every agent-initiated input event passes through `BurnBarApprovalRequest` before dispatch unless the active session is in **Trusted** mode AND the action matches an active scope rule. There is no "let it run silently" toggle at v1. We trade theoretical UX flow for an unambiguous safety story during launch — the Trusted-mode pre-approval flow (Phase 13) is the eventual relief valve.

Adds friction; mitigation: the Mac approval sheet pre-renders inside the popover (≤16 ms paint), the phone approval row swaps in over the action timeline without an animation jump, and Step mode lets the user pre-approve a *next 30 seconds of similar actions* burst.

### Decision 2 — Three trust modes, chosen per session, never per agent

| Mode | Approval per action | Audit | Use case |
|---|---|---|---|
| **Manual** (default) | Yes, every action | Always | First run with a new agent, sensitive domains, anything unfamiliar |
| **Step** | Yes, but burst-approval (10 actions or 30 s) | Always | Watching a known agent on a known task |
| **Trusted** | Only if action escapes the active scope rule | Always | Pre-defined automation (e.g., GitHub triage on `github.com/owner/repo`) |

Stored on `ComputerUseSessionDoc.trustMode`. Defaults reset to Manual when starting a fresh session — Trusted is never sticky across sessions. The mode picker lives in the new `ComputerUseSessionPanel.swift` and surfaces on the phone overlay so the user can downgrade from Trusted → Manual on the phone if the agent starts misbehaving.

### Decision 3 — Browser CU ships before Mac CU

Phase 9 (Browser) precedes Phase 11 (Mac System) by ≥ 14 days of soak. Playwright actions never escape the Chromium sandbox; the worst case is "agent posted a wrong tweet inside its own browser." Mac System actions can `rm -rf ~`, open Mail and send a message, drag-drop a Keychain item. We earn the system surface through Browser-mode field data.

### Decision 4 — Cursor mirroring rides the existing screen-video stream

Cursor position is read from the `SCStreamConfiguration.showsCursor` already true in `ScreenCapturePipeline`. We do not open a separate cursor-coords stream. The phone overlay reads cursor position from the decoded frame itself (no out-of-band synchronization to keep in sync). Action overlays (the "Clicking 'Submit'..." chip) ride the new reliable-ordered `control.action.log` stream and are time-anchored to the surface stream by GOP-ordinal — same approach Mercury uses for stats.

### Decision 5 — Phone emits intent, Mac translates to HID

The phone never sends raw `CGEvent` payloads. It sends an `ActionIntent { kind: .tap, normalizedPoint: (0.45, 0.62), modifiers: [], authority: signedEnvelope }`. Mac:
1. Validates the Ed25519 signature against the paired peer's pubkey (from existing `iroh_pairing` doc).
2. Validates a monotonic counter (replay protection).
3. Maps normalized coord to display coord via `MacScreenshotService` calibration.
4. Runs the same deny-region matcher that gates agent-initiated actions.
5. Synthesizes the `CGEvent` and posts it.

This means the phone cannot ask the Mac to do anything the agent itself couldn't do — same gate, same audit. The phone's only special privilege over an agent is that **it doesn't need explicit approval per action in Manual mode** (the user is already holding the phone — they are the approval).

### Decision 6 — Phone overlay is the only visible action queue

Mac has a `ComputerUseSessionPanel.swift` for configuration; the active action queue, however, lives **only** on the phone overlay. Two reasons:
- The Mac is where the agent is actually doing things — adding a Mac-side queue creates a visual race with the agent's own cursor.
- The phone is the operator's seat. Keeping the queue on the phone is the design pressure that forces us to make the phone overlay carry its own weight.

The Mac panel shows: current trust mode, active scope rules, the latest audit-chain entries, and the panic-stop button. Not a queue.

### Decision 7 — Panic kill has three independent paths

| Source | Trigger | Latency budget |
|---|---|---|
| Global hotkey | `⌃⌥⌘.` registered via `NSEvent.addGlobalMonitorForEvents` | ≤ 100 ms hotkey → driver kill |
| Phone gesture | Three-finger long-press on `AgentWatchView` for 800 ms | ≤ 200 ms phone tap → driver kill (network) |
| Auth gate | Mac lock screen / fast user switch / `loginwindow` activation | ≤ 100 ms NSWorkspace notification → driver kill |
| Remote Config | `computer_use_kill_switch = true` (server-side) | ≤ 60 s cache TTL |

The hotkey and the auth gate are **must-have**. Phone gesture is the convenience path. Remote Config is the org-wide brake.

### Decision 8 — Audit log is content-addressed and tamper-evident

Each audit entry:
```json
{
  "sessionId": "<uuid>",
  "entryIndex": 42,
  "timestamp": "2026-05-16T18:24:33.412Z",
  "action": { "kind": "browser.click", "selector": "button[type=submit]", "url": "https://github.com/..." },
  "beforeScreenshotBlake3": "<32 bytes hex>",
  "afterScreenshotBlake3": "<32 bytes hex>",
  "approvalId": "<uuid>?",
  "approvedBy": "mac" | "phone" | "trustedScope",
  "parentEntryBlake3": "<32 bytes hex>"
}
```

`parentEntryBlake3` is BLAKE3 of the prior canonical-JSON entry. The first entry's parent is BLAKE3 of the session-start manifest. Tampering with any entry breaks the chain. Verification: a pure-function validator walks the file and re-hashes.

Screenshots are stored only on the local Mac under `~/Library/Application Support/com.openburnbar.AgentLens/computer-use-audit/{sessionId}/`. The chain header (timestamps + hashes only, no screenshots) is replicated to `users/{uid}/computer_use_actions/{actionId}` for cross-device visibility on the phone.

### Decision 9 — Separate SKU `hosted_computer_use_sync`, not extending `hosted_media_sync`

Different threat model, different price-discrimination class, different per-action cost (vision-model dollars). Keeping it separate lets us churn pricing on either side without affecting the other. `burnbar_pro_max` ($24.99) bundles `hosted_quota_sync` + `hosted_media_sync` + `hosted_computer_use_sync`. Existing `hosted_media_sync` subscribers get **no grandfather** for CU (unlike Mercury Phase 2's media-grandfather) — the cost asymmetry is too high.

### Decision 10 — Bounded vision context per turn (cost control)

Each agent turn sees: (1) the most recent full-resolution screenshot, (2) up to 3 prior screenshots downsized to 320×180 thumbnails, (3) the last 5 audit-chain action descriptions (text only). No DOM dump, no AX tree dump in the prompt by default — the agent must call a `browser.extract` / `mac.inspect.accessibility` tool to read structure, which is auditable.

Estimated per-turn token cost: ~3.5K input + ~400 output on Claude Sonnet 4.5 = $0.013/turn at list pricing. 100-turn run = $1.30. Budget envelope keys off the same `evaluateComputerUseBudget` function.

---

## Capability matrix

| Capability | Direction | Throughput | Latency budget | Max session | Concurrent | Entitlement | Soft cap | Hard cap |
|---|---|---|---|---|---|---|---|---|
| Agent Watch (read-only) | Mac → iOS/Android | Reuse Mercury Phase 3 envelope (2.5–8 Mbps HEVC) | ≤ 250 ms glass-to-glass · ≤ 200 ms action-log delivery | 60 min/session, 120 min/day | 1 active | `hosted_media_sync.screenShare` (inherited) | Mercury soft cap | Mercury hard cap |
| Browser Computer Use | Mac local (Playwright) | n/a (DOM driver) | ≤ 500 ms approval → action (Manual) · ≤ 200 ms Step/Trusted | 30 min/session, 4 sessions/day | 1 active | `hosted_computer_use_sync.browser` | 25 actions/run · 100/day | 0 (paused) |
| Mac Computer Use | Mac local (CGEvent + AX) | n/a | ≤ 300 ms approval → CGEventPost (Manual) · ≤ 150 ms Step/Trusted | 30 min/session, 4 sessions/day | 1 active | `hosted_computer_use_sync.system` | 25 actions/run · 100/day | 0 (paused) |
| Phone-as-controller | iOS/Android → Mac | ~1 KB/event reliable-ordered | ≤ 200 ms tap → CGEventPost | Inherits host session | 1 active controller per session | `hosted_computer_use_sync.controller` (host pays) | inherits | inherits |

Three knobs we can tighten without re-shipping:

1. **Per-session action ceiling** (default 50 actions/run, max 200). Conservative for Phase 9 launch; loosens once Phase 11 stabilizes.
2. **Daily envelope** (200 actions/day) maps to ≤ $1 of vision-model spend per user-day at p99 — comfortably under $14.99 SKU margin even if half the userbase saturates.
3. **Concurrent sessions = 1**. No parallel agents driving the same Mac. A second session attempt returns `.denied(reason: concurrentSession)` with an "End current session" prompt.

---

## A. Transport plan over iroh

### A.1 Stream classes (extending `MediaStreamClass`)

`MediaStreamClass` is already a string-newtype designed for in-band negotiation (`OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaStreamClass.swift`). We add four new classes; older peers route unknown classes to a no-op handler, so this is forward-compatible.

| Stream class | Cardinality per session | Direction | QUIC discipline |
|---|---|---|---|
| `control.surface.frame` | 1 per GOP (~60 frames @ 30 fps) | Mac → iOS/Android | Reliable, ordered, stream-per-GOP — **alias of `media.screen.video`** with an additional `cursor` field in the codec header (4 extra bytes: `int16 cursorX`, `int16 cursorY`). When the alias is detected, the receiver routes to `AgentWatchReceiver` instead of `ScreenShareViewerCoordinator`. |
| `control.action.log` | 1 per session | Mac → iOS/Android | Reliable, ordered — JSON envelope `{entryIndex, timestamp, action, status, screenshotHash?}` per planned/executing/completed/failed action |
| `control.input` | 1 per session | iOS/Android → Mac | Reliable, ordered — JSON envelope `{intent, normalizedPoint?, text?, key?, modifiers?, authority: {sig, counter, peerNodeId}}` |
| `control.approval` | 1 per session | Bidirectional | Reliable, ordered — JSON envelope wrapping the existing `BurnBarApprovalRequest` / `BurnBarApprovalResponse` Codable types verbatim |

A new `control.classify` frame is the first frame sent on any new bi-stream after `request.start`-style negotiation, identical to the `media.classify` shape — receiver sees `{ media: { streamClass: "control.input" } }` and routes to the right handler.

### A.2 Wire layout (no new ALPN)

The existing `HermesRealtimeRelayMediaPayload` (`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRealtimeRelayTypes.swift:65`) is the carrier. We add three new frame types to `HermesRealtimeRelayFrameType`:

```swift
case controlActionLogEntry = "control.action.log.entry"
case controlInputIntent = "control.input.intent"
case controlApprovalRequest = "control.approval.request"
case controlApprovalResponse = "control.approval.response"
```

And one new sibling-of-`media` payload type `HermesRealtimeRelayControlPayload` carrying the typed fields. `JSONEncoder` omits absent optionals, so chat-only / media-only traffic stays byte-identical to the pre-rollout wire form.

### A.3 Surface frame codec (extending `MediaPacketCodec`)

The existing 16-byte frame header gains a 4-byte extension:

```
existing:  | u8 type | u8 flags | u16 GOPid | u32 ptsMs | u32 frameIdx | u32 nalLen | <NAL units...> |
new:       | ... existing 16 bytes ... | i16 cursorX | i16 cursorY | <NAL units...> |
```

The `flags` byte gains a `kHasCursorMetadata` bit (`0x04`). Receivers that don't set the bit ignore the 4 trailing bytes — codec stays backward-compatible.

### A.4 Phone-control authority envelope

```swift
struct PhoneControlAuthority: Codable, Sendable {
    let peerNodeId: String           // base32 iroh NodeId
    let counter: UInt64              // monotonic, per peer
    let timestamp: Date              // freshness window check (≤ 5 s)
    let intentHashBlake3: String     // hex BLAKE3 of canonical intent JSON
    let signatureEd25519: String     // base64 of Sign(peerPrivKey, intentHashBlake3 || counter || timestamp)
}
```

Mac-side validator:
1. Look up peer pubkey from `users/{uid}/iroh_pairing/{connId}.peerPubKey`.
2. Verify `signatureEd25519` against `intentHashBlake3 || counter || timestamp` with `Curve25519.Signing.PublicKey`.
3. Reject if `counter <= lastSeenCounter[peerNodeId]`.
4. Reject if `|now - timestamp| > 5 s`.
5. Re-hash the intent JSON and compare to `intentHashBlake3`.

Replay protection is structural — same Ed25519 pattern Mercury Phase 1 uses for the iroh-blobs ticket exchange.

### A.5 Why not WebSocket / WebRTC / DataChannel

Same axes as Mercury Decision 6:
- iroh-tls already encrypts.
- WebRTC DataChannel adds ~7 MB binary + DTLS+SRTP redundancy.
- Stream-class dispatch in our existing accept-loop is constant-time and already battle-tested by Hermes + media.
- We already pay the audit-event cost for iroh streams; adding control-plane streams gets free observability.

---

## B. macOS implementation (AgentLens + daemon)

### B.1 New shared SwiftPM target — `OpenBurnBarComputerUseCore`

Lives under `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/`. Cross-platform-safe (no AppKit, no AVFoundation). Carries:

| File | Role |
|---|---|
| `ComputerUseSessionMetadata.swift` | `ComputerUseSessionID`, `ComputerUseMode` (.agentWatch / .browser / .system), `ComputerUseTrustMode` (.manual / .step / .trusted), `ComputerUseEndReason` |
| `ComputerUseScopeRule.swift` | `URLPrefixRule`, `BundleIDRule`, `WindowTitleRule`, `DenyRule` (always wins). Pure matcher functions tested in isolation. |
| `ComputerUseDenyRegistry.swift` | Hard-coded deny defaults (lock screen, password fields, Keychain, Mail composer "Send" until reviewed, etc.). Extended by user-defined `DenyRule` entries. |
| `ComputerUseAuditEntry.swift` | Codable entry + canonical-JSON serializer + BLAKE3 hash extension. |
| `ComputerUseAuditChain.swift` | Walker + validator. Pure. Tested with golden fixtures. |
| `ComputerUseActionDescriptor.swift` | Typed action models for `BrowserAction`, `MacInputAction`, `PhoneControlIntent`. The `executableSummary(forApproval:) -> String` helper that produces "Click 'Submit' button at (460, 812) on github.com" copy for the approval sheet. |
| `ComputerUseCapabilityGate.swift` (protocol) | Same shape as `MediaCapabilityGate`. |
| `ComputerUseBudgetEnvelope.swift` | Bucket types for normal/soft/hard cap; consumed by `MediaCapabilityGate` impls. |

### B.2 New module `AgentLens/Services/ComputerUse/`

| File | Role |
|---|---|
| `ComputerUseSessionCoordinator.swift` | Mac-side orchestrator. Mirrors `MediaSessionCoordinator` shape. Owns active mode (agentWatch/browser/system), trust mode, scope rules, audit-chain handle, fan-out to `AgentWatchHUDSession` (Path A) and `BrowserActionDispatcher` / `MacActionDispatcher` (Paths B/C). Publishes `@MainActor` `ComputerUseSessionState` via Combine + `@Observable`. |
| `ComputerUseCapabilityGate.swift` (impl) | Reads `MacCloudEntitlementStore.hostedComputerUseEntitlement` + per-session/per-day counters + `ops/computer_use_budget_status/state/current`. Returns `.allowed` / `.denied(.entitlement \| .sessionLimit \| .dailyLimit \| .softCap \| .hardCap \| .scope \| .denyRegion)`. |
| `AgentWatchHUDSession.swift` (Path A) | Opens a `control.surface.frame` stream (via `MediaSessionCoordinator.startScreenShare()` with a new `streamClassOverride: .controlSurface`) AND a sibling `control.action.log` stream. The latter publishes `AgentAction` events sourced from `BurnBarRunJournalEvent` (`approvalRequested`, `toolCallStarted`, `toolCallCompleted`, `runFailed`). |
| `BrowserActionDispatcher.swift` (Path B) | Routes `BurnBarToolKind.browser*` invocations through the new `OpenBurnBarPlaywrightDriver`, gated by approval. |
| `MacActionDispatcher.swift` (Path C) | Routes `BurnBarToolKind.macInput*` invocations through `MacInputController`, gated by approval + deny matcher. |
| `MacInputController.swift` (Path C) | Thin wrapper over `CGEventCreateMouseEvent`, `CGEventCreateKeyboardEvent`, `CGEventPost(.cghidEventTap, event)`. Validates point ∈ a connected display before emitting. Refuses if `AXIsProcessTrusted()` returns false. |
| `MacAccessibilityInspector.swift` (Path C) | Reads focused window's AX tree via `AXUIElementCreateApplication` + `AXUIElementCopyAttributeValue`. Returns role/title/value/frame for elements at a point. Used to (a) build human-readable approval copy, (b) feed the deny matcher. |
| `MacScreenshotService.swift` (Paths B+C) | Wraps `CGWindowListCreateImage` for one-off screenshots passed to the vision model. ScreenCaptureKit handles the live stream (already shipped). |
| `PhoneControlReceiver.swift` (Path D) | Owns the `control.input` stream. Validates `PhoneControlAuthority`. Calls `MacInputController` or `BrowserActionDispatcher` based on intent and active mode. |
| `PhoneControlAuthorityValidator.swift` (Path D) | Pure validator (sig, counter, freshness, hash match). Tested with golden Ed25519 fixtures. |
| `ComputerUsePanicHaltCoordinator.swift` | Global hotkey registration (`⌃⌥⌘.`), `NSWorkspace.willSleepNotification` + `NSWorkspace.sessionDidResignActiveNotification` listeners, Remote Config kill-switch listener. All three paths converge in `ComputerUseSessionCoordinator.panicHalt(source:)`. |
| `ComputerUseAuditLogger.swift` | Append-only writer to `~/Library/Application Support/com.openburnbar.AgentLens/computer-use-audit/{sessionId}.jsonl`. Maintains parent-hash chain. Replicates header to Firestore (metadata only). |
| `ComputerUseSessionLogger.swift` | Rolling 5-min JSONL in sandbox for action latencies, scope-violation counts, approval round-trip times. Never screenshots, never content. |

### B.3 New daemon module `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/`

| File | Role |
|---|---|
| `OpenBurnBarPlaywrightDriver.swift` (Path B) | Wraps Playwright CLI as a long-lived subprocess speaking JSON-RPC on stdio. We already detect `playwright` via `locateExecutable("playwright")` in `BurnBarBrowserToolService`. Lifecycle: one `chromium.launch(headless: false)` per CU session, window pinned visible so ScreenCaptureKit can target it via `SCContentFilter(desktopIndependentWindow:)`. Methods: `start(options)`, `click(selector, options)`, `fill(selector, text, options)`, `goto(url)`, `key(key)`, `select(selector, value)`, `screenshot() -> PNG`, `extract(selector) -> String`, `stop()`. Default 10 s per-action timeout. Strict selector resolution (timeout 2 s before failing — no implicit waits beyond that). |
| `OpenBurnBarPlaywrightLifecycle.swift` (Path B) | First-launch installer wrapper. If `playwright` not found, runs `npm install -g playwright@1.49.x && playwright install chromium --with-deps`. Idempotent; verifies binary checksum after install. Tracked in `BurnBarBrowserEngineKind.playwright` health-status surface that already exists. |
| `ComputerUseRunCoordinator.swift` | Extension over `BurnBarRunService` that recognizes the new `BurnBarToolKind.{browser*, macInput*, macInspect*}` and routes through the session coordinator. |

### B.4 Edits to existing files

- **`AgentLens/Services/IrohRelay/HermesIrohRelayHostClient.swift`** — accept-loop fans out by stream class. Today: chat + media. Add: `control.*` → hands off to `ComputerUseSessionCoordinator` adapter.
- **`AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift`** — extend the `case .mediaClassify, .mediaBlobAdvertise, .mediaBlobAck` switch arm with `.controlActionLogEntry, .controlInputIntent, .controlApprovalRequest, .controlApprovalResponse`. Dispatcher receives the frame + ack sender exactly the way the media dispatcher does today (line 158).
- **`AgentLens/Services/IrohRelay/HermesRelayHostFanout.swift`** — multiplex control streams under one iroh connection.
- **`AgentLens/Services/SettingsManager.swift`** — six new flags (`computerUseWatchEnabled`, `computerUseBrowserEnabled`, `computerUseSystemEnabled`, `computerUsePhoneControlEnabled`, `computerUseTrustedScopesEnabled`, `computerUseAuditExportEnabled`) mirrored to Remote Config. Plus a `computerUseKillSwitch` listener that calls `ComputerUseSessionCoordinator.panicHalt(source: .remoteConfig)`.
- **`AgentLens/Services/MacCloudEntitlementStore.swift`** — add `hostedComputerUseEntitlement` publisher mirroring the `hostedMediaEntitlement` pattern.
- **`AgentLens/App/AgentLensApp.swift`** — register global hotkey on `applicationDidFinishLaunching`; tear down on `applicationWillTerminate`.
- **`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRealtimeRelayTypes.swift`** — add four `controlSomething` frame types + `HermesRealtimeRelayControlPayload` sibling-of-`media` payload.
- **`OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaStreamClass.swift`** — add four new constants (`controlSurfaceFrame`, `controlActionLog`, `controlInput`, `controlApproval`) + `feature: ComputerUse` case in the existing `Feature` enum.
- **`OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarToolContracts.swift`** — extend `BurnBarToolKind` with 11 new cases:
  ```swift
  case browserClick = "browser_click"
  case browserFill = "browser_fill"
  case browserGoto = "browser_goto"
  case browserKey = "browser_key"
  case browserSelect = "browser_select"
  case browserScreenshot = "browser_screenshot"
  case browserExtract = "browser_extract"
  case macInputClick = "mac_input_click"
  case macInputType = "mac_input_type"
  case macInputKey = "mac_input_key"
  case macInputShortcut = "mac_input_shortcut"
  case macInputDragDrop = "mac_input_drag_drop"
  case macInspectAccessibility = "mac_inspect_accessibility"
  ```
  Each gets a `BurnBarToolDefinition` with `approvalPolicy: .userApproval` and `requiresTrustedWorkspace: true`. (Trusted-scope pre-approval is handled at dispatch time, not via the existing tool-definition flag.)
- **`OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarConnectorContracts.swift`** — extend `BurnBarBrowserActionKind` with `click`, `fill`, `goto`, `key`, `select`, `screenshot`, `extract`. Add `BurnBarBrowserActionArguments` carrying `selector`, `text`, `url`, `key`, `value` as optionals.
- **NEW** `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarComputerUseContracts.swift` — `ComputerUseSessionRequest`, `ComputerUseSessionResponse`, `ComputerUseInvokeRequest`, `ComputerUseInvokeResponse`, `ComputerUseAuditExportRequest`. All Codable; consumed by daemon RPC.
- **`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRunService+Execution.swift`** — `executeProviderOnlyRun` decision branch: when `run.intent.requestedToolsOrEmpty` intersects the CU tool set, route via `ComputerUseRunCoordinator.dispatch(...)` instead of the existing companion-tool dispatch.
- **`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarBrowserToolService.swift`** — extend `performAction` to handle the seven new `BurnBarBrowserActionKind` cases via the Playwright driver. The existing `BurnBarBrowserEngineKind.playwright` engine already validates the executable; only the dispatch matrix grows.
- **`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift`** — register `ComputerUseService` for socket-RPC consumption by the Mac UI (start session, get state, set trust mode, add scope rule, panic halt, export audit).

### B.5 macOS UI surfaces — `AgentLens/Views/ComputerUse/`

| Surface | Spec |
|---|---|
| `ComputerUseSessionPanel.swift` | New Settings panel under "Computer Use". 720×530 NavigationSplitView page. Sections: trust-mode pill picker (Manual / Step / Trusted), scope-rule list with add/remove (one rule per row, `mercuryGradient` 1pt stroke, swipe to delete), latest 10 audit-chain entries (mono ordinals, `monoTiny` action description, ember `●` for executed / mercury `○` for pending / error `✕` for rejected), "Panic stop" button (full-width, `error` bg, `display` 28pt typography). |
| `ComputerUseApprovalSheet.swift` | Modal sheet on each pending action. 1pt `mercuryGradient` border. Top: pre-action screenshot (320×180 thumbnail with `borderSubtle` stroke). Below: action description (`body` 14pt semibold), selector / coords (`monoSmall` 12pt `textMuted`), bottom row: Approve (`hermesAureate` fill with `mercuryShimmer`) · Reject (`error` outline) · Reject + Halt (`error` fill). Entry: `stripExpand`. |
| `ComputerUseSetupWizard.swift` | First-run flow. Three screens: (1) "What Computer Use does" with mercury-stroked illustration, (2) Permissions (Accessibility for Path C, browser install for Path B), (3) Benign sample action ("OpenBurnBar will open Calculator and compute 2+2"). Sample-action result rendered as a green `success` chip. |
| `ComputerUseScopeRuleEditor.swift` | Sheet to add a scope rule. Three tabs: URL prefix · Bundle ID · Window-title regex. Live preview against the current frontmost window/URL. Validates: refuses to save any rule that overlaps the built-in deny registry (Keychain bundle id, `loginwindow`, etc.). |
| `AgentWatchControlStrip.swift` | Mac-side strip in the popover header. Mercury-bordered "Watch on phone" button (caduceus → eye glyph). Disabled if no paired iOS pair or `computer_use_watch_enabled` off. Cooldown badge if a session ended < 30 s ago. |
| `ComputerUseIndicator.swift` | Menu-bar SF Symbol `circle.dotted` with `mercuryGradient` stroke + `mercuryPulse` while any CU session active. Tooltip mirrors `MercuryRing`. |
| Edit: `MediaPermissionsView.swift` | New capability card after Video Call: "Computer Use — Let an agent take actions on this Mac while you watch on your phone." Status pill ties to `hostedComputerUseEntitlement` + Accessibility permission. |

### B.6 TCC + entitlements (Mac)

| Entitlement | Path | Justification |
|---|---|---|
| `com.apple.security.accessibility` (granted via Accessibility prompt — not an entitlement; documented in Info.plist `NSAppleEventsUsageDescription`) | C | "OpenBurnBar uses macOS Accessibility to operate apps on your Mac during agent runs that you approve. The agent's actions are recorded in a tamper-evident audit log on your Mac and shown live on your paired iPhone." |
| `NSScreenCaptureUsageDescription` | A, B, C | Already shipped in Mercury Phase 3. Justification stays unchanged. |
| Hardened Runtime — `com.apple.security.cs.disable-library-validation` | B (Playwright spawn) | Required to launch the user-installed Playwright binary. Documented in App Store Connect notes. |

**Sandbox stance:** Path A and B are MAS-compatible if Playwright is delivered out-of-band (the user installs it; our app spawns it). Path C requires Accessibility, which **mandates direct distribution** (Apple does not allow sandboxed apps to request Accessibility). Phase 11 ships outside the Mac App Store; the MAS build hard-codes Path C off via a `#if DISTRIBUTION_MAS` flag.

---

## C. iOS / iPadOS implementation (OpenBurnBarMobile)

### C.1 New module `OpenBurnBarMobile/Services/ComputerUse/`

| File | Role |
|---|---|
| `AgentWatchReceiver.swift` (Path A) | Pairs with the Mac sender; ingests `control.surface.frame` (decoded by reusing `VideoReceivePipeline`) + `control.action.log` entries; publishes `AgentWatchState` (`@Observable`) with: `currentFrame`, `actionTimeline: [AgentAction]`, `pendingApproval: BurnBarApprovalRequest?`, `lastFiveAuditEntries`. |
| `AgentWatchOverlayCoordinator.swift` (Path A) | Drives the overlay above `ScreenShareViewerView`. Animates action chip from `.planning` → `.awaitingApproval` → `.executing` → `.complete` using `stripExpand` + `mercuryShimmer`. |
| `PhoneControlSender.swift` (Path D) | Translates SwiftUI tap/drag/keyboard events on `AgentWatchView` into `PhoneControlIntent` envelopes. Owns the monotonic counter (`UserDefaults.standard.integer(forKey: "phoneControl.counter.\(peerNodeId)")`) — incremented and persisted before each send. Signs with the iOS-side iroh Ed25519 key from `IrohPairingKeyStore`. |
| `PhoneControlOptionSheet.swift` (Path D) | Slide-up sheet during "Take over" mode. Tabs: Tap / Type / Shortcut. The Shortcut tab is a grid of common shortcuts (`⌘C`, `⌘V`, `⌘Z`, `⌘W`, `⌘Tab`, `⌘Space`, etc.); custom shortcut composer at the bottom. |
| `ComputerUseSessionState.swift` | Per-session state mirror of the Mac coordinator. Reads `hosted_computer_use_sync` Firestore entitlement only as a hint — the Mac is the actual gate (mirrors Mercury Decision 2). |

### C.2 New iOS UI surfaces — `OpenBurnBarMobile/Views/ComputerUse/`

| Surface | Spec |
|---|---|
| `AgentWatchView.swift` | Full-bleed display of `control.surface.frame` via `AVSampleBufferDisplayLayer` (same display path as `ScreenShareViewerView`). Overlay layers (top → bottom): (1) Top safe-area mercury hairline + session status (`Watching · Manual Mode · 02:42`), (2) bottom strip with three rows pinned to bottom safe-area: cost row (`monoTiny` "Spent: $0.47 · 38 actions"), planned-action row (`body` "Clicking 'Submit'..." with `mercuryShimmer`), approval row (Approve / Reject buttons, only when `pendingApproval != nil`). Three-finger long-press anywhere = panic halt; visual feedback is a screen-wide ember pulse. |
| `AgentActionTimelineSheet.swift` | Drag-up sheet over `AgentWatchView`. Editorial typography per `DESIGN.md` Editorial Observatory. 01/02/03 mono ordinals. Each entry: thumbnail (88×50 from local cache) + action description + timestamp + status pill. |
| `ComputerUseTrustModeBadge.swift` | Pinned chip in `AgentWatchView` upper-left showing current trust mode. Tap → sheet that lets the phone-side user **downgrade only** (Trusted → Step → Manual). Upgrading must happen on the Mac (Decision 2 enforcement). |
| `ComputerUseDeviceSheet.swift` | Settings → Computer Use (iOS). Shows paired Macs with current trust mode, last-session audit summary, "Forget pairing" per row. |

### C.3 iOS edits

- **`OpenBurnBarMobile/Services/IrohRelay/HermesIrohRelayTransport.swift`** — stream-class dispatch extended with `control.*`.
- **`OpenBurnBarMobile/Services/HermesService.swift`** — split `HermesCompositeRelayTransport` so chat + media + control are three sibling transports sharing one iroh connection.
- **`OpenBurnBarMobile/Info.plist`** — no new permissions (we don't need iOS Accessibility for the phone side; the phone is a viewer/controller, not the actor). Stays unchanged.
- **`OpenBurnBarMobile/Resources/PrivacyInfo.xcprivacy`** — no new entries (screenshots are decoded for display only, not stored).

### C.4 Android parity (Phase 11+)

Android follows iOS by one phase per `docs/ANDROID_NATIVE_PARITY_GOAL.md`. New module `android/app/src/main/java/com/openburnbar/ui/computeruse/` mirrors `OpenBurnBarMobile/Views/ComputerUse/`. Surface frames decoded via existing `VideoReceivePipeline.kt`. Phone-control intents signed via Tink Ed25519 (same library Android Mercury uses for pairing).

---

## D. UI/UX spec (Mercury Rising compliant)

All surfaces inherit from `DESIGN.md` § Hermes Mercury. **No new color axis. No new motion tokens.**

**Color tokens reused:** `hermesMercury`, `hermesAureate`, `mercuryGradient`, `ember`, `whimsy`, `surface`, `surfaceElevated`, `border`, `borderSubtle`, `error`, `success`, `textPrimary`, `textSecondary`, `textMuted`.

**Motion tokens reused:** `mercuryShimmer` (action-planning state on phone overlay), `mercuryPool` (vision-model thinking), `mercuryPulse` (live session indicator), `stripExpand` (approval sheet entry), `snappy` easeOut (Approve/Reject button press).

**Glass surfaces reused:** `GlassCard` (Mac session panel), `ChatBubbleStyle.toolShape` (audit-entry rows), `EditorialHero` (timeline sheet header).

### D.1 Mac session panel

```
┌─ ComputerUseSessionPanel — Settings → Computer Use ─────────────────────────┐
│  COMPUTER USE                                                               │
│  Last 30 days                                                               │
│  ────────────────────────────────────────────  (mercuryGradient, 1pt)       │
│                                                                             │
│  Trust mode                                                                 │
│  ┌──────────┐  ┌────────┐  ┌──────────┐                                     │
│  │ Manual ●│  │  Step  │  │ Trusted  │   (segmented pill, mercuryGradient   │
│  └──────────┘  └────────┘  └──────────┘    fill on active)                  │
│                                                                             │
│  Scope rules                                                                │
│  ┌─ github.com/owner/* ──────────────── allow ── 2026-05-16 ─── delete ─┐   │
│  │  com.apple.Calculator                allow                            │   │
│  │  com.apple.SecurityAgent             deny (built-in)                  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│  + Add scope rule                                                           │
│                                                                             │
│  Recent audit chain                                                         │
│   01  18:24:33  ●  browser.click   "Submit" — github.com         approved   │
│   02  18:24:42  ●  browser.fill    "title"  — github.com         approved   │
│   03  18:24:51  ✕  browser.goto    "evil.example"                rejected   │
│   04  18:24:58  ○  mac.input.click "OK" — Mail                   pending    │
│  ──────────────────────────────────────────────────────────────────────     │
│                                                                             │
│              ┌──────────────────────────────────────┐                       │
│              │     ⛔  PANIC STOP                   │  (error fill, display) │
│              └──────────────────────────────────────┘                       │
│                                                                             │
│  Audit · b3:7af2a8c4...               Local run · session 04:31 — 04:58     │
└─────────────────────────────────────────────────────────────────────────────┘
```

### D.2 Phone overlay (Agent Watch + intervention)

```
┌─ AgentWatchView (full bleed) ───────────────────────────────────────────────┐
│                                                                             │
│  Watching · Manual · 02:42                          Trusted mode ▼          │
│  ──── mercuryGradient hairline ────                                         │
│                                                                             │
│                                                                             │
│                  [live screen frame at 30 fps HEVC]                         │
│                          (Mac's Chromium window)                            │
│                                                                             │
│                                                                             │
│                  cursor mirrored at (827, 412) ──→                          │
│                                                                             │
│                                                                             │
│                                                                             │
│                                                                             │
│  ┌──── mercuryGradient hairline ────────────────────────────────────────┐   │
│  │  Spent  $0.47  ·  38 actions  ·  Avg $0.012/action                   │   │
│  │  Next   Clicking 'Submit' button — github.com/owner/repo/pulls/12    │   │
│  │  ┌──────────────┐                       ┌──────────────┐             │   │
│  │  │   Reject     │                       │   Approve    │             │   │
│  │  └──────────────┘                       └──────────────┘             │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────┐    │
│  │                  ↑ drag up for timeline                            │    │
│  └────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

Three-finger long-press anywhere → screen-wide ember pulse + `PANIC STOPPED` banner + Mac session terminates within 200 ms.

Top-right trust-mode chip taps → bottom sheet:

```
┌─ Downgrade trust ─────────────────────────────────────────────────────┐
│  You're currently in Trusted mode. Drop to:                           │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │  Step — every action needs Mac-side approval                 │    │
│  └──────────────────────────────────────────────────────────────┘    │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │  Manual — every action needs my approval here on the phone   │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                       │
│  To go back up, use the Mac.                                          │
└───────────────────────────────────────────────────────────────────────┘
```

### D.3 Mac approval sheet

```
┌─ ComputerUseApprovalSheet — 1pt mercuryGradient ──────────────────────┐
│                                                                       │
│   ┌──────────────────────────────────────────────────────────────┐   │
│   │                                                              │   │
│   │     [320 × 180 pre-action screenshot, borderSubtle stroke]   │   │
│   │                                                              │   │
│   └──────────────────────────────────────────────────────────────┘   │
│                                                                       │
│   Click 'Submit' button                                               │
│   github.com/owner/repo/pulls/12                                      │
│   selector  button[type='submit']                                     │
│   coords    (460, 812)                                                │
│                                                                       │
│   ┌───────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│   │   Reject + Halt   │  │      Reject      │  │     Approve      │  │
│   │   (error fill)    │  │  (error outline) │  │  (hermesAureate) │  │
│   └───────────────────┘  └──────────────────┘  └──────────────────┘  │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
```

`mercuryShimmer` sweeps across the Approve button on hover. `snappy` (0.15 s easeOut) on press.

### D.4 Audit timeline sheet (phone, drag-up from `AgentWatchView`)

Editorial typography per `DESIGN.md` Editorial Observatory:

```
┌──────────────────────────────────────────────────────────────────────┐
│   AUDIT TRACE                                                        │
│   Last 30 actions                                                    │
│   ────  mercuryGradient hairline                                     │
│                                                                      │
│   01  18:24:33  browser.click  "Submit"                              │
│       [88 × 50 thumbnail]   github.com/owner/repo/pulls/12           │
│                                                                      │
│   02  18:24:42  browser.fill   "title"                               │
│       [88 × 50 thumbnail]   github.com/owner/repo/pulls/12           │
│                                                                      │
│   03  18:24:51  browser.goto   "evil.example"  ✕ REJECTED            │
│                  reason: deny rule matched                           │
│                                                                      │
│   ...                                                                │
│                                                                      │
│   ──── mercuryGradient hairline                                      │
│   Chain integrity verified · b3:7af2a8c4 · 38 entries                │
└──────────────────────────────────────────────────────────────────────┘
```

### D.5 DESIGN.md addendum (decision log per phase)

Each phase appends to `DESIGN.md`'s decision log table:

| Date | Decision | Rationale |
|---|---|---|
| Phase 8 ship | Agent Watch reuses Mercury Phase 3 transport with cursor extension | Decision 4. No new transport plumbing; 4 extra bytes on existing codec header. |
| Phase 9 ship | Browser approval sheet uses `mercuryGradient` border with pre-action thumbnail | Pattern from Mercury attachment row, raises the bar with the thumbnail evidence. |
| Phase 10 ship | Trust modes shown as segmented pill in `ComputerUseSessionPanel` | Three options need at-a-glance comparison; pill is the macOS HIG-standard for tri-state selection. |
| Phase 11 ship | Audit chain panel uses `monoTiny` ordinals + status glyphs | Mirrors `IntelligenceBriefScreen.kt` Editorial Observatory pattern; auditing is a forensic activity, needs the editorial voice. |
| Phase 12 ship | Trust-mode downgrade from phone, upgrade only from Mac | Decision 2 enforcement; prevents a compromised phone session from elevating itself. |
| Phase 13 ship | Trusted-scope library lives in `ComputerUseSessionPanel`, not in chat | Scopes are infrastructure, not conversation; chat is the wrong surface for stable configuration. |

---

## E. Premium gating + quotas

### E.1 SKU strategy

| SKU | Product ID | Cost | Gates |
|---|---|---|---|
| `hosted_quota_sync` (existing) | `com.openburnbar.hostedQuotaSync.cloud.monthly` | $4.99/mo | Cloud quota sync, Hermes hosted relay |
| `hosted_media_sync` (existing) | `com.openburnbar.hostedMediaSync.monthly` | $9.99/mo | File transfer, screen share, video calling (Mercury) |
| `hosted_computer_use_sync` (NEW Phase 9) | `com.openburnbar.hostedComputerUseSync.monthly` | $14.99/mo | Browser CU + Mac CU + Phone control + audit export |
| `burnbar_pro_max` (NEW Phase 9 umbrella) | `com.openburnbar.proMax.monthly` | $24.99/mo | All three above |
| `burnbar_pro` (existing umbrella) | `com.openburnbar.pro.monthly` | $14.99/mo | `hosted_quota_sync` + `hosted_media_sync` (CU explicitly excluded) |

Entitlement document shape:
```
users/{uid}/entitlements/hosted_computer_use_sync:
  active: true
  productID: "com.openburnbar.hostedComputerUseSync.monthly"
  expireAt: <timestamp>
  features:
    browserComputerUse: true
    systemComputerUse: true
    phoneControl: true
    auditExport: true
    trustedScopes: true
```

**No grandfather grant** for existing `hosted_media_sync` subscribers (Decision 9). The cost asymmetry — vision-model spend per action is ~$0.013, compared to Mercury's ~$0.40/user-day relay max — makes blanket grandfathering unfeasible. Existing subscribers get a 14-day Computer Use trial on first launch of a build that includes Phase 9.

### E.2 Quota envelope (Firestore + local cache)

```
users/{uid}/computer_use_quota_usage/{YYYY-MM-DD}:
  browserActionsExecuted: int
  browserActionsRejected: int
  systemActionsExecuted: int
  systemActionsRejected: int
  phoneControlIntentsExecuted: int
  phoneControlIntentsRejected: int
  sessionsStarted: int
  sessionsCompleted: int
  totalSessionSeconds: int
  visionModelSpendUSD: float
  updatedAt: timestamp
```

Caps (normal mode):
- 200 actions/day (combined browser + system)
- 50 actions/run
- 30 min/session
- 4 sessions/day
- $5 vision-spend/day hard ceiling (per-user)

### E.3 Budget-aware auto-tightening

Cloud Function `evaluateComputerUseBudget` (scheduled hourly, `functions/src/computerUseBudget.ts`):
1. Reads vision-model spend from `users/*/computer_use_actions/*.visionTokensCost`.
2. Reads `ops/computer_use_session_daily_rollups/days/*` for the current month.
3. Projects month-end spend.
4. Writes `ops/computer_use_budget_status/state/current`:
   ```
   {
     level: "normal" | "soft_cap" | "hard_cap",
     projectedMonthEndUSD: number,
     monthToDateUSD: number,
     activeEnvelope: {
       actionsPerRun: number,
       actionsPerDay: number,
       sessionsPerDay: number,
       perUserDailySpendCeilingUSD: number
     }
   }
   ```
5. Soft cap (projected ≥ $1500/mo): envelope tightens to 25 actions/run · 100/day · 2 sessions/day · $2.50 ceiling.
6. Hard cap (projected ≥ $2500/mo): `computer_use_kill_switch = true` in Remote Config. All sessions terminate within 60 s.

### E.4 Enforcement (three layers, Decision 2 analog)

1. **Mac host gate (primary)** — `ComputerUseCapabilityGate.check(mode:trustMode:scope:)` reads `MacCloudEntitlementStore` + local quota counters + budget status. Returns `.allowed` / `.denied(.entitlement | .sessionLimit | .dailyLimit | .softCap | .hardCap | .scope | .denyRegion)`.
2. **Control-plane reconcile** — Mac writes `computer_use_quota_usage/{day}` every 30 s. Server-side `recomputeComputerUseQuotaUsage` Cloud Function corrects drift hourly.
3. **iroh accept-loop gate (secondary)** — on each new `control.*` stream open, Mac's accept-loop re-checks entitlement freshness (cached 60 s). Refuses streams if entitlement expired, daily cap hit, or kill-switch active. Sends `control.denied(reason)` and closes.

iOS-side check is informational only — surfaces the same `computer_use_budget_status` toast.

---

## F. Privacy & security

### F.1 Threat model

| Adversary | Vector | Mitigation |
|---|---|---|
| **A1: malicious page** convinces the agent to click destructive UI | Vision model misinterprets phishing page | Scope rules (URL prefix gate); deny registry (any URL matching `/admin`, `/billing`, `/oauth/authorize` shows mandatory approval even in Trusted mode) |
| **A2: compromised model** emits intent to click password field | Vision model outputs `(x, y)` over an `AXSecureTextField` | `MacAccessibilityInspector` reads role at point; deny matcher refuses click on `AXSecureTextField`, `AXSheet` with role-description "password" |
| **A3: peer tampering** of phone-control intent in transit | Adversary injects raw bytes into `control.input` stream | iroh-tls already encrypts the stream; Ed25519 signature on every intent envelope (`PhoneControlAuthority`); monotonic counter rejects replay |
| **A4: audit log tampering** for evidence destruction | Local attacker (or compromised process) edits a JSONL entry | Content-addressed hash chain (Decision 8); BLAKE3 parent link detects any edit; root hash exportable to an off-device timestamping service in Phase 13 |
| **A5: agent self-elevation** by clicking System Settings → Privacy → Accessibility | Agent tries to add itself to Accessibility allow-list to bypass approval | `loginwindow` + `SecurityAgent` + `System Settings` with frontmost panel = Privacy & Security all in built-in deny registry; cannot be removed via scope-rule editor |
| **A6: phone-controller hijack** by a stolen iPhone | Stolen phone with active iroh pairing | Pairing-rotate flow on every Mac unlock; phone-control session terminates on Mac lock; "Forget pairing" remotely from Settings → Devices |
| **A7: stale Trusted scope** persists across malicious update | User pre-approves `github.com/owner/repo` on Monday; on Tuesday a typosquatted page resembles the URL | Trusted scopes expire after 24 h or 50 actions, whichever first; phone displays remaining budget on every action |

### F.2 Info.plist (macOS)

- `NSAppleEventsUsageDescription`: "OpenBurnBar uses Accessibility to operate apps on your Mac during agent runs you approve. Every action is recorded in a tamper-evident audit log and shown live on your paired iPhone."
- `NSScreenCaptureUsageDescription`: already shipped — extends to include "OpenBurnBar mirrors this Mac to your paired iPhone or iPad during agent runs so you can watch and intervene from the phone."

iOS: **no new permissions**. The phone is a viewer/controller, not an actor.

### F.3 PrivacyInfo.xcprivacy

`NSPrivacyAccessedAPITypes` — no new entries beyond Mercury.
`NSPrivacyCollectedDataTypes`:
- `NSPrivacyCollectedDataTypeOtherUsageData` (action descriptors, no payloads) — Linked: false · Tracking: false · Purposes: `AppFunctionality`.

### F.4 App Store review notes addendum

> OpenBurnBar Computer Use lets a user run an AI agent that operates their Mac with explicit consent. Every action passes through an approval gate that the user sees on the Mac and (optionally) on their paired iPhone or iPad. The agent can be halted by global hotkey, by a three-finger gesture on the paired iPhone, or by locking the Mac. A tamper-evident audit chain records every action on-device. Path B (Browser Computer Use) is sandboxed inside Chromium and ships in the MAS build. Path C (System Computer Use) requires the macOS Accessibility permission and ships only via direct download with notarization; the MAS build hard-codes Path C off.

Pre-recorded reviewer walkthrough video link.

### F.5 Kill switches (Decision 7 detail)

| Source | Implementation |
|---|---|
| `⌃⌥⌘.` global hotkey | `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` filtered to keycode 47 + `[.command, .option, .control]`. Calls `ComputerUseSessionCoordinator.panicHalt(source: .hotkey)`. |
| Phone three-finger long-press | SwiftUI `.simultaneousGesture(LongPressGesture(minimumDuration: 0.8).onEnded(...))` with `numberOfTouchesRequired: 3` on `AgentWatchView`. Sends `PhoneControlIntent.panic` envelope. |
| Mac lock / fast user switch | `NSWorkspace.shared.notificationCenter` for `.screensDidSleep`, `.sessionDidResignActive`, `.didLaunchApplicationNotification` filtered to bundle id `com.apple.loginwindow`. |
| Remote Config | Firebase Remote Config listener on `computer_use_kill_switch` fires `panicHalt(source: .remoteConfig)`. 60 s cache TTL. |

All four converge in `ComputerUseSessionCoordinator.panicHalt(source:)`:
1. Cancel any in-flight action (Playwright driver killed via `SIGKILL`; pending `CGEventPost` aborted via early-return guard).
2. Append `panicHalted` entry to audit chain with source.
3. Tear down `control.*` streams within 200 ms.
4. Show modal sheet on Mac and phone: "Halted. Audit log saved."

---

## G. Observability

### G.1 Firebase Analytics events (bucketed, no payload)

| Event | Params |
|---|---|
| `cu_session_started` | `mode` (.agentWatch \| .browser \| .system), `trustMode` (.manual \| .step \| .trusted), `hasPhoneViewer` (bool) |
| `cu_session_ended` | `mode`, `trustMode`, `durationBucket` (<1m, 1-5m, 5-15m, 15-30m), `endReason` (.completed \| .userHalt \| .panic \| .timeout \| .entitlement \| .budget \| .error), `actionCountBucket` (0, 1-10, 11-50, 51-200), `approvalLatencyP95Bucket` |
| `cu_action_proposed` | `toolKind`, `mode`, `requiresApproval` (bool) |
| `cu_action_approved` | `toolKind`, `approvedBy` (.mac \| .phone \| .trustedScope), `approvalLatencyBucket` (<200ms, 200-500ms, 500ms-2s, >2s) |
| `cu_action_rejected` | `toolKind`, `rejectReason` (.user \| .scope \| .denyRegion \| .timeout \| .signatureFail) |
| `cu_action_executed` | `toolKind`, `executionLatencyBucket`, `hadError` (bool), `errorCategory` (.timeout \| .selectorMiss \| .axDenied \| .crash) |
| `cu_panic_halt` | `source` (.hotkey \| .phoneGesture \| .macLock \| .remoteConfig) |
| `cu_scope_violation` | `matchedRule` (hash of rule id, not URL), `attemptedToolKind` |
| `cu_audit_chain_validated` | `entryCount`, `validationSuccess` (bool) |

### G.2 Reuse `iroh_audit_events`

New `streamClass` values: `control.surface.frame`, `control.action.log`, `control.input`, `control.approval`. Always carried. BWE samples summarized at stream close.

### G.3 Server-side rollups

NEW Cloud Function `rollupComputerUseDaily` (`functions/src/computerUseMonitoring.ts`) mirrors `rollupMediaSessionDaily`. Reads `users/*/computer_use_actions/*` filtered by day. Outputs `ops/computer_use_daily_rollups/days/{YYYY-MM-DD}`: per-tool counts, p50/p95/p99 approval latency, scope-violation count, panic-halt count, vision-model spend.

### G.4 Budget monitor

`ops/computer_use_budget_status/state/current` is the canonical budget surface. Read by Mac + iOS at session start. Written hourly by `evaluateComputerUseBudget`. BigQuery export to Looker Studio dashboard `computer-use-budget`.

### G.5 On-device audit-chain validator

A pure SwiftPM library (`OpenBurnBarComputerUseCore.ComputerUseAuditChain.validate(at: URL) -> ValidationResult`) walks the JSONL file and re-hashes. Surface in Mac UI: Settings → Computer Use → "Validate audit chain". Result: green check + "All 47 entries cryptographically linked" or red cross + "Tamper detected at entry 23 (parent hash mismatch)".

Phase 13 ships an optional "Notarize chain" feature that submits the root hash to an off-device timestamping service (e.g., OpenTimestamps) for non-repudiable proof of session existence.

---

## H. Phasing

Phase numbers continue the Mercury Media plan's phasing (1–7). Computer Use phases are 8–13.

Each phase exits with: tests green · `docs/HERMES_COMPUTER_USE.md` updated · `CHANGELOG.md` entry · `DESIGN.md` decision-log entry · `docs/runbooks/computer-use-rollout-status.md` entry · ≥ 7-day soak before next phase's flag flips on for > 5% of users.

| Phase | Theme | Flag | Duration | Dependency |
|---|---|---|---|---|
| 8 | **Agent Watch** (Path A — read-only) over `control.surface.frame` + `control.action.log` | `computer_use_watch_enabled` | ~2 weeks | Mercury Phase 3 ≥ 95% success |
| 9 | **Browser Computer Use** (Path B — Manual mode only) + `hosted_computer_use_sync` SKU launch | `computer_use_browser_enabled` | ~4 weeks | Phase 8 + Playwright lifecycle |
| 10 | **Trust modes + scope rules + audit chain** (Manual / Step / Trusted; deny registry; hash-chain logger) | `computer_use_trust_modes_enabled` | ~2 weeks | Phase 9 |
| 11 | **Mac Computer Use** (Path C — CGEvent + AX + Accessibility prompt) | `computer_use_system_enabled` | ~5 weeks | Phase 10 + ≥ 14-day Phase 9 soak |
| 12 | **Phone-as-controller** (Path D — `control.input` with Ed25519 signed envelopes) | `computer_use_phone_control_enabled` | ~3 weeks | Phase 11 |
| 13 | **Polish: Trusted-scope library, audit export, scope-expiry, OpenTimestamps notarization** | `computer_use_polish_enabled` | ~2 weeks | Phase 12 |

**Total:** ~18 weeks of engineering. Plus ≥ 14-day soak between Phase 9 → Phase 11 (the highest-risk transition — browser → full Mac).

---

## I. Tests (project-wide)

### I.1 Unit tests (per-platform)

| Module | Targets |
|---|---|
| `ComputerUseScopeMatcher` | URL prefix match, bundle-id wildcard, window-title regex, deny-rule precedence, overlap detection |
| `ComputerUseAuditChain` | Parent-hash chain integrity, tamper detection at every position, canonical-JSON serialization stability across Swift compiler versions |
| `ComputerUseCapabilityGate` | Entitlement-missing, expired, daily-cap, session-cap, soft-cap, hard-cap, deny-region |
| `MacInputController` | Event-creation round-trip (post and assert payload via mock), display-bounds validation, AXIsProcessTrusted gate |
| `MacAccessibilityInspector` | Role-at-point on mock UI element tree, password-field detection, descendant search |
| `OpenBurnBarPlaywrightDriver` | JSON-RPC framing, action timeout, selector-resolution failure mapping, lifecycle (start → action → stop), crash recovery |
| `PhoneControlAuthorityValidator` | Ed25519 signature verify, monotonic counter, freshness window, intent-hash match |
| `PhoneControlNormalizedCoord` | Frame size → display coord transform (multi-monitor, retina), bounds clamping |
| `ComputerUsePanicHaltCoordinator` | Hotkey registration, NSWorkspace listener wiring, all-paths-converge-on-coordinator contract |
| `ComputerUseBudgetEnvelope` | Soft/hard cap level transitions, projected month-end calculation |

### I.2 Integration tests

| Test | Scope |
|---|---|
| `MediaLoopbackAgentWatch` | Single-process iroh loopback; fake agent emits 10 actions; phone overlay reflects all 10 within 200 ms each |
| `BrowserComputerUseSmokeTests` | Spawn Playwright in CI; deterministic mini-scenario (open about:blank → fill input → click button → assert state); audit chain validates |
| `MacInputLoopbackTests` | Calculator scripted scenario via NSWorkspace + AX; type 2+2, read result; tagged `@requiresAccessibility`, skipped in CI without permission |
| `PhoneControlLoopbackTests` | Fake iOS sender + fake Mac receiver; assert intent → CGEvent translation within 1 px tolerance |
| `ApprovalCrossDeviceTests` | XCUITest: Mac sends approval request; phone simulator receives + approves; Mac run proceeds |

### I.3 Chaos tests

| Test | Scenario | Expected |
|---|---|---|
| `ChaosBrowserActionTimeout` | Playwright hangs on selector | Driver kills page within 10 s; audit entry records failure |
| `ChaosScopeViolation` | Agent emits `browser.goto` to deny-listed URL | Request rejected without approval prompt; audit entry recorded; agent run continues with error |
| `ChaosPanicHaltMidAction` | Halt during `mac.input.click` execution | CGEvent post aborts via early-return; driver killed; audit `panicHalted` entry written within 200 ms |
| `ChaosAccessibilityRevokedMidRun` | Revoke AX permission during active System session | Run terminates within 3 s; modal sheet shown; audit entry `accessibilityRevoked` |
| `ChaosPhoneControlReplay` | Replay an already-used `PhoneControlAuthority` envelope | Receiver rejects on counter check; audit entry `replayRejected` |
| `ChaosPhoneControlTamper` | Modify intent JSON without re-signing | Signature mismatch; receiver rejects |
| `ChaosAuditChainTamper` | Edit a middle entry on disk | `ComputerUseAuditChain.validate` returns failure with entry index |
| `ChaosSoftCapEngages` | Manually flip `computer_use_budget_status` to soft_cap mid-session | Envelope tightens for next session; current session continues to its 50-action cap |
| `ChaosHardCapEngages` | Manually flip to hard_cap | Active session terminates within 60 s; modal sheet shown |
| `ChaosLockScreenDuringSession` | Mac lock during active CU session | Session terminates within 100 ms; audit entry `macLocked` |

### I.4 Device matrix

| Device | Phase 8 (watch) | Phase 9 (browser) | Phase 11 (system) | Phase 12 (control) |
|---|---|---|---|---|
| iPhone 13 mini | ✓ receive | ✓ approve | ✓ approve | ✓ control |
| iPhone 17 Pro Max | ✓ | ✓ | ✓ | ✓ |
| iPad mini 6 | ✓ | ✓ | ✓ | ✓ |
| iPad Pro M4 | ✓ | ✓ | ✓ | ✓ |
| Mac Intel Core i7 (Skylake+) | ✓ encode | ✓ Playwright | ✓ CGEvent | ✓ receive |
| Mac M1 | ✓ | ✓ | ✓ | ✓ |
| Mac M3 / M4 | ✓ | ✓ | ✓ | ✓ |

Per device per phase: 10 scripted scenarios (sample: GitHub PR triage, Gmail search-and-archive, Calculator math, Mail-compose-but-don't-send). Record p50/p95 latency, error rate, panic-halt latency into `docs/runbooks/computer-use-device-matrix/{phase}.md`.

---

## J. Risks (ranked) + mitigations

1. **Vision model clicks the wrong destructive UI element.** Mitigated by: (a) AX deny matcher refuses password fields and known dangerous bundles, (b) per-session scope rules constrain agent reach, (c) Manual approval gates every action by default, (d) approval sheet shows pre-action screenshot so the human sees what's about to happen, (e) `Reject + Halt` button on the approval sheet for immediate kill.

2. **Accessibility permission revoked mid-run.** Mitigated by: `AXIsProcessTrusted()` polled every 5 s + on `NSWorkspace.didActivateApplicationNotification` (which fires on Privacy pane changes). Revocation → `panicHalt(source: .accessibilityRevoked)` within 3 s.

3. **Playwright version drift.** Pin `playwright@1.49.x` in `OpenBurnBarPlaywrightLifecycle.swift`. Verify SHA256 checksum after install. CI nightly job re-verifies install on a fresh runner.

4. **App Store rejection of Path C.** Outside-MAS direct distribution. MAS build has Path C compiled out via `#if DISTRIBUTION_MAS`. Document signing identity in `docs/runbooks/computer-use-app-store.md`.

5. **Token-cost blowout on vision context.** Decision 10 caps context per turn. `evaluateComputerUseBudget` projects month-end every hour. Soft cap at $1500, hard cap at $2500. Per-user $5/day ceiling enforces fairness.

6. **Phone-controller replay / forge attacks.** Ed25519 signature + monotonic counter + 5 s freshness window per Decision 5 / A.4. Counter persisted in `UserDefaults` per peer; reset on pairing rotate.

7. **AX inspector latency spikes (large UI trees).** Cache per-window snapshots 200 ms. Pre-warm on `NSWorkspace.didActivateApplicationNotification`. Fallback: if AX query > 500 ms, fall back to "Unknown element at (x,y)" in approval copy and rely on screenshot for the user's decision.

8. **Audit log size explosion.** Default 30-day rolling retention. User opt-in to longer retention in Settings → Computer Use → Advanced. Compression: gzip rotation every 1 MB.

9. **Coordination overhead with Mercury rollout.** Phase 8 explicitly gated on Mercury Phase 3 ≥ 95% success for 7 days. Each subsequent CU phase requires no Mercury regression.

10. **Selector resolution misses on dynamic pages (Phase 9).** Playwright handles most cases; for SPAs with shadow DOMs, the agent gets a `selector_not_found` error and is prompted to use `browser.extract` to query structure first. The vision model is encouraged to use coordinate-based clicks (via `browser.click({position: {x, y}})`) when selectors fail.

11. **Trusted-scope drift / outdated approval.** Scopes expire after 24 h or 50 actions (Decision 9 threat A7). Phone overlay shows remaining scope budget on every action.

12. **iroh accept-loop race on control + media + chat streams.** Already constant-time dispatch in `IrohRelayRequestHandler.serve()` (verified by Mercury rollout). New `control.*` types add 4 cases to the existing switch — no algorithmic complexity change.

---

## K. Files-to-touch inventory

### Shared SwiftPM (`OpenBurnBarCore/Sources/`)
- **NEW** `OpenBurnBarComputerUseCore/` target — see §B.1
- **NEW** `OpenBurnBarComputerUseCoreTests/` target
- **EDIT** `OpenBurnBarCore/Package.swift` — register new target with `OpenBurnBarMedia` dependency
- **EDIT** `OpenBurnBarMedia/MediaStreamClass.swift` — four new constants + `.computerUse` Feature case
- **EDIT** `OpenBurnBarCore/SharedModels/HermesRealtimeRelayTypes.swift` — four new frame types + `HermesRealtimeRelayControlPayload`
- **EDIT** `OpenBurnBarCore/Contracts/BurnBarToolContracts.swift` — 13 new `BurnBarToolKind` cases
- **EDIT** `OpenBurnBarCore/Contracts/BurnBarConnectorContracts.swift` — 7 new `BurnBarBrowserActionKind` cases + `BurnBarBrowserActionArguments`
- **NEW** `OpenBurnBarCore/Contracts/BurnBarComputerUseContracts.swift` — RPC contracts

### macOS daemon (`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/`)
- **NEW** `ComputerUse/OpenBurnBarPlaywrightDriver.swift`
- **NEW** `ComputerUse/OpenBurnBarPlaywrightLifecycle.swift`
- **NEW** `ComputerUse/ComputerUseRunCoordinator.swift`
- **NEW** `ComputerUse/ComputerUseService.swift` (socket RPC)
- **EDIT** `OpenBurnBarDaemonServer.swift` — register `ComputerUseService`
- **EDIT** `OpenBurnBarBrowserToolService.swift` — dispatch 7 new action kinds via Playwright driver
- **EDIT** `BurnBarRunService+Execution.swift` — route CU tool invocations through coordinator

### macOS app (`AgentLens/Services/ComputerUse/` — NEW directory)
- `ComputerUseSessionCoordinator.swift` · `ComputerUseCapabilityGate.swift` · `AgentWatchHUDSession.swift` · `BrowserActionDispatcher.swift` · `MacActionDispatcher.swift` · `Mac/MacInputController.swift` · `Mac/MacAccessibilityInspector.swift` · `Mac/MacComputerUseDenyRegions.swift` · `Mac/MacScreenshotService.swift` · `PhoneControlReceiver.swift` · `PhoneControlAuthorityValidator.swift` · `ComputerUsePanicHaltCoordinator.swift` · `ComputerUseAuditLogger.swift` · `ComputerUseSessionLogger.swift`

### macOS edits
- **EDIT** `AgentLens/Services/IrohRelay/HermesIrohRelayHostClient.swift` — stream-class fanout for `control.*`
- **EDIT** `AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift` — handle four new frame types
- **EDIT** `AgentLens/Services/IrohRelay/HermesRelayHostFanout.swift` — multiplex control streams
- **EDIT** `AgentLens/Services/SettingsManager.swift` — six new flags + kill-switch listener
- **EDIT** `AgentLens/Services/MacCloudEntitlementStore.swift` — `hostedComputerUseEntitlement` publisher
- **EDIT** `AgentLens/Services/Media/ScreenCapturePipeline.swift` — accept optional `windowID: CGWindowID` configuration; pass through to `SCContentFilter(desktopIndependentWindow:)`
- **EDIT** `AgentLens/App/AgentLensApp.swift` — global hotkey registration

### macOS UI (`AgentLens/Views/ComputerUse/` — NEW directory)
- `ComputerUseSessionPanel.swift` · `ComputerUseApprovalSheet.swift` · `ComputerUseSetupWizard.swift` · `ComputerUseScopeRuleEditor.swift` · `AgentWatchControlStrip.swift` · `ComputerUseIndicator.swift`
- **EDIT** `AgentLens/Views/Media/MediaPermissionsView.swift` — add Computer Use capability card
- **EDIT** `AgentLens/Views/Settings/SettingsView.swift` — register Computer Use settings tab
- **EDIT** `AgentLens/Views/Popover/PopoverQuickSwitchView.swift` — "Watch on phone" affordance

### iOS (`OpenBurnBarMobile/Services/ComputerUse/` — NEW directory)
- `AgentWatchReceiver.swift` · `AgentWatchOverlayCoordinator.swift` · `PhoneControlSender.swift` · `PhoneControlAuthorityIssuer.swift` · `ComputerUseSessionState.swift`

### iOS UI (`OpenBurnBarMobile/Views/ComputerUse/` — NEW directory)
- `AgentWatchView.swift` · `AgentActionTimelineSheet.swift` · `PhoneControlOptionSheet.swift` · `ComputerUseTrustModeBadge.swift` · `ComputerUseDeviceSheet.swift`

### iOS edits
- **EDIT** `OpenBurnBarMobile/Services/IrohRelay/HermesIrohRelayTransport.swift` — stream-class dispatch
- **EDIT** `OpenBurnBarMobile/Services/HermesService.swift` — sibling `ControlRelayTransport`
- **EDIT** `OpenBurnBarMobile/Views/Settings/SettingsHubView.swift` — register Computer Use section

### Android (Phase 11+ parity)
- **NEW** `android/app/src/main/java/com/openburnbar/data/computeruse/` — receiver, sender, signer, state mirror
- **NEW** `android/app/src/main/java/com/openburnbar/ui/computeruse/` — AgentWatchActivity, AgentWatchOverlay, PhoneControlSheet
- **EDIT** `android/app/src/main/java/com/openburnbar/data/media/VideoReceivePipeline.kt` — accept `control.surface.frame` with cursor metadata

### Cloud Functions (`functions/src/`)
- **NEW** `computerUseMonitoring.ts` — `rollupComputerUseDaily`
- **NEW** `computerUseQuota.ts` — `recomputeComputerUseQuotaUsage`
- **NEW** `computerUseBudget.ts` — `evaluateComputerUseBudget`
- **EDIT** `types.ts` — `ComputerUseSessionDoc`, `ComputerUseActionDoc`, `ComputerUseAuditHeaderDoc`, `ComputerUseBudgetStatusDoc`
- **EDIT** `index.ts` — exports

### Rules
- **EDIT** `firestore.rules` — gate `users/{uid}/computer_use_sessions`, `users/{uid}/computer_use_actions`, `users/{uid}/computer_use_quota_usage/{day}`, `users/{uid}/entitlements/hosted_computer_use_sync`, `ops/computer_use_budget_status/{doc}`. Helper `hasActiveHostedComputerUseEntitlement(userId)` mirrors existing pattern.

### Design + docs
- **EDIT** `DESIGN.md` — "Computer Use" subsection (session panel, approval sheet, agent-watch overlay, decision log per phase)
- **EDIT** `docs/HERMES_IROH_TRANSPORT.md` — "Control stream classes" section
- **NEW** `docs/HERMES_COMPUTER_USE.md` — operator/engineer reference
- **NEW** `docs/runbooks/computer-use-quota.md` — quota disputes, manual reset
- **NEW** `docs/runbooks/computer-use-budget.md` — soft/hard cap operations
- **NEW** `docs/runbooks/computer-use-rollout-status.md` — phase log mirroring `media-rollout-status.md`
- **NEW** `docs/runbooks/computer-use-device-matrix/` — per-phase device-matrix results
- **NEW** `docs/runbooks/computer-use-app-store.md` — MAS vs direct-download distribution playbook
- **EDIT** `AGENTS.md` — Add "Computer Use" to repo capability matrix
- **EDIT** `CHANGELOG.md` — entry per phase ship

### CI / Tooling
- **NEW** `scripts/test-computer-use-loopback.sh` — runs the loopback suites against a CI runner
- **NEW** `scripts/install-playwright.sh` — reproducible recipe used by `OpenBurnBarPlaywrightLifecycle`
- **NEW** `.github/workflows/computer-use-loopback-test.yml` — runs on `macos-14-large`

---

## Per-phase implementation specs

---

### Phase 8 — Agent Watch (Path A, read-only)

**Goal:** smallest end-to-end slice — a real agent run on the Mac mirrors to a paired iPhone, complete with planned-action overlay and pending-approval row. No agent input control yet; the user still approves on the Mac.

**Flag:** `computer_use_watch_enabled`. Off by default.
**Duration estimate:** ~2 weeks.

**Inclusion:**
- Cursor extension to `MediaPacketCodec` (Decision 4, §A.3). 4 extra bytes per frame; flag bit `kHasCursorMetadata = 0x04`. Old peers ignore.
- New stream class `control.surface.frame` (alias of `media.screen.video` with cursor flag set) + `control.action.log` (JSON envelope per action).
- `AgentWatchHUDSession.swift` (Mac) — opens both streams via existing `MediaSessionCoordinator.startScreenShare()` with a `streamClassOverride` parameter.
- `AgentWatchActionPublisher.swift` (Mac) — subscribes to `BurnBarRunJournalEvent`, emits `AgentAction { kind, summary, status, screenshotHash? }`.
- `AgentWatchReceiver.swift` (iOS) + `AgentWatchView.swift` (full-bleed mirror + bottom strip).
- "Watch on phone" mercury-bordered button in Mac popover header (`AgentWatchControlStrip.swift`).
- Phone-side approval row is **visual only** in Phase 8 (taps show "Approve on Mac" toast); actual cross-device approval ships in Phase 12.

**Cloud / rules:** No new schema. Reuses `media_session_events` with a `mode: agentWatch` discriminator.

**Privacy:** No new permissions beyond Mercury Phase 3.

**Tests:**
- Unit: `MediaPacketCodecTests` adds cursor round-trip case (≥ 4 new assertions). `AgentWatchActionPublisherTests` covers journal → publisher contract (≥ 6 cases).
- Integration: `MediaLoopbackAgentWatch` — fake agent emits 10 actions; assert phone overlay reflects all 10 within 200 ms each.
- Manual: real Mac (M3) running a benign CLI agent task → real iPhone shows live frame + action overlay across LAN and LTE.

**Docs:**
- NEW `docs/HERMES_COMPUTER_USE.md` skeleton (Phase 8 details).
- NEW `docs/runbooks/computer-use-rollout-status.md` (Phase 8 entry).
- `CHANGELOG.md`: `feat(cu): agent-watch read-only mirror — Phase 8 (off by default)`.
- `DESIGN.md` decision-log: "Phase 8 agent-watch reuses Mercury Phase 3 transport; cursor coords embedded in codec header."

**Acceptance gate:**
1. CI workflow `computer-use-loopback-test` green.
2. `swift test --filter ComputerUseCore` green (≥ 10 new tests).
3. TestFlight build: 5 consecutive runs of "agent triages 3 emails via Mail" task display correctly on iPhone across LAN + LTE.
4. `iroh_audit_events` exports under `docs/runbooks/computer-use-rollout-status.md` showing expected `control.surface.frame` + `control.action.log` open/close, zero `iroh_fallback_to_wss`.

**Out of scope (Phase 9+):**
- Agent input control · approval cross-device · trust modes · audit chain · scope rules.

---

### Phase 9 — Browser Computer Use (Path B, Manual mode)

**Goal:** the agent can drive a Playwright Chromium window; every action gates through `BurnBarApprovalRequest` on the Mac; phone overlay shows the same approval prompt (visual only — approve still on Mac).

**Flag:** `computer_use_browser_enabled`.
**Duration estimate:** ~4 weeks.

**Inclusion:**
- 13 new `BurnBarToolKind` cases (browser-prefixed) + 7 new `BurnBarBrowserActionKind` cases (Path B subset).
- `OpenBurnBarPlaywrightDriver.swift` + `OpenBurnBarPlaywrightLifecycle.swift` (first-launch install if missing).
- `BrowserActionDispatcher.swift` (Mac) — routes tool invocations through driver with approval gate.
- `ComputerUseApprovalSheet.swift` (Mac) — pre-screenshot + action summary + Approve/Reject/Halt.
- `hosted_computer_use_sync` SKU launch in App Store Connect.
- `ComputerUseCapabilityGate` enforces entitlement + per-day/per-run/per-session caps.
- Vision-model planner integration: new system prompt template at `OpenBurnBarDaemon/Resources/Prompts/browser-computer-use.txt`. Default planner: Claude Sonnet 4.5; configurable in Settings → Computer Use → Advanced.

**Cloud / rules:**
- NEW `functions/src/types.ts` types: `ComputerUseSessionDoc`, `ComputerUseActionDoc`, `ComputerUseEntitlementDoc`.
- NEW `functions/src/computerUseQuota.ts` (`recomputeComputerUseQuotaUsage`).
- EDIT `firestore.rules` — gate three new collections.

**Privacy:** macOS `NSAppleEventsUsageDescription` added (text in §F.2) — even though we're not using AppleEvents directly in Phase 9, the wording covers future System mode and the prompt is benign. App Store re-submission required.

**Tests:**
- Unit: `OpenBurnBarPlaywrightDriverTests` (mock subprocess, action timeout, selector resolution). `BrowserActionDispatcherTests` (approval gate, scope-violation rejection, audit-entry emission).
- Integration: `BrowserComputerUseSmokeTests` — 5 deterministic scenarios (Wikipedia search, GitHub repo navigation, form fill, multi-page flow, error recovery). Each scenario must complete 5/5 runs.
- Chaos: `ChaosBrowserActionTimeout`, `ChaosScopeViolation`, `ChaosPanicHaltMidAction`.
- Device matrix: per §I.4 Phase 9 row. 10 scenarios per device.
- Manual: 100 TestFlight users; ≥ 95% scripted-scenario completion.

**Docs:**
- `docs/HERMES_COMPUTER_USE.md` — full Browser CU section.
- NEW `docs/HOSTED_COMPUTER_USE_SYNC.md` — SKU details.
- `DESIGN.md` decision-log: "Browser approval sheet uses pre-screenshot + selector text; Approve/Reject/Halt buttons; mercuryGradient border."
- `docs/runbooks/computer-use-device-matrix/phase-9.md`.
- `CHANGELOG.md` entry.

**Acceptance gate:**
1. App Store Connect new SKU live in production.
2. ≥ 95% scripted-scenario completion across 50 runs per device.
3. Audit-chain validation green on every test run.
4. Panic halt latency ≤ 200 ms p95 (asserted in `ChaosPanicHaltMidAction`).
5. Vision-model spend per typical run ≤ $1.50 (asserted by `evaluateComputerUseBudget` simulation).
6. ≥ 12 new unit tests + ≥ 5 integration scenarios green.
7. 7-day soak with flag on for internal users; ≤ 2% panic-halt rate (signal that the agent is misbehaving).
8. App Store re-submission accepted with `NSAppleEventsUsageDescription`.

**Out of scope (Phase 10+):**
- Step/Trusted modes · scope rules · audit chain export · phone-side approval · Mac System mode.

---

### Phase 10 — Trust modes + scope rules + audit chain

**Goal:** the trust-and-audit infrastructure that makes Path C safe to ship.

**Flag:** `computer_use_trust_modes_enabled`.
**Duration estimate:** ~2 weeks.

**Inclusion:**
- `ComputerUseTrustMode` field added to `ComputerUseSessionDoc` (default `.manual`).
- `ComputerUseScopeRule` schema + `ComputerUseScopeRuleEditor.swift` Mac UI.
- `ComputerUseDenyRegistry` hard-coded defaults (12 entries: lock screen, password fields, Keychain Access, etc.).
- `ComputerUseAuditChain` + `ComputerUseAuditLogger` + on-disk JSONL with parent-hash links.
- `ComputerUseSessionPanel.swift` Mac surface — trust mode picker, scope-rule list, audit-chain preview, "Panic stop" button.
- Step-mode burst approval — Mac approval sheet adds "Approve next 10 actions like this" toggle (defaults off).
- "Validate audit chain" button in Settings.

**Cloud / rules:**
- `ComputerUseSessionDoc.trustMode` added to schema validation.
- `ComputerUseActionDoc.parentEntryBlake3` field added.

**Privacy:** No new permissions.

**Tests:**
- Unit: `ComputerUseScopeMatcherTests` (≥ 15 cases including deny-precedence). `ComputerUseAuditChainTests` (golden fixtures: 100-entry valid chain, single-entry tampered chain, gap-detection).
- Integration: full Phase 9 scenarios re-run in Step and Trusted modes; assert action count + approval count + audit chain length.
- Chaos: `ChaosScopeViolation`, `ChaosAuditChainTamper`.
- Manual: 50 internal-user TestFlight runs across all three trust modes.

**Docs:**
- `DESIGN.md` decision-log: "Trust modes shown as segmented pill; downgrade from phone OK, upgrade only from Mac."
- `docs/HERMES_COMPUTER_USE.md` — trust-mode section.
- `docs/runbooks/computer-use-quota.md` — quota dispute flow uses audit-chain export.
- `CHANGELOG.md` entry.

**Acceptance gate:**
1. Audit chain validates on 100/100 test runs.
2. Tamper detection: golden-fixture test catches single-byte modification at every entry position.
3. Step-mode burst approval respects 10-action / 30-s ceiling.
4. Trusted-mode actions outside any active scope rule fall back to Manual approval (asserted in integration test).
5. 7-day soak; zero unintended Trusted-mode escapes.

**Out of scope (Phase 11+):**
- Mac CGEvent · phone-side approval · scope expiry · OpenTimestamps notarization.

---

### Phase 11 — Mac Computer Use (Path C, CGEvent + AX)

**Goal:** the agent operates the whole Mac. Accessibility permission flow, AX deny matcher, full-display screen capture (already shipped via Mercury Phase 3 — just configure ScreenCaptureKit for full display instead of single window), `MacInputController` synthesizing CGEvents.

**Flag:** `computer_use_system_enabled`.
**Duration estimate:** ~5 weeks.
**Dependency:** Phase 10 + ≥ 14-day Phase 9 soak with ≥ 95% success rate.

**Inclusion:**
- `MacInputController.swift` (CGEvent wrapper).
- `MacAccessibilityInspector.swift` (AX tree reader).
- `MacComputerUseDenyRegions.swift` (built-in 12-entry deny list + AX-based password-field detection at point).
- `MacActionDispatcher.swift` — routes 5 new `BurnBarToolKind.macInput*` cases.
- Accessibility permission prompt in `ComputerUseSetupWizard`.
- MAS-build flag (`#if DISTRIBUTION_MAS`) hard-codes System mode off.
- Direct-download distribution channel + notarization workflow (separate scripts/runbook).

**Cloud / rules:** No new schema.

**Privacy:**
- `NSAppleEventsUsageDescription` (Phase 9) becomes functionally exercised.
- `com.apple.security.cs.disable-library-validation` Hardened Runtime entitlement (Playwright already requires this in Phase 9).
- Direct-download notarized build signed with developer ID.

**Tests:**
- Unit: `MacInputControllerTests` (event creation, display bounds), `MacAccessibilityInspectorTests` (role at point, secure-field detection).
- Integration: `MacInputLoopbackTests` — Calculator and TextEdit scripted scenarios (tagged `@requiresAccessibility`).
- Chaos: `ChaosAccessibilityRevokedMidRun`, `ChaosLockScreenDuringSession`.
- Device matrix: per §I.4 Phase 11 row.
- Manual: 50 internal-user TestFlight runs of System-mode scenarios.

**Docs:**
- `docs/HERMES_COMPUTER_USE.md` — full System mode section.
- NEW `docs/runbooks/computer-use-app-store.md` — MAS vs direct-download distribution playbook.
- `DESIGN.md` decision-log: "Audit-chain panel uses Editorial Observatory ordinal pattern."
- `docs/runbooks/computer-use-device-matrix/phase-11.md`.
- `CHANGELOG.md` entry.

**Acceptance gate:**
1. Accessibility permission flow ≥ 95% completion in TestFlight survey.
2. Calculator scripted scenario completes 50/50 runs.
3. TextEdit "compose, format, save" scenario completes 50/50 runs.
4. Deny-region matcher catches all 12 listed deny scenarios.
5. Panic halt latency ≤ 200 ms p95 even mid-CGEvent-post.
6. Direct-download notarized build verified via `spctl --assess`.
7. MAS build verified to compile with `DISTRIBUTION_MAS` flag and have System mode invisible in Settings.
8. 14-day soak; zero unauthorized actions (defined as: action executed without matching approval or scope rule).

**Out of scope (Phase 12+):**
- Phone-controller intervention · Trusted-scope library · OpenTimestamps.

---

### Phase 12 — Phone-as-controller (Path D)

**Goal:** the phone can intervene — tap to click, type to send keystrokes, drag to scroll, halt to stop. Phone-side approval of agent actions becomes functional.

**Flag:** `computer_use_phone_control_enabled`.
**Duration estimate:** ~3 weeks.

**Inclusion:**
- `control.input` stream class (§A.1) + `PhoneControlAuthority` envelope (§A.4).
- `PhoneControlSender.swift` + `PhoneControlAuthorityIssuer.swift` (iOS) — signs intents with iOS-side iroh Ed25519 key.
- `PhoneControlReceiver.swift` + `PhoneControlAuthorityValidator.swift` (Mac) — validates sig + counter + freshness + intent-hash.
- "Take over" toggle on `AgentWatchView` (iOS).
- `PhoneControlOptionSheet.swift` — slide-up sheet for Type / Shortcut input.
- Cross-device approval: `control.approval` stream functional. Phone Approve button completes the same `BurnBarApprovalRequest` ID the run is awaiting (first responder wins; the other surface updates to "Approved by phone").
- Trust-mode downgrade from phone (Decision 2): tapping the trust-mode chip on `AgentWatchView` opens a sheet that lets the phone-side user drop Trusted → Step or Manual. Upgrade still Mac-only.

**Cloud / rules:** `PhoneControlAuthority` counter rotates on `iroh_pairing` rotation — extend existing rotation flow.

**Privacy:** No new permissions.

**Tests:**
- Unit: `PhoneControlAuthorityValidatorTests` (sig, counter, freshness, intent-hash — ≥ 20 cases), `PhoneControlNormalizedCoordTests` (multi-monitor, retina).
- Integration: `PhoneControlLoopbackTests` — fake iOS sender + fake Mac receiver, 1 px tolerance assertion. `ApprovalCrossDeviceTests` — Mac requests approval, phone approves, Mac proceeds.
- Chaos: `ChaosPhoneControlReplay`, `ChaosPhoneControlTamper`.
- Device matrix: per §I.4 Phase 12 row. Each device sends 100 intents; latency p95 measured.
- Manual: 30-min pair-debug session with one person at Mac, one at phone.

**Docs:**
- `docs/HERMES_COMPUTER_USE.md` — phone-controller section.
- `DESIGN.md` decision-log: "Phone-side trust-mode downgrade only; upgrade from Mac only."
- `docs/runbooks/computer-use-device-matrix/phase-12.md`.
- `CHANGELOG.md` entry.

**Acceptance gate:**
1. Tap-to-CGEventPost latency ≤ 200 ms p95 across device matrix.
2. Zero replay-success attempts in 1000-event chaos run.
3. Zero unsigned-intent accepts in 100-event chaos run.
4. Cross-device approval round-trip ≤ 500 ms p95.
5. Trust-mode downgrade from phone effective within 1 s.
6. 7-day soak; ≤ 1% phone-controller error rate.

**Out of scope (Phase 13):**
- Trusted-scope library · Scope expiry · OpenTimestamps notarization · Audit export.

---

### Phase 13 — Polish: Trusted-scope library, audit export, OpenTimestamps

**Goal:** the long-tail features that make Computer Use real-world durable.

**Flag:** `computer_use_polish_enabled`.
**Duration estimate:** ~2 weeks.

**Inclusion:**
- **Trusted-scope library:** Settings → Computer Use → "Saved scopes" — named, reusable scope-rule bundles (e.g., "GitHub PR triage" = scope rules for `github.com/owner/repo` + `github.com/owner/repo/pulls/*` + 50-action budget + 24 h expiry).
- **Scope expiry:** All Trusted-mode scopes auto-expire after 24 h or 50 actions, whichever first. Phone overlay shows remaining budget.
- **Audit export:** Settings → Computer Use → "Export audit log" produces a tar.gz of the JSONL chain + all screenshots, signed with an OpenBurnBar trusted-device signing identity stored in the local Keychain (`WhenUnlockedThisDeviceOnly`). The original draft said "user's iCloud device certificate"; implementation audit found no iCloud-device-certificate API/pattern in this repo, so the production trust root is the OpenBurnBar trusted-device key plus sidecar metadata (`signerKind`, `trustRoot`, public key, public-key SHA-256). For privacy: defaults to local file save; user must opt into iCloud upload.
- **OpenTimestamps notarization:** Settings → Computer Use → Advanced → "Notarize this session" submits the audit-chain root hash to OpenTimestamps. The returned proof is appended to the audit file. Verifies on Bitcoin block headers — non-repudiable proof the session existed at a point in time.
- **Audit chain dispute flow:** new `docs/runbooks/computer-use-audit-disputes.md`. If a user claims an action was unauthorized, support workflow: export → validate chain → check OpenTimestamps proof → cross-reference with `users/*/computer_use_actions/*` server-side rollup.

**Cloud / rules:**
- `ComputerUseAuditHeaderDoc.openTimestampsProof` field added (optional, base64 string).
- Server-side `validateOpenTimestampsProof` Cloud Function for cross-checking.

**Privacy:** OpenTimestamps notarization sends ~32 bytes (the root hash) to a public timestamping service. Documented in `docs/PRIVACY.md`. User opt-in.

**Tests:**
- Unit: `ComputerUseScopeLibraryTests` (named bundles, expiry, partial overlap), `ComputerUseAuditExportTests` (signed tar.gz round-trip, chain validation after export), `OpenTimestampsClientTests` (proof construction, mock verification).
- Manual: 10-user TestFlight test of "GitHub PR triage" scope library; audit export validated end-to-end.

**Docs:**
- `docs/HERMES_COMPUTER_USE.md` — polish section.
- NEW `docs/runbooks/computer-use-audit-disputes.md`.
- `CHANGELOG.md` entry.

**Acceptance gate:**
1. Scope expiry enforced 100% of the time across 50 sessions.
2. Audit export validates against on-disk chain 100/100 attempts.
3. OpenTimestamps proof verification succeeds for 10/10 notarized sessions.
4. 7-day soak.

**Out of scope:**
- Multi-Mac CU orchestration (defer to future plan).
- Agent-to-agent CU (one agent driving another agent's Mac — defer).

---

## Verification recipe (E2E for the integrating engineer)

After any phase lands, before flag flips for > 5% rollout:

```bash
# Rust crate (unchanged — control streams ride existing iroh transport)
cd crates/openburnbar-iroh && cargo test --release

# SwiftPM tests
cd OpenBurnBarCore && swift test --filter "OpenBurnBarComputerUseCoreTests"
cd OpenBurnBarCore && swift test --filter "MediaLoopbackAgentWatch"
cd OpenBurnBarCore && swift test --filter "BrowserComputerUseSmokeTests"

# Mac build + tests
xcodebuild test \
  -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:OpenBurnBarTests/ComputerUse

# iOS build + tests
xcodebuild test \
  -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBarMobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:OpenBurnBarMobileTests/ComputerUse

# Daemon tests
cd OpenBurnBarDaemon && swift test --filter "ComputerUse"

# Functions
cd functions && npm ci && npx tsc --noEmit && npm run test:computer-use

# Loopback smoke
./scripts/test-computer-use-loopback.sh

# Phase-specific acceptance gate per §H phase row.
# Capture screenshots, audit chain exports, and `iroh_audit_events` exports
# under docs/runbooks/computer-use-device-matrix/{phase}.md and
# docs/runbooks/computer-use-rollout-status.md.
```

---

## Rollout governance

Each phase gate is reviewed against telemetry in this order:

1. Test suites green (auto-blocking).
2. Device-matrix manual results captured (manual sign-off in `docs/runbooks/computer-use-device-matrix/{phase}.md`).
3. ≥ 7-day soak with flag on for internal users; success rate ≥ 95%, panic-halt rate ≤ 2%, scope-violation rate ≤ 0.5%.
4. `iroh_audit_events` shows expected streamClass distribution; zero unexpected fallbacks.
5. App Store review pass (Phases 9, 11 require re-submission for new permissions / distribution channel).
6. Budget projection from `evaluateComputerUseBudget` shows < $1000/mo at current trajectory before broad rollout.
7. Alberto approves Remote Config percentage step (5% → 25% → 50% → 100% with ≥ 48 h between steps; double the Mercury cadence because CU blast radius is bigger).

Rollback at any time by flipping the phase's Remote Config flag to `false`. Rollback the whole feature with `computer_use_kill_switch=true`. The legacy iroh + Mercury paths are unaffected by any CU rollback.

---

## Decisions index

| # | Decision | Implementation phase | Lives at |
|---|---|---|---|
| 1 | Approval is the only ground truth at v1 | Phase 9 | `BrowserActionDispatcher.swift` · `MacActionDispatcher.swift` |
| 2 | Three trust modes (Manual / Step / Trusted), per-session | Phase 10 | `ComputerUseSessionMetadata.swift` · `ComputerUseSessionPanel.swift` |
| 3 | Browser CU before Mac CU | Phases 9 → 11 | Phase ordering + 14-day soak gate |
| 4 | Cursor in surface stream, not separate channel | Phase 8 | `MediaPacketCodec.swift` · `AgentWatchReceiver.swift` |
| 5 | Phone emits intent, Mac translates to HID | Phase 12 | `PhoneControlReceiver.swift` · `PhoneControlAuthorityValidator.swift` |
| 6 | Action queue lives on phone only | Phase 8 | `AgentWatchView.swift` · `ComputerUseSessionPanel.swift` (no queue UI) |
| 7 | Three independent panic-kill paths | Phase 9 | `ComputerUsePanicHaltCoordinator.swift` |
| 8 | Audit log is content-addressed, tamper-evident | Phase 10 | `ComputerUseAuditChain.swift` · `ComputerUseAuditLogger.swift` |
| 9 | Separate `hosted_computer_use_sync` SKU | Phase 9 | StoreKit · entitlement doc |
| 10 | Bounded vision context per turn | Phase 9 | `BrowserActionDispatcher.swift` prompt builder |

---

## Glossary

- **Path A (Agent Watch):** Mac → phone read-only mirror with action overlay.
- **Path B (Browser CU):** agent drives Playwright Chromium; sandboxed in the browser.
- **Path C (Mac CU):** agent operates the whole Mac via CGEvent + AX.
- **Path D (Phone Control):** phone emits intent to take over from the agent.
- **Trust mode:** Manual / Step / Trusted — chosen per session, controls approval granularity.
- **Scope rule:** URL prefix, bundle ID, or window-title regex that defines what the agent can touch in Trusted mode.
- **Deny region:** built-in or AX-derived UI region where actions are refused without prompt (lock screen, password fields, Keychain, etc.).
- **Audit chain:** content-addressed BLAKE3 hash chain of action entries; tamper-evident.
- **Authority envelope:** Ed25519-signed `PhoneControlAuthority` carrying intent hash, counter, timestamp.
- **Panic halt:** instant cross-path session termination (hotkey, phone gesture, lock, kill-switch).
- **Vision context:** the last full screenshot + 3 thumbnails + 5 action summaries fed to the vision model per turn.
- **`hosted_computer_use_sync`:** new entitlement SKU at $14.99/mo; gates Browser CU + Mac CU + Phone control + audit export + trusted scopes.
- **`computer_use_kill_switch`:** Remote Config flag flipped on hard-cap budget breach; disables all new CU sessions.

---

## Cross-references

- `AGENTS.md` — completion bar.
- `DESIGN.md` — Mercury identity, tokens, motion (extended per phase decision log).
- `plans/2026-05-15-mercury-media-master-plan.md` — Mercury Media plan (Phases 1–7); CU Phase 8 depends on Mercury Phase 3 ≥ 95% success.
- `docs/HERMES_IROH_TRANSPORT.md` — current iroh transport (extended with `control.*` stream classes).
- `docs/HERMES_MEDIA_TRANSPORT.md` — Mercury media stream classes (template for the new control classes).
- `docs/HERMES_COMPUTER_USE.md` — NEW operator/engineer reference for the substrate this plan ships.
- `docs/runbooks/computer-use-rollout-status.md` — NEW phase status log.
- `functions/src/types.ts` — canonical schema (extended with CU doc types).
- `firestore.rules` — security rules (extended with CU collections + entitlements).
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarApprovalContracts.swift` — existing approval primitives this plan extends.
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarToolContracts.swift` — existing tool primitives extended with 13 new CU tool kinds.
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarBrowserToolService.swift` — existing browser surface extended with 7 new action kinds.

End of master plan.
