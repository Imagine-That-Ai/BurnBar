# Mercury Remote Clipboard

**Date:** 2026-05-25
**Owner:** Independent implementation agent
**Targets:** AgentLens macOS, OpenBurnBarMobile iOS/iPadOS, Android
**Related systems:** Mercury screen share, Computer Use phone control, signed control intents

## Summary

Add explicit clipboard controls to the Mercury mirror toolbar:

- `Paste to Mac`: read the phone clipboard after the user taps, send text to the Mac, set the Mac pasteboard, and dispatch `Command+V`.
- `Grab from Mac`: read the Mac text clipboard, send it back, and write it to the phone clipboard.

V1 is text only. Images and files are reserved for later via `contentType`, but must not be implemented in this pass.

## Current Repo Context

- Phone control already sends signed `control.input.intent` frames through `PhoneControlSender`.
- Mac validation path is `PhoneControlReceiver -> MacInputController`.
- iOS keyboard path already emits text and shortcut intents from `ScreenShareViewerView`.
- Android keyboard path emits `TYPE` and `SHORTCUT` intents from `ScreenShareViewerActivity` and `PhoneControlSender`.
- Mac clipboard primitives exist elsewhere via `NSPasteboard`; iOS uses `UIPasteboard`; Android uses `ClipboardManager`.

## User Experience

Add two toolbar actions near keyboard:

- `Paste to Mac`
- `Grab from Mac`

Behavior:

- The phone reads its clipboard only after the user taps `Paste to Mac`.
- The phone writes its clipboard only after a successful `Grab from Mac`.
- Show short status chips in the existing control-status area:
  - `Pasted to Mac`
  - `Mac clipboard copied`
  - `Clipboard empty`
  - `Mac denied clipboard`
  - `Clipboard too large`
- Do not add background clipboard sync or polling.
- Do not show a visible text input box on the phone.

## Shared Interface Changes

Add frame types to `HermesRealtimeRelayFrameType`:

```swift
case controlClipboardRequest = "control.clipboard.request"
case controlClipboardResponse = "control.clipboard.response"
```

Add optional fields to `HermesRealtimeRelayControlPayload`:

- `clipboardRequest: HermesRealtimeRelayClipboardRequest?`
- `clipboardResponse: HermesRealtimeRelayClipboardResponse?`

Add shared wire structs:

```swift
public enum HermesRealtimeRelayClipboardAction: String, Codable, Sendable, Equatable {
    case pasteToMac = "paste_to_mac"
    case grabFromMac = "grab_from_mac"
}

public enum HermesRealtimeRelayClipboardStatus: String, Codable, Sendable, Equatable {
    case accepted
    case denied
    case empty
    case tooLarge = "too_large"
    case unsupported
    case error
}

public struct HermesRealtimeRelayClipboardRequest: Codable, Sendable, Equatable {
    public var requestId: String
    public var action: HermesRealtimeRelayClipboardAction
    public var contentType: String
    public var text: String?
    public var maxBytes: Int
    public var clientIntentId: String
    public var authority: HermesRealtimeRelayAuthorityEnvelope
}

public struct HermesRealtimeRelayClipboardResponse: Codable, Sendable, Equatable {
    public var requestId: String
    public var action: HermesRealtimeRelayClipboardAction
    public var status: HermesRealtimeRelayClipboardStatus
    public var contentType: String?
    public var text: String?
    public var byteCount: Int?
    public var detail: String?
}
```

Signing:

- Reuse the same Ed25519 authority envelope, monotonic counter, freshness window, and authority-free canonical hash pattern as phone control.
- Extend both Swift and Android signers to sign clipboard requests.
- Clipboard requests and input intents share the same counter namespace so replay protection stays simple.

Limits:

- `contentType` must be `text/plain` in v1.
- Default `maxBytes` is 65536.
- Reject outbound phone text over 65536 UTF-8 bytes before sending.
- Mac rejects response text over requester `maxBytes`.

## Mac Implementation

Create `RemoteClipboardController` under `AgentLens/Services/ComputerUse/Mac/`.

Dependencies:

- `NSPasteboard.general`
- `PhoneControlAuthorityValidator`
- `MacAccessibilityInspector`
- `MacInputController`
- current session/trust state from the existing Computer Use coordinator

`pasteToMac` flow:

1. Validate authority and replay counter.
2. Require active phone-control session and trusted controller.
3. Reject if content type is not `text/plain`.
4. Reject empty text with `empty`.
5. Reject loginwindow, SecurityAgent, screen sleep, secure text fields, and deny-region matches.
6. Set `NSPasteboard.general` to the request text.
7. Dispatch `Command+V` via `MacInputController`.
8. Send response `accepted`.
9. Write an audit entry with action kind `clipboard.paste_to_mac`; do not store clipboard content in the audit entry.

`grabFromMac` flow:

1. Validate authority and replay counter.
2. Require active phone-control session and trusted controller.
3. Reject deny regions and secure focus contexts.
4. Read `NSPasteboard.general.string`.
5. Reject empty string with `empty`.
6. Reject over `maxBytes` with `too_large`.
7. Send response with `text`.
8. Write an audit entry with action kind `clipboard.grab_from_mac`; do not store clipboard content in the audit entry.

## iOS Implementation

Add request helpers near `PhoneControlSender`:

- `send(clipboardRequest:)`
- `RemoteClipboardClient` or a small wrapper owned by `MediaControlStreamCoordinator` / the viewer container.

In `ScreenShareViewerView.swift`:

- Add two toolbar buttons using SF Symbols:
  - Paste: `doc.on.clipboard`
  - Grab: `arrow.down.doc`
- `Paste to Mac` reads `UIPasteboard.general.string` only inside the button action.
- `Grab from Mac` waits for `control.clipboard.response`; on accepted text, writes `UIPasteboard.general.string`.
- Surface failure through the same compact control-status chip used for input denied states.

## Android Implementation

Add request helpers to `PhoneControlSender.kt`:

- `send(clipboardRequest: PhoneControlClipboardRequest)`
- Extend `PhoneControlSigner.kt` canonical signing for clipboard requests.

In `ScreenShareViewerActivity.kt` and `ScreenShareViewerScreen.kt`:

- Use `ClipboardManager` only inside explicit button actions.
- Add the same two toolbar keycaps.
- Store pending request IDs and match responses.
- Write accepted `Grab from Mac` text with `ClipData.newPlainText("Mac clipboard", text)`.

## Tests

Shared:

- Encode/decode clipboard request and response.
- Unknown clipboard frame types are ignored by older dispatch paths.

Signing:

- Swift signer validates clipboard request hash.
- Android signer validates clipboard request hash.
- Replay counter rejects duplicate clipboard requests.
- Tampered text fails validation.

Mac:

- `pasteToMac` sets fake pasteboard and invokes fake `Command+V`.
- `grabFromMac` returns fake pasteboard text.
- Secure field / loginwindow / deny-region contexts reject.
- Audit entries omit clipboard content.

iOS:

- `Paste to Mac` reads pasteboard only after button tap.
- `Grab from Mac` writes pasteboard only for matching accepted response.
- Too-large phone clipboard is rejected locally.

Android:

- Same paste/grab/too-large tests with fake `ClipboardManager`.

Manual acceptance:

- iPhone can paste text into the currently focused Mac app.
- Android can paste text into the currently focused Mac app.
- iPhone can grab Mac clipboard text.
- Android can grab Mac clipboard text.
- Clipboard actions fail with clear status when Mac Accessibility or control authority is denied.

## Non-goals

- No background clipboard sync.
- No image, rich text, or file transfer in v1.
- No clipboard content in logs, audit chain, analytics, or Firestore.
- No bypass around Computer Use entitlement, trust, deny regions, or panic halt.
