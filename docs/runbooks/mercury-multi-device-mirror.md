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
