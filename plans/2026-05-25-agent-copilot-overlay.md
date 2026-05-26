# Agent Co-Pilot Overlay

**Date:** 2026-05-25
**Owner:** Independent implementation agent
**Targets:** AgentLens macOS, OpenBurnBarMobile iOS/iPadOS, Android
**Related systems:** Mercury mirror, Agent Watch, Hermes/Pi/Codex/Claude/OpenClaw chat, Agent Capability Grants

## Summary

Add a Co-Pilot mode to the Mercury mirror. The user taps a target on the mirrored Mac screen, adds an instruction such as `agent, use this`, and sends the target plus screen context to the active agent.

This is context handoff, not direct control. The Co-Pilot event must not click, type, or grant desktop tools by itself. If the agent later wants to act on the Mac, the existing Computer Use approval, trust, scope, deny-region, and panic-halt rules still apply.

## Current Repo Context

- Mobile Agent Watch state already ingests focus context and action logs.
- Mobile desktop permission grants exist through `MobileAgentPermissionGrantController` and agent grant frames.
- Mac AX enrichment exists in `MacAccessibilityInspector`.
- Mac input and phone control use signed `HermesRealtimeRelayInputIntent` authority.
- Mobile chat dispatch exists through Hermes/Pi/CLI agent surfaces and mission dispatch, but no current wire type sends screen target context from the mirror into an agent thread.

## User Experience

Add a new toolbar mode:

- Icon: target/crosshair style.
- Name for accessibility: `Agent Co-Pilot`.

Interaction:

1. User taps Co-Pilot mode.
2. User taps a point on the mirror.
3. The UI places a persistent target ring at that point.
4. A compact bottom prompt sheet opens with a single instruction field.
5. User enters text or uses OS dictation.
6. User taps send.
7. The active agent receives a target-aware user message.

If no active agent thread is available:

- Show a compact runtime picker for Hermes, Pi, Codex, Claude, and OpenClaw.
- Default to the runtime visible in the current mobile chat context if available.
- If no thread exists for that runtime, create or select the normal active thread using existing app routing. Do not invent a separate agent session model.

Status feedback:

- `Sent to Hermes`
- `Choose an agent`
- `Desktop tools needed`
- `Target denied`
- `Agent unavailable`

## Shared Interface Changes

Add frame type:

```swift
case controlAgentContextTarget = "control.agent.context.target"
```

Add optional field to `HermesRealtimeRelayControlPayload`:

- `agentContextTarget: HermesRealtimeRelayAgentContextTarget?`

Add shared wire struct:

```swift
public struct HermesRealtimeRelayAgentContextTarget: Codable, Sendable, Equatable {
    public var requestId: String
    public var sessionId: String?
    public var runtime: String
    public var threadId: String?
    public var displayId: String?
    public var normalizedX: Double
    public var normalizedY: Double
    public var normalizedRect: HermesRealtimeRelayNormalizedRect?
    public var instruction: String
    public var focusContext: HermesRealtimeRelayFocusContext?
    public var clientIntentId: String
    public var requestedAt: Date
    public var authority: HermesRealtimeRelayAuthorityEnvelope
}
```

If Smart Zoom has not landed yet, define `HermesRealtimeRelayNormalizedRect` in this feature and let Smart Zoom reuse it later. If Smart Zoom lands first, reuse its type.

Signing:

- Reuse the phone-control Ed25519 authority envelope and counter namespace.
- Add canonical signing support for `HermesRealtimeRelayAgentContextTarget` in Swift and Android.
- Reject stale timestamps, replayed counters, missing peer public keys, and tampered instruction/coordinates.

## Mac Implementation

Create `AgentContextTargetReceiver` under `AgentLens/Services/ComputerUse/`.

Flow:

1. Receive `control.agent.context.target`.
2. Validate authority and replay counter.
3. Denormalize point using the selected display bounds.
4. Reject malformed coordinates.
5. Query `MacAccessibilityInspector.snapshotAtPoint`.
6. Reject hard deny regions such as loginwindow, SecurityAgent, screen sleep, and secure text fields.
7. Build an enriched context object with:
   - user instruction
   - normalized and display coordinates
   - app name, bundle id, window title, window id
   - AX role, title, label, role description when available
   - current Computer Use session id if available
8. Dispatch the context to the selected agent thread as a normal user-visible message plus hidden structured metadata.
9. Send an acknowledgement frame or existing `control.denied` frame back to the phone.
10. Audit the target event without screenshot bytes or sensitive field values.

Agent routing:

- Runtime strings must match existing mobile/runtime ids: `hermes`, `pi`, `codex`, `claude`, `openclaw`.
- If `threadId` is present, use that thread.
- If `threadId` is absent, use the active thread for the runtime.
- If no active thread exists, return `agent_unavailable` and let mobile create/select through existing UI.

Desktop tools:

- Do not create a capability grant automatically.
- If the target instruction implies action and the runtime lacks required desktop capability, surface the existing Agent Permission Grant flow.
- The receiver may include a `desktopToolsAvailable` boolean in the local dispatch metadata, but the agent broker remains the source of truth before any tool call.

## Mobile iOS Implementation

In `ScreenShareViewerView.swift`:

- Add `ScreenShareInteractionMode.coPilot`.
- Reuse current normalized point mapping so selected targets are correct under manual or smart zoom.
- Add target ring rendering independent of tap feedback.
- Add a compact prompt sheet. It should not obscure the target ring or the whole toolbar.
- Add send/cancel actions.

In services:

- Add `AgentContextTargetSender` or extend `PhoneControlSender`.
- Pull active runtime/thread from existing Hermes Square / Agent Watch context where available.
- If unavailable, present runtime picker before sending.

Input:

- The prompt field is local to the phone. It sends instruction context to the agent; it does not type into the Mac.
- OS dictation is enough for v1 voice support. Do not build a custom speech recognizer unless already available locally.

## Android Implementation

In `ScreenShareViewerScreen.kt`:

- Add `ScreenMirrorControlMode.COPILOT` or separate mode state if that avoids disrupting touch mode.
- Reuse `ScreenMirrorInputPolicy.normalizedPoint`.
- Render a target ring and bottom instruction sheet.
- Add runtime picker parity with iOS.

In `PhoneControlSender.kt` and signer code:

- Add `send(agentContextTarget)`.
- Keep the same counter namespace as phone-control input.
- Match response/denied frames to update status.

## Agent Dispatch Details

The injected agent message should have this shape:

Visible user content:

```text
Use this screen target: <instruction>
```

Structured metadata:

```json
{
  "kind": "mac_screen_target",
  "runtime": "codex",
  "threadId": "...",
  "displayId": "...",
  "normalizedPoint": {"x": 0.42, "y": 0.61},
  "displayPoint": {"x": 812, "y": 534},
  "focus": {
    "appName": "Warp",
    "bundleId": "dev.warp.Warp-Stable",
    "windowTitle": "...",
    "axRole": "AXTextArea",
    "axTitle": "..."
  }
}
```

Do not include a screenshot bitmap in v1. A future pass can add local screenshot crop hashes or attachments after privacy review.

## Tests

Shared:

- Encode/decode target frame with and without optional focus fields.
- Canonical signing rejects tampered instruction, runtime, coordinates, and thread id.
- Replay counter is rejected.

Mac:

- Denormalization chooses the selected display.
- AX enrichment attaches element role/title/label.
- Secure region rejects and returns a denied frame.
- Dispatch routes to explicit thread id when present.
- Dispatch returns unavailable when no active thread exists.
- Audit entry excludes sensitive field values and screenshot bytes.

iOS:

- Co-Pilot tap maps correctly under fit, fill, manual zoom, and smart zoom.
- Target ring persists until cancel/send.
- Runtime picker appears when no active runtime/thread is known.
- Send button disabled for empty instruction.

Android:

- Same normalized point, target ring, picker, and empty-instruction tests.

Manual acceptance:

- On iPhone, tap a terminal/editor region, send `use this`, and verify the active agent receives target-aware context.
- On Android, repeat the same.
- The target event does not move the Mac cursor or click by itself.
- If desktop grant is absent, the app surfaces the existing permission flow before agent tools can act.

## Non-goals

- No automatic clicking or typing from the Co-Pilot target event.
- No automatic desktop permission grants.
- No screenshot/image attachment in v1.
- No new agent runtime.
- No bypass of Computer Use approval, scope, deny-region, audit, or panic-halt paths.
