# Mercury Smart Zoom

**Date:** 2026-05-25
**Owner:** Independent implementation agent
**Targets:** AgentLens macOS, OpenBurnBarMobile iOS/iPadOS, Android
**Related systems:** Mercury screen share, Computer Use phone control, Agent Watch focus follow

## Summary

Add context-aware local zoom to the Mercury mirror viewer. The phone should automatically frame the active text field, cursor, selected window, or active agent workspace while preserving manual pinch, drag, and toolbar zoom controls.

The important boundary: Smart Zoom changes the phone viewport, not the Mac capture target. Whole-Mac mirroring should continue to capture the full selected display. Agent Watch may keep using the existing focus-follow capture path, but Smart Zoom itself must be safe as a local rendering feature.

## Current Repo Context

- iOS viewer surface: `OpenBurnBarMobile/Views/Media/ScreenShareViewerView.swift`.
- Android viewer surface: `android/app/src/main/java/com/openburnbar/ui/media/ScreenShareViewerScreen.kt`.
- Shared relay types: `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRealtimeRelayTypes.swift`.
- Mac capture and focus context: `AgentLens/Services/Media/ScreenCapturePipeline.swift` and `AgentLens/Services/ComputerUse/Mac/AgentFocusFollowController.swift`.
- Existing viewport code already supports local scale/offset, manual zoom, normalized point mapping, and display selection.
- Existing `HermesRealtimeRelayFocusContext` carries app/window identity but not a rect or cursor/text-field target.

## User Experience

Add a toolbar control named `Smart Zoom` with these modes:

- `Smart`: default for Agent Watch, available for normal Mirror Mac.
- `Text`: follow focused text fields only.
- `Window`: follow the selected/focused window only.
- `Cursor`: follow cursor position only.
- `Off`: disable automatic follow.

Manual interactions always win temporarily:

- Pinch, drag, double-tap, zoom in, zoom out, or reset zoom sets `manualOverrideUntil = now + 5 seconds`.
- While override is active, context updates are retained but not applied.
- Tapping `Smart Zoom` after manual override immediately resumes context following.

Visual feedback:

- A tiny `Smart` chip appears in the stats/control rail only when auto-follow is actively controlling the viewport.
- Do not add explanatory in-app text or a tutorial overlay.
- Do not let the tool rail consume Mac control gestures outside its own bounds.

## Shared Interface Changes

Extend `HermesRealtimeRelayFocusContext` additively. Keep all fields optional except the existing app identity fields so older peers keep decoding.

```swift
public enum HermesRealtimeRelayFocusTargetKind: String, Codable, Sendable, Equatable {
    case cursor
    case focusedElement = "focused_element"
    case focusedWindow = "focused_window"
    case agentWorkspace = "agent_workspace"
}

public struct HermesRealtimeRelayNormalizedRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
}

public struct HermesRealtimeRelayNormalizedPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
}
```

Add optional fields to `HermesRealtimeRelayFocusContext`:

- `targetKind: HermesRealtimeRelayFocusTargetKind?`
- `displayId: String?`
- `normalizedRect: HermesRealtimeRelayNormalizedRect?`
- `normalizedPoint: HermesRealtimeRelayNormalizedPoint?`
- `confidence: Double?`
- `updatedAt: Date?`

Do not add a new stream. Carry this context on existing media/control payloads that already propagate focus context.

## Mac Implementation

Create `SmartZoomContextProvider` under the Mac Computer Use or Media service area.

Inputs:

- `MacAccessibilityInspector` for focused element and element-at-point metadata.
- `ScreenCapturePipeline.availableDisplays()` for display bounds.
- `NSWorkspace.shared.frontmostApplication` and focused AX window for window context.
- Cursor position from `NSEvent.mouseLocation` converted into the same top-left display coordinate space used by `MacInputCore.denormalize`.

Responsibilities:

- Publish context at no more than 4 Hz.
- Emit no context when the Mac is at loginwindow, SecurityAgent, or screen sleep.
- Prefer focused text field when AX role is text-area, text-field, search-field, combo-box text, or terminal-like editable area.
- Fall back to focused window when no focused element is useful.
- Include cursor context only when the selected mode or Smart mode needs it.
- Clamp all normalized rects and points to `0...1`.
- If Accessibility is denied, still emit cursor and focused window context where possible, but do not fake focused text-field context.

Mapping rules:

- Text-field target rect should include 12 percent padding in the short axis and 8 percent padding in the long axis before normalization.
- Window target rect should frame the whole focused window with 4 percent padding.
- Cursor target point should become a small rect on the client side, not a Mac-side rect.

## iOS Implementation

In `ScreenShareViewerView.swift`:

- Add `SmartZoomMode` and `ScreenShareSmartZoomContext` value types near the viewport code.
- Extend `ScreenShareViewportState` with a pure `viewport(following:in:contentRect:)` reducer, or add a separate `ScreenShareSmartZoomReducer`.
- The reducer returns scale and offset only. It must not send control intents.
- Keep normalized click/type coordinate mapping based on the effective viewport already displayed to the user.
- Apply smart zoom in `.onChange` of context and on a light timer while a new context remains fresh.
- Treat context as stale after 1500 ms.

Recommended scales:

- Text target: fit the target rect to 62 percent of the shorter viewport axis, clamped to `1.4...4.0`.
- Window target: fit target rect to 86 percent of viewport, clamped to `1.0...2.4`.
- Cursor target: center on point at current scale if zoomed, otherwise use `1.8`.
- Agent workspace: same as window but allow up to `3.0`.

## Android Implementation

In `ScreenShareViewerScreen.kt`:

- Add Android mirrors of the smart zoom mode and reducer.
- Move current fit-only surface math into a reusable viewport state that can combine fit, smart scale, and smart offset.
- Keep `ScreenMirrorInputPolicy.normalizedPoint` correct after smart zoom. This is the highest-risk part: touch coordinates must map through the inverse of the rendered transform.
- Add toolbar keycap for Smart Zoom mode cycling.
- Reuse the same stale timeout and manual override behavior as iOS.

## Tests

Add pure tests first:

- Smart reducer centers a text rect and clamps scale.
- Cursor mode centers the cursor without overscrolling off content.
- Window mode avoids zooming beyond `2.4`.
- Missing/stale context leaves viewport unchanged.
- Manual override suppresses context until timeout.
- Coordinate inverse mapping stays correct after smart zoom.

Platform tests:

- iOS XCTest for `ScreenShareViewportState` or the new reducer.
- Android JVM tests for `ScreenMirrorInputPolicy` and the new reducer.
- Shared relay encode/decode test proving old payloads without new fields still decode.
- Mac unit tests using fake AX/window/cursor providers.

Manual acceptance:

- On iPhone and Android, normal Mirror Mac keeps whole-display capture but zooms locally to the focused terminal/editor field.
- Pinch/drag pauses auto-follow for about 5 seconds.
- Touch/click coordinates still hit the Mac target under zoom.
- Display switching still works.
- Agent Watch focus-follow capture remains unchanged except for smoother local framing.

## Non-goals

- Do not build OCR-based target detection in v1.
- Do not crop the Mac capture for normal Mirror Mac.
- Do not add new entitlement gates.
- Do not change the Computer Use approval/trust model.
