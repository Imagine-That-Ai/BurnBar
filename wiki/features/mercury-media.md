# Mercury media

Mercury media is the P2P communication layer between Mac and phone: file transfer, screen sharing, and 1:1 voice/video calls. All traffic rides iroh QUIC — no WebRTC, no external relay for media.

## Transport

| Layer | Detail |
|---|---|
| Protocol | iroh QUIC mesh |
| ALPN (relay + control) | `openburnbar/1` |
| ALPN (audio datagrams) | `openburnbar/mercury/audio/1` |
| Authentication | Ed25519 key pairs per device, pairing signature verified before session |
| iOS binary | `OpenBurnBarIroh.xcframework` (Rust UniFFI bindings) |
| Android binary | `Vendor/openburnbar-iroh.aar` (same Rust crate, `cargo-ndk` 4 ABIs) |

Stream classes are negotiated in-band via the first frame on each new bi-stream; existing peers stay interoperable without a new ALPN.

## Stream classes

| Class | Direction | QUIC discipline | Phase |
|---|---|---|---|
| `media.blob.advertise` | Sender → receiver | Reliable, ordered (JSON) | 1 |
| `media.blob.fetch` | Receiver → sender | Reliable, ordered (iroh-blobs) | 1 |
| `media.screen.video` | Mac → iOS | Reliable, ordered, per-GOP | 3 |
| `media.video.{out,in}` | Bidirectional | Reliable, ordered, per-GOP | 5 |
| `media.audio.{out,in}` | Bidirectional | QUIC datagrams (RTP-style) | 4 |

## MediaFrame wire format

```
[18-byte header]
  [4-byte class tag]
  [4-byte session ID]
  [4-byte sequence number]
  [2-byte flags]
  [4-byte payload length]
+ [payload bytes]
+ [optional 4 bytes: i16 cursorX, i16 cursorY, big-endian]
  when Flags bit 0x08 (hasCursorMetadata) is set — used by Agent Watch
```

MediaFrame v1 is the compatibility floor. When both peers advertise v2 support, the Mac sender emits v2 envelopes carrying the selected codec and VideoToolbox LTR acknowledgement tokens.

## Incoming calls

### iOS

Incoming calls arrive via **PushKit VoIP push** so the system can wake the app. `CallKit` presents the system call screen (native ringer, lock-screen wake).

### Android

Android receives a **high-priority FCM data message** with `media_incoming_call` shape from the Cloud Function `triggerVoIPCall`. `MercuryFcmService` constructs `Notification.CallStyle.forIncomingCall(...)` with `setFullScreenIntent(...)` targeting `IncomingCallActivity` (declared `showOnLockScreen=true`, `turnScreenOn=true`).

On Android 14+ without `USE_FULL_SCREEN_INTENT` permission, it degrades to a heads-up notification with a settings deep link. A self-managed `ConnectionService` via `CallKitFacade` is the Android CallKit equivalent.

## File transfer and save preferences

Per-partner save preferences persist the user's choice (Save to Photos / Save to Files / Forget):

- **iOS**: `MediaPartnerSavePreferenceStore` (Codable + `UserDefaults`). `SavePolicy.SAVE_TO_PHOTOS` routes to `PHPhotoLibrary`. `SAVE_TO_FILES` uses `UIDocumentPickerViewController` once to remember a bookmark, then writes directly.
- **Android**: `MediaPartnerSavePreferenceStore` (DataStore Proto, keyed by peer `NodeId`). `SAVE_TO_PHOTOS` routes to `MediaStore.Images.Media` / `.Video.Media` (scoped storage, API 29+). `SAVE_TO_FILES` uses `ActivityResultContracts.OpenDocumentTree` + `DocumentsContract.createDocument`. Privacy nuke: `forgetAll()`.

## Host permissions (Mac)

- **Local Network**: required for iroh/local-peer discovery. `NSLocalNetworkUsageDescription` declared.
- **Screen Recording**: required for mirror. Preflight via `ScreenCaptureKit` before requesting shareable displays; reports `screenRecordingPermissionDenied` on failure.
- OpenBurnBar's own Mac window bundle is excluded from the `ScreenCaptureKit` display filter so transient app chrome doesn't pollute the phone mirror.

## Lock-screen policy

On Mac lock, screen sleep, loginwindow, or SecurityAgent: `MercuryRouter` halts all normal mirror and agent/Computer Use sessions and sends a terminal ACK to the phone. The only exception is Remote Unlock (`remoteUnlockSession` flag + HPKE-certified Mac capabilities + local auth on phone). Agents never receive remote-unlock frames.

## Key files

| File | Role |
|---|---|
| `AgentLens/Services/Media/MercuryRouter.swift` | Central session routing, lock-screen gates (~87 KB) |
| `AgentLens/Services/Media/MediaSessionCoordinator.swift` | Per-session lifecycle |
| `AgentLens/Services/Media/MacFileTransferService.swift` | File send/receive via iroh-blobs |
| `AgentLens/Services/Media/MacMediaCapabilityGate.swift` | Permission checks (~31 KB) |
| `AgentLens/Services/Media/AudioEncoder.swift` | Opus audio encoding |
| `AgentLens/Services/Media/VideoEncoder.swift` | H.264/HEVC video encoding |
| `AgentLens/Services/Media/ScreenCapturePipeline.swift` | ScreenCaptureKit capture pipeline |
| `AgentLens/Services/Media/VoIPCallTrigger.swift` | FCM/APNs call initiation |
| `crates/openburnbar-iroh/` | Rust iroh crate with UniFFI surface |
| `android/openburnbar-iroh-relay/` | Gradle module — Kotlin UniFFI bindings, same wire format as Swift |

## Related

- [Computer Use](./computer-use.md) — Agent Watch extends `MediaFrame` with cursor metadata (flag `0x08`)
- [iOS companion app](../apps/ios-app/index.md) — PushKit integration, mirror surfaces
- [Android companion app](../apps/android-app.md) — FCM, `IncomingCallActivity`, `MercuryAudioDatagramChannel`
- `docs/HERMES_MEDIA_TRANSPORT.md` — full transport spec, codec policy, evidence gates
- `packages/openburnbar-iroh.md` — iroh Rust package reference
