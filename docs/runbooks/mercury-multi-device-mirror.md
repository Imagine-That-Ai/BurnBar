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

## Verification

Focused automated gates:

```bash
xcodebuild -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBar \
  -destination 'platform=macOS,arch=arm64' \
  -jobs 1 \
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
  --no-daemon
```

Physical proof should include one iOS device and one Android device connected
at the same time. The expected result is that both devices render the same Mac
display, the first accepted device controls the Mac, and the second accepted
device remains read-only.
