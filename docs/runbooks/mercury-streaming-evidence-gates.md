# Mercury Streaming Evidence Gates

This runbook tracks the audited Mercury Mirror streaming upgrade. It replaces
the unsafe AV1-first strategy with capability-probed rollout gates.

## Current Rule

Do not change live media behavior until the evidence gates below are green.
The existing v1 media wire remains the compatibility floor.

Last implementation update: 2026-05-21.

Current live posture:

- Capability snapshots, codec policy, MediaFrame v2 envelopes, shadow BWE
  policy, datagram scheduling policy, and VideoToolbox LTR token hooks exist.
- Runtime-health snapshots now include actual process CPU measurement plus
  battery, low-power, and thermal state where the platform exposes them.
- Datagram capability probing normalizes the existing iroh runtime
  `max_datagram_size()` / `maxDatagramSize()` result; absent or zero size keeps
  video datagrams disabled.
- Mirror requests and presence heartbeats carry optional streaming capability
  snapshots on Swift and Android. Mac, iOS, and Android advertise v1+v2 on the
  live mirror paths that can parse and render the v2 envelope.
- The `media.ltr.ack` control frame exists. iOS and Android can ACK a v2 LTR
  token after successful decode, and Mac dispatch can feed the acknowledged
  token back into the active encoder.
- Live Mac->iOS and Mac->Android mirror traffic sends MediaFrame v2 envelopes
  with codec/LTR metadata when both peers advertise v2. v1 remains the
  compatibility fallback.
- Android's live receiver enables `MediaFormat.KEY_LOW_LATENCY` for decoders
  whose `CodecCapabilities.FEATURE_LowLatency` probe is present.
- Video datagrams and RPS recovery are not promoted into the live sender path
  yet.
- Benchmark or competitor-parity claims remain blocked until Gate 6 has real
  device data.

## Gate 0 — Capability Snapshot

Required before codec or transport rollout:

- Apple VideoToolbox encode/decode probe for AV1, HEVC, and H.264.
- Android MediaCodec encode/decode probe for AV1, HEVC, and H.264.
- LTR support probe.
- Temporal-layer support probe.
- Screen-content-coding support probe.
- Runtime iroh datagram `max_datagram_size()` capture.
- MediaFrame v1/v2 support advertisement.

Implementation anchor:

- `OpenBurnBarCore/Sources/OpenBurnBarMedia/MercuryStreamingCapabilities.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarMedia/MercuryVideoToolboxCapabilityProbe.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarMedia/MercuryStreamingStats.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRealtimeRelayTypes.swift`
- `android/app/src/main/java/com/openburnbar/data/media/MercuryStreamingCapabilities.kt`
- `android/app/src/main/java/com/openburnbar/data/media/AndroidMediaCodecCapabilityProbe.kt`
- `android/app/src/main/java/com/openburnbar/data/media/MercuryStreamingStats.kt`
- `android/app/src/main/java/com/openburnbar/data/media/AndroidRuntimeHealthProbe.kt`
- `android/openburnbar-iroh-relay/src/main/java/com/openburnbar/irohrelay/HermesRealtimeRelayFrame.kt`

Control-frame propagation:

- `OpenBurnBarMobile/Services/Media/MediaControlStreamCoordinator.swift`
- `OpenBurnBarMobile/Views/Media/MercuryLiveSheet.swift`
- `AgentLens/Services/Media/MercuryRouter.swift`
- `AgentLens/Services/Media/MediaSessionCoordinator.swift`
- `android/app/src/main/java/com/openburnbar/data/media/MediaControlStreamCoordinator.kt`

## Gate 1 — Wire Compatibility

Rules:

- `MediaFrame` v1 stays byte-compatible.
- v2 metadata is sent only when both peers advertise v2 support.
- v2 metadata must include an explicit extension length.
- New `MediaFrame.Kind` values are not sent to v1 peers.
- Unknown stream classes remain no-op routed, not crash routed.

Proof:

```bash
swift test --package-path OpenBurnBarCore --filter MediaPacketCodecTests
swift test --package-path OpenBurnBarCore --filter MediaFrameProtocolTests
swift test --package-path OpenBurnBarCore --filter MercuryStreamingCapabilitiesTests
swift test --package-path OpenBurnBarCore --filter MercuryStreamingStatsTests
cd android && JAVA_HOME="$HOME/.homebrew/opt/openjdk@21" ANDROID_HOME="$HOME/Library/Android" ANDROID_SDK_ROOT="$HOME/Library/Android" ./gradlew :app:testDebugUnitTest :openburnbar-iroh-relay:testDebugUnitTest --tests 'com.openburnbar.data.media.MercuryStreamingCapabilitiesTest' --tests 'com.openburnbar.data.media.MediaPacketCodecTest' --tests 'com.openburnbar.irohrelay.IrohRelayFrameCodecTest' --no-daemon
```

## Gate 1a — MediaFrame v2 Envelope

Rules:

- v2 is a separate envelope, not a reinterpretation of the v1 header.
- v2 encode requires negotiated `MercuryMediaFrameWireVersion.V2`.
- v2 carries explicit metadata and payload lengths.
- v2 metadata can carry the selected codec and a real LTR acknowledgement token.
- v1 peers reject v2 envelopes instead of treating new kinds as valid v1
  traffic.

Implementation anchor:

- `OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaFrameV2.swift`
- `android/app/src/main/java/com/openburnbar/data/media/MediaFrameV2.kt`

Proof:

```bash
swift test --package-path OpenBurnBarCore --filter MediaFrameV2CodecTests
cd android && JAVA_HOME="$HOME/.homebrew/opt/openjdk@21" ANDROID_HOME="$HOME/Library/Android" ANDROID_SDK_ROOT="$HOME/Library/Android" ./gradlew :app:testDebugUnitTest --tests 'com.openburnbar.data.media.MediaFrameV2CodecTest' --no-daemon
```

## Gate 2 — Codec Selection

Production policy:

1. HEVC hardware where local encode and remote decode are proven.
2. H.264 hardware fallback.
3. AV1 only when the experiment flag is enabled and both peers prove runtime
   support.

The codec resolver must not select AV1 in production just because the OS knows
the AV1 four-character code.

Implementation anchor:

- `OpenBurnBarCore/Sources/OpenBurnBarMedia/MercuryStreamingPolicy.swift`
- `AgentLens/Services/Media/MediaSessionCoordinator.swift`
- `AgentLens/Services/Media/MercuryRouter.swift`
- `android/app/src/main/java/com/openburnbar/data/media/MercuryStreamingPolicy.kt`

Live routing status:

- The policy resolver prefers HEVC hardware, then H.264 hardware.
- AV1 remains experiment-only and requires runtime encode/decode proof from
  both peers.
- Mac mirror startup now passes local and remote capability snapshots into the
  session coordinator.
- Live mirror promotes v2 only for screen-share peers that both advertise v2.
  Call surfaces remain v1-only until their video data paths are upgraded.

Proof:

```bash
swift test --package-path OpenBurnBarCore --filter MercuryStreamingPolicyTests
cd android && JAVA_HOME="$HOME/.homebrew/opt/openjdk@21" ANDROID_HOME="$HOME/Library/Android" ANDROID_SDK_ROOT="$HOME/Library/Android" ./gradlew :app:testDebugUnitTest --tests 'com.openburnbar.data.media.MercuryStreamingPolicyTest' --no-daemon
```

## Gate 3 — Datagram Readiness

Video datagrams require:

- runtime max payload present;
- payload budget after Mercury overhead greater than the encoded packet;
- reliable fallback for IDR and parameter sets;
- kill switch `mercury_video_datagram_enabled`;
- Android parity before rollout.

No code may assume a fixed 1200-byte MTU.

Implementation anchor:

- `OpenBurnBarCore/Sources/OpenBurnBarMedia/MercuryStreamingPolicy.swift`
- `android/app/src/main/java/com/openburnbar/data/media/MercuryStreamingPolicy.kt`

Status:

- Datagram packet scheduling exists as policy code and respects runtime max
  payload, Mercury overhead, IDR/parameter-set reliable fallback, and a kill
  switch.
- Live video does not send datagrams yet.

## Gate 4 — Controller And Pacer Shadow Mode

The next bandwidth estimator and frame pacer must run beside the current
controller before taking ownership of the session.

Promotion requires improvement or parity across:

- freeze count/minute;
- present-time error;
- recovery time after loss;
- bitrate target vs actual;
- CPU, battery, thermal impact.

Implementation anchor:

- `OpenBurnBarCore/Sources/OpenBurnBarMedia/MercuryStreamingPolicy.swift`
- `android/app/src/main/java/com/openburnbar/data/media/MercuryStreamingPolicy.kt`
- `AgentLens/Services/Media/MediaSessionCoordinator.swift`

Status:

- Shadow BWE decisions are computed and observed beside the existing production
  `BitrateController`.
- Promotion to owner remains blocked pending impairment results and live
  receiver pacer data.

## Gate 5 — LTR/RPS

LTR recovery must use the platform acknowledgement-token lifecycle:

1. Force LTR refresh.
2. Read the returned acknowledgement token from the encoded sample.
3. Receiver ACKs only after successful receipt/decode.
4. Encoder supplies acknowledged tokens on later frames.
5. Fall back to IDR when the window is empty or recovery fails.

Synthetic `ltrId`-only recovery is not allowed.

Implementation anchor:

- `AgentLens/Services/Media/VideoEncoder.swift`
- `AgentLens/Services/Media/MacFileTransferService.swift`
- `AgentLens/Services/Media/MercuryRouter.swift`
- `AgentLens/Services/Media/MediaSessionCoordinator.swift`
- `OpenBurnBarMobile/Services/Media/MediaControlStreamCoordinator.swift`
- `OpenBurnBarMobile/Services/Media/VideoReceivePipeline.swift`
- `OpenBurnBarMobile/Views/Media/MercuryLiveSheet.swift`
- `OpenBurnBarMobile/Views/Media/ScreenShareViewerView.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarMedia/MercuryStreamingPolicy.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRealtimeRelayTypes.swift`

Status:

- The VideoToolbox encoder exposes real LTR enablement, force-refresh, returned
  acknowledgement token capture, and acknowledged-token frame options.
- The network receiver-to-encoder ACK loop is wired for v2 frames: iOS ACKs
  after decode success and Mac routes `media.ltr.ack` back to the encoder.
- Live Mac->iOS screen-share promotes LTR token metadata inside negotiated v2
  frames. RPS remains gated; when v2/LTR is unavailable or unacknowledged, live
  recovery must fall back to IDR.

## Gate 6 — Benchmark Claim

Do not claim Parsec/Moonlight/Splashtop-class performance until the impairment
matrix proves it on real devices.

Required matrix:

- LAN and LTE;
- 0/1/3/5/10% loss;
- 30/100/300 ms RTT;
- glass-to-glass latency;
- freeze count/minute;
- SSIM or equivalent visual-quality metric;
- CPU, battery, thermal state;
- projected relay cost.

Harness:

```bash
scripts/e2e/mercury-mirror-network-impairment.sh --dry-run
```

The harness writes a CSV for the full matrix without touching network state by
default. Real impairment runs must provide host-specific apply/clear commands
through `OPENBURNBAR_IMPAIRMENT_APPLY_CMD` and
`OPENBURNBAR_IMPAIRMENT_CLEAR_CMD`, then pass the real Mercury verification
command after `--run --`.

### Live Paired Screen-Share Benchmark

Use this when a Mac and Android/iOS device are signed into the same account and
already paired through Mercury Mirror. The goal is evidence capture, not a demo
clip.

Preflight:

- Mac and phone/tablet on the same LAN, unlocked, battery saver off.
- macOS Screen Recording permission granted to OpenBurnBar and the active
  helper build.
- Current Android debug APK or current iOS build installed.
- Mercury Mirror pairing visible in the mobile paired-Mac surface.

Artifact setup for Android:

```bash
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
export BENCH_DIR="$PWD/artifacts/mercury-live-benchmark/$RUN_ID"
mkdir -p "$BENCH_DIR"

adb -s R3CXB0CNS0J logcat -c
adb -s R3CXB0CNS0J logcat -v epoch > "$BENCH_DIR/android-logcat.txt" &
ANDROID_LOG_PID=$!

log stream --style compact \
  --predicate 'process CONTAINS "OpenBurnBar" OR process CONTAINS "AgentLens" OR eventMessage CONTAINS "Mercury" OR eventMessage CONTAINS "iroh"' \
  > "$BENCH_DIR/mac-log.txt" &
MAC_LOG_PID=$!

adb -s R3CXB0CNS0J shell screenrecord --time-limit 180 /sdcard/mercury-benchmark.mp4 &
```

Manual run:

1. Start Mac to mobile Mercury Mirror from the Mac.
2. Accept/open the viewer on the phone or tablet.
3. Run 60 seconds static desktop.
4. Run 60 seconds high-motion scrolling or window dragging.
5. Run 60 seconds app switching or video-like motion.
6. Note request time, accept time, first non-black frame, freezes, reconnects,
   selected codec, and visible stats-overlay values if present.
7. End the stream and collect artifacts:

```bash
adb -s R3CXB0CNS0J pull /sdcard/mercury-benchmark.mp4 "$BENCH_DIR/"
adb -s R3CXB0CNS0J bugreport "$BENCH_DIR/android-bugreport.zip"
kill "$ANDROID_LOG_PID" "$MAC_LOG_PID" 2>/dev/null || true
```

Pass/fail floor:

- No app crash on either side.
- No persistent black screen after first frame.
- First non-black frame within 2 seconds on LAN.
- No freeze longer than 2 seconds during static or high-motion segments.
- Wi-Fi toggle or impairment recovery either reconnects within 5 seconds or
  reports a clear recoverable failure.
- No fatal decoder, encoder, iroh, or frame-parser errors in captured logs.
- Evidence folder contains mobile logs, Mac logs, screen recording, bugreport,
  and timestamp notes.

## Verification Snapshot — 2026-05-21

Commands run successfully after the Android native-context and mobile warning
cleanup pass:

```bash
xcodebuild -scheme OpenBurnBarMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:OpenBurnBarMobileTests/MediaControlStreamPresenceTests test -quiet
cd android && JAVA_HOME="$HOME/.homebrew/opt/openjdk@21" ANDROID_HOME="$HOME/Library/Android" ANDROID_SDK_ROOT="$HOME/Library/Android" ./gradlew assembleDebug :openburnbar-iroh-relay:testDebugUnitTest :app:testDebugUnitTest --no-daemon
adb -s R3CXB0CNS0J install -r android/app/build/outputs/apk/debug/app-debug.apk
adb -s R3CXB0CNS0J shell am start -W -n com.openburnbar/.MainActivity
```

Results:

- iOS focused XCTest gate passed with no `warning:` or `error:` diagnostics in
  `artifacts/swift-warning-final.log`.
- Android debug APK and app plus relay JVM unit tests passed with no compiler
  warnings in `artifacts/android-warning-final.log`.
- Samsung `R3CXB0CNS0J` cold-launched `com.openburnbar/.MainActivity` in
  963 ms wait time.
- Launch log includes `Installed Android native context for iroh DNS resolver`
  and no fatal AndroidRuntime/SIGABRT/SIGSEGV markers.
- Captured evidence lives under `artifacts/android-device-smoke-final/`.

## Verification Snapshot — 2026-05-20

Commands run successfully against the current implementation:

```bash
swift test --package-path OpenBurnBarCore
xcodebuild -scheme OpenBurnBar -destination 'platform=macOS' -derivedDataPath /tmp/OpenBurnBarDerivedData-Mercury build
xcodebuild -scheme OpenBurnBarMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/OpenBurnBarMobileDerivedData-Mercury build
cd android && JAVA_HOME="$HOME/.homebrew/opt/openjdk@21" ANDROID_HOME="$HOME/Library/Android" ANDROID_SDK_ROOT="$HOME/Library/Android" ./gradlew :app:testDebugUnitTest :openburnbar-iroh-relay:testDebugUnitTest --no-daemon
cd crates/openburnbar-iroh && cargo test
OPENBURNBAR_IMPAIRMENT_ARTIFACT_DIR="$(mktemp -d)" scripts/e2e/mercury-mirror-network-impairment.sh --dry-run
```

Results:

- `OpenBurnBarCore`: 972 tests, 2 skipped, 0 failures.
- macOS app build: succeeded with fresh DerivedData.
- iOS simulator app build: succeeded with fresh DerivedData.
- Android app plus iroh relay unit tests: `BUILD SUCCESSFUL`.
- Rust iroh crate: 9 unit tests plus doc-tests passed.
- Impairment harness: dry-run enumerates the full 15-scenario loss/RTT matrix
  and writes CSV output.
