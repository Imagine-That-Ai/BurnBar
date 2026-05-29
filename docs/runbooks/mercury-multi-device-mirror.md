# Mercury Multi-Device Mac Mirror

Mercury Mac mirroring supports multiple mobile viewers on one Mac stream. The
Mac owns capture, encoding, display selection, and control authority; iOS and
Android join as viewers over their own `media.control` streams.

## Runtime Contract

- Maximum viewers: 3 per Mac mirror session.
- Controller: the first accepted viewer. It can tap, type, scroll, use
  clipboard actions, and switch displays.
- Watchers: later accepted viewers. They receive the same mirror frames and
  focus context but cannot send Mac-control, clipboard, co-pilot target, or
  display-switch actions.
- Reconnects: the same `viewerId` or `viewerDeviceId` replaces its stale viewer
  lease instead of consuming another slot.
- Mobile lifecycle: app backgrounding, sheet re-parenting, full-screen-cover
  dismissal, and activity recreation are not user intent to stop the Mac mirror.
  iOS and Android may detach local frame handlers during those transitions, but
  they must keep the host-side mirror alive and reinstall handlers when the
  viewer returns.
- Explicit stop: only the viewer close/back/finish path, sign-out, or a Mac-side
  policy/kill path should emit `media.mirror.stop` for a normal mobile viewer.
- Shutdown: stopping one viewer detaches only that viewer. The ScreenCaptureKit
  session stops when the last viewer leaves.

## Wire Fields

`media.mirror.request` carries:

- `viewerId`
- `viewerDeviceId`
- `controlAuthorityPeerNodeId`

`media.mirror.ack` carries:

- `sessionId`
- `viewerId`
- `viewerRole`
- `viewerCount`
- `maxViewers`
- `controlOwnerViewerId`

`media.mirror.stop` and `media.mirror.display.select` carry `sessionId` so the
Mac can scope lifecycle and display-selection changes to the active mirror
session.

## Control Authority

The Mac-side `PhoneControlReceiver` validates the Ed25519 control envelope as
before, then checks the current mirror controller peer. If a watcher sends a
signed control intent, the Mac rejects it with `control.denied` detail
`control_owned_by_other_viewer`.

## Viewer controls

Controllers can tap, type, scroll, switch displays, and use Mercury clipboard
actions from the mirror dock. Optional **Auto keyboard on text focus** (Media
settings or mirror dock customize; default off) opens the phone keyboard when
Mac focus context reports a text field; Smart Zoom framing stays independent.
Manual **Type on Mac** still works when auto-type is off or after dismiss.

## Connection Recovery

`media.control` stream ownership is bound to the paired iroh node and signed-in
uid, not only to the Mac's latest published relay `connectionId`. A phone can
open a valid stream through a still-signed persisted route while the Mac has
already refreshed its relay document. The Mac must accept the first
`media.classify` frame, register the stream under the frame's `connectionId`,
and audit the drift instead of dropping the stream. Dropping that first classify
frame leaves mobile clients stuck in the "connecting / reconnecting" loop before
presence heartbeats or mirror requests reach `MercuryRouter`.

## Verification

Focused automated gates:

```bash
xcodebuild -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBar \
  -destination 'platform=macOS,arch=arm64' \
  -jobs 1 \
  -only-testing:OpenBurnBarTests/IrohRelayRequestHandlerTests \
  -only-testing:OpenBurnBarTests/MercuryRouterTests \
  -only-testing:OpenBurnBarTests/MacMediaCapabilityGateTests \
  test

swift test --package-path OpenBurnBarCore --filter MediaFrameProtocolTests

cd android
./gradlew :openburnbar-iroh-relay:testDebugUnitTest \
  --tests com.openburnbar.irohrelay.IrohRelayFrameCodecTest \
  --tests com.openburnbar.irohrelay.HermesRealtimeRelayControlFrameTest \
  :app:testDebugUnitTest \
  --tests com.openburnbar.data.media.MediaControlStreamCoordinatorTest \
  --tests com.openburnbar.ui.media.ScreenShareAutoTypeFollowPolicyTest \
  --no-daemon

OPENBURNBAR_MOBILE_TEST_FILTER="OpenBurnBarMobileTests/ScreenShareAutoTypeFollowPolicyTests" \
  ./scripts/test-openburnbar-mobile.sh
```

Physical proof should include one iOS device and one Android device connected
at the same time. The expected result is that both devices render the same Mac
display, the first accepted device controls the Mac, and the second accepted
device remains read-only.

Reconnect proof should also background and foreground each mobile viewer while
the Mac is locked or at the login window. The expected result is that frames
resume without consuming another viewer slot, and keyboard input still reaches
the Mac so the user can enter their password after the OS unlocks the secure
input path.

## Focused interactive CLI terminal (Phase 12)

"CLI mode" in an agent chat opens a *focused single-window terminal* instead of
mirroring the whole desktop. When the phone sends the mirror request it includes
an optional `agentTerminal` payload (`HermesRealtimeRelayAgentTerminalRequest`:
`runtimeId`, `workingDirectory?`, `interactive`, `modelID?`). On accept, the Mac:

1. Launches that runtime's CLI **interactively** in Terminal.app via
   `InteractiveTerminalLauncher` (`hermes`, `pi`, `codex`, `claude`, `droid`,
   `forge`, `agy`, `grok`, `openclaude`) — a bare REPL/TUI, no one-shot
   `-p`/`exec`/`--print` flags. It reuses the same `open -a Terminal <run.command>`
   mechanism as the existing one-shot visible-CLI path, so it ships in the
   sandboxed Mac App Store build too.
2. Resolves the new Terminal window's `CGWindowID` (diffing the Terminal window
   set before/after launch, with a unique window-title token as a secondary
   signal).
3. Pins the capture to just that window with
   `MediaSessionCoordinator.switchScreenShareTarget(displayId: nil, windowID:)`
   — deterministic, and **independent of** `AgentFocusFollowController`
   (which is `#if !DISTRIBUTION_MAS`). So the focused-window view works in both
   the direct and Mac App Store builds.

The launched session is terminated (process tree killed, temp dir removed) when
the mirror viewer is removed.

### Build-specific behavior

| Capability | Direct / notarized | Mac App Store (sandboxed) |
| --- | --- | --- |
| Launch interactive agent terminal | yes (`open -a Terminal`) | yes (same path) |
| Show only that terminal window, focused | yes (windowID pin) | yes (windowID pin) |
| Inject live keystrokes into the TUI | yes (`MacInputController`) | no — Accessibility unavailable |

Live keystroke typing into the TUI is wired end to end: the focused terminal
view (`InlineAgentMirrorView`) hosts a hidden `RemoteKeyboardCaptureView` plus a
floating key bar (Esc / Tab / Ctrl-C / arrows / Return). Keystrokes flow
`InlineAgentMirrorController.sendText`/`sendKey` -> `PhoneControlSender` -> relay
-> the Mac control dispatcher -> `MacInputController` -> `CGEvent` into the
frontmost Terminal window (which the launcher activates). The control lane is set
up with the same recipe as `MercuryLiveSheet.startPhoneControlIfPossible`
(device-trust register, authority publish, classify, signed intents) and is only
effective in the **direct build** — the sandboxed MAS Mac compiles
`MacInputController` out, so injected frames are dropped and the user falls back
to the chat composer (flip the `CLIAgentChatPresentationMode` segmented control
back to `nativeChat`). Needs on-device validation of the full inject path.

### Surfaces

- Hermes / Pi (`HermesTabView`, `ChatView`): CLI mode renders the inline mirror,
  now pinned to the launched terminal (`InlineAgentMirrorView(runtime:)`).
- Dedicated CLI agents (`CLIAgentChatThreadView`): the session-interface picker
  gains `CLIAgentChatPresentationMode.macInteractiveCLI` ("Terminal"), which
  replaces the transcript with the focused terminal for that runtime.
- The full-screen Mercury Live viewer (`MercuryLiveSheet`) accepts a
  `terminalRuntime` and threads the same `agentTerminal` payload, so the
  fully-wired keyboard/control surface can host the focused terminal.
