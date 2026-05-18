# Mercury Media Master Plan
## Mac ⇄ iPhone / iPad — File Transfer, Screen Share, 1:1 Video Calling over iroh

**Date:** 2026-05-15
**Owner:** Alberto
**Branch baseline:** `chore/router-brand-coherent-rail`
**Transport baseline:** iroh QUIC mesh — Phase A green, Phase B in flight (`docs/runbooks/iroh-rollout-status.md`)
**Targets:** AgentLens (macOS 14+), OpenBurnBarMobile (iOS 17+ / iPadOS 17+)
**Status:** Approved end-to-end design. Phase 1 ready to start.

---

## Context

OpenBurnBar already has iroh peer-to-peer transport in source: a Rust crate at `crates/openburnbar-iroh` (`iroh = "0.91"`, `iroh-net` + `iroh-blobs`) wrapped in a UniFFI surface and packaged as `Vendor/OpenBurnBarIroh.xcframework`. The Mac host (`AgentLens/Services/IrohRelay/`) and the iOS dialer (`OpenBurnBarMobile/Services/IrohRelay/`) speak length-prefixed JSON frames over QUIC streams today, carrying Hermes chat completions and Pi telemetry. Pairing is Ed25519-signed Firestore records (`/users/{uid}/iroh_pairing/{conn}`); telemetry rolls up nightly through `rollupIrohTransportDaily`; the legacy Cloud Run + Memorystore WSS path stays as a fallback until Phase 7 retirement (`docs/HERMES_IROH_RETIREMENT.md`).

Three new Mac ⇄ iPhone/iPad media capabilities now layer onto that transport:

1. **File and blob transfer** — logs, exports, screenshots, chat attachments.
2. **Live screen share** — Mac → iOS one-way, for triage / pair-debug / Hermes Dashboard demos.
3. **1:1 video calling** — bidirectional Mac webcam ⇄ iPhone/iPad front camera, with mic.

These are **additional iroh stream classes** (`media.blob.*`, `media.screen.*`, `media.video.*`, `media.audio.*`), not a transport replacement. Hermes + Pi continue exactly as today.

This master plan supersedes `~/.claude/plans/prancy-exploring-hippo.md` (the planning-session artifact). All four open questions from that draft are resolved and folded in below.

---

## Executive summary

OpenBurnBar gains three Mac ⇄ iPhone/iPad media capabilities layered on iroh as new QUIC stream classes. File transfer rides **iroh-blobs** for content-addressed resume, dedupe, and BLAKE3 verification. Screen share is **Mac → iOS one-way**, captured via **ScreenCaptureKit** and encoded as **HEVC** (H.264 fallback) over an ordered QUIC stream-per-GOP. Calls are bidirectional HEVC video + **Opus over QUIC datagrams**, with **CallKit + PushKit** waking iPhone from suspended state and a Mercury in-app sheet swapping in when the app is already foregrounded. We **do not** layer WebRTC — iroh-tls already gives us SRTP-equivalent encryption and our own ~200 LOC pacing/jitter/BWE is cheaper than WebRTC's ~7 MB binary plus duplicate signaling. A new **`hosted_media_sync`** entitlement ($9.99/mo) separates media infrastructure from `hosted_quota_sync` (data sync). **Only the Mac needs the entitlement** — paired iPhones receive and send during a session because the Mac owns and pays for it. iOS image saves **prompt once, remember per partner**. Hosted-relay bandwidth has a **$600/mo soft cap** (auto-tightening quotas) and a **$1000/mo hard cap** (Remote Config kill-switch). Seven phases ship independently behind flags, each gated on tests + docs + `DESIGN.md` decision log per AGENTS.md completion bar.

---

## Locked decisions (2026-05-15)

### Decision 1 — iOS incoming-call UI: CallKit primary + Mercury foreground sheet

PushKit VoIP push always reports the call to CallKit (Apple requires this — skipping kills the app). When `CXAnswerCallAction` fires, decide based on `UIApplication.shared.applicationState`:
- `.active` (app already foregrounded) → fulfill action, post `MediaCallIncomingNotification`, present Mercury sheet matching the Mac sheet design.
- `.background` / `.inactive` → fulfill action, app launches to foreground, root view detects active-call state and renders `CallHUD` directly (no intermediate sheet).

Adds ~1 day of state-machine work over CallKit-only. Trade: brief flash of CallKit UI even when the user is already in the app. Mitigation: keep transition < 200 ms via pre-warmed `CallHUD` rendering.

### Decision 2 — Recipient gate: Mac-side entitlement only

A paired iPhone can ring / receive / send media during a session as long as the **Mac** holds `hosted_media_sync`. The iPhone does not need its own subscription. Defensible because the Mac owns the session, pays for hosted-relay bandwidth, and pair-debug is initiated by the operator. Enforcement: `triggerVoIPCall` Cloud Function verifies the calling Mac's entitlement before forwarding the APNs push. Mac-side accept-loop refuses outbound media streams if its own entitlement lapses mid-session.

### Decision 3 — iOS attachment save: prompt-once, remember-per-partner

First image attachment from a given paired Mac shows an action sheet "Save to Photos / Save to Files". Choice is persisted in `UserDefaults` under `media.savePreference.<peerDeviceId>`. Subsequent images from the same partner use the saved choice. Non-image MIME types always use `UIDocumentPickerViewController`. Settings → Media → "Per-partner save preferences" lists each peer with current choice + per-row "Forget" + global "Forget all".

### Decision 4 — Hosted-relay budget: $600 soft / $1000 hard

A new Cloud Function `evaluateMediaBudget` runs hourly, reads n0 services API for month-to-date hosted-relay bytes, projects month-end at current daily rate, and writes `ops/media_budget_status/state/current` with one of three levels: `normal` / `soft_cap` / `hard_cap`.

**Soft cap (projected ≥ $600/mo):**
- Quotas tighten automatically. iOS + Mac re-read on session start (cached 60 s).
- File: 5 GB/day → 2.5 GB/day in + out.
- Screen share: 60 min/day · 60 min/session → 30 min/day · 30 min/session.
- Video call: 240 min/day · 30 min/call → 120 min/day · 20 min/call.
- New session attempts return `.denied(quotaSoftCap)` after limit. Toast: "High demand — your media quota is reduced today."

**Hard cap (projected ≥ $1000/mo):**
- `media_kill_switch` Remote Config flag flips to `true`.
- Both apps refuse new sessions immediately ("Media paused — try again tomorrow").
- In-flight sessions receive `media.terminate(reason: budget_hard_cap)` with 60 s grace.
- Auto-recovers when month rolls over and projection drops back under $600.

n0 dashboard alerts at 75% / 100% / 150% of $600.

### Decision 5 — SKU strategy (recorded; implicit in the approved plan)

New `hosted_media_sync` SKU (`com.openburnbar.hostedMediaSync.monthly`, $9.99) is **distinct from** existing `hosted_quota_sync` ($4.99). `burnbar_pro` umbrella ($14.99) entitles both. Per-feature toggles inside the entitlement doc (`features.fileTransfer`, `features.screenShare`, `features.videoCall`). Phase 1 reuses `hosted_quota_sync` to avoid a SKU flag-day; Phase 2 migrates with a 90-day grandfather window for existing `hosted_quota_sync` subscribers.

### Decision 6 — Transport substrate: direct iroh, no WebRTC

Build directly on iroh QUIC streams (per-GOP) + datagrams (audio). Reasoning: iroh-tls already encrypts; WebRTC would add a redundant DTLS/SRTP hop plus ~7 MB binary plus separate signaling plus parallel telemetry. Cost of going direct: ~200 LOC of pacing + jitter + GCC-lite BWE. Benefit: unified `iroh_audit_events` telemetry, no second encryption hop, no WebRTC × iroh integration unknowns.

### Decision 7 — File transport: iroh-blobs

iroh-blobs is already imported by the Rust crate. Content-addressed BLAKE3 hashing, native resume on disconnect, dedupe of repeated screenshots. Two new UniFFI functions: `publish_blob(local_path) -> BlobTicket` and `fetch_blob(ticket, dest, progress_cb) -> Result<TransferStats>`. The ticket is the wire-level handle, sent as a JSON field in a new `attachment.advertise` frame on the existing Hermes control stream.

---

## Capability matrix

| Capability | Direction | Min / target throughput | Latency budget | Max session | Concurrent | Entitlement | Soft-cap envelope | Hard-cap envelope |
|---|---|---|---|---|---|---|---|---|
| File / blob transfer | Bidirectional Mac ⇄ iOS | min 250 KB/s WAN · target 5 MB/s WAN · 50 MB/s LAN | First-byte ≤ 800 ms · throughput-bound after | 30 min per file · 1 GB max | 4 concurrent · 5 GB/day in + out (50 transfers) | `hosted_media_sync.fileTransfer` (Phase 2+) | 2.5 GB/day | 0 (paused) |
| Live screen share | Mac → iOS | min 2.5 Mbps @ 1280×720 24 fps · target 8 Mbps @ 1920×1080 30 fps | Glass-to-glass ≤ 250 ms · I-frame interval 2 s | 60 min/session · 120 min/day | 1 active | `hosted_media_sync.screenShare` | 30 min/session · 30 min/day | 0 (paused) |
| 1:1 video + audio call | Bidirectional Mac ⇄ iOS | Video min 600 kbps @ 480p 20 fps · target 1.2 Mbps @ 720p 24 fps · Audio Opus 48 kHz 64 kbps mono | Glass-to-glass ≤ 200 ms video · ≤ 150 ms audio · 60 ms jitter | 30 min/call · 240 min/day | 1 active (call + share simultaneously OK) | `hosted_media_sync.videoCall` | 20 min/call · 120 min/day | 0 (paused) |

Quotas enforced at three layers: (a) Mac host gate before initiation, (b) Firestore `users/{uid}/media_quota_usage/{YYYY-MM-DD}` reconciled hourly by `recomputeMediaQuotaUsage`, (c) iroh accept-loop on the Mac refuses `media.*` streams whose entitlement / daily envelope / kill-switch fails.

---

## A. Capability matrix (detailed)

Three knobs to twist if hosted-relay cost or App Store review pushes back:

1. **Screen-share max-session ceiling** is conservative (60 min) to match the legacy Cloud Run WSS request timeout and to limit relayed-traffic exposure when iroh holepunch fails. Can lift to 4 hours once Phase 5 telemetry shows ≥ 75% direct (no relay assist).
2. **Daily envelope** maps to ≤ ~$0.40 of hosted-relay bandwidth per user-day at p99 — comfortably under the $9.99 SKU margin even if a third of users hit cap.
3. **Concurrent sessions = 1** for screen share and video. Two-on-one party calls explicitly out of scope.

---

## B. Transport plan over iroh

### B.1 Stream classes (extending `IrohRelayProtocol`)

The existing `IrohRelayProtocol.WireFormat` is a length-prefixed JSON envelope (`[u32 BE length][JSON HermesRealtimeRelayFrame]`) on a hard-pinned ALPN `openburnbar/1`. We do not bump the ALPN; instead we extend the frame's `type` enum so new stream classes are negotiated in-band:

| Stream class | Cardinality per call | Direction | QUIC discipline |
|---|---|---|---|
| `media.blob.advertise` | 1 per attachment, rides existing Hermes control stream | Sender → receiver | Reliable, ordered |
| `media.blob.fetch` | 1 per attachment, dedicated stream | Receiver dials sender | Reliable, ordered — iroh-blobs `BlobReader` |
| `media.screen.video` | 1 per GOP (~60 frames) | Mac → iOS | Reliable, ordered, **stream-per-GOP** for head-of-line isolation |
| `media.video.out`, `media.video.in` | 1 per direction per GOP | Bidirectional | Same per-GOP pattern |
| `media.audio.out`, `media.audio.in` | None — QUIC datagrams | Bidirectional | Datagrams (RTP-style) |
| `media.control` | 1 per session | Bidirectional | Reliable — RTCP-style sender reports, BWE feedback, mute, pause, terminate |

A new `media.classify { class: ... }` frame is the first frame sent on any new bi-stream after the existing `request.start`-style negotiation, so the receiver knows which pipeline to route the stream into.

### B.2 iroh-blobs for file transfer — yes

- **Content-addressed (BLAKE3)**: natural dedupe of repeated screenshots, idempotent re-sends after drops, hash verification without bolting on our own MAC.
- **Resume**: iroh-blobs ships partial-fetch primitives (`BlobReader::range`); a mid-transfer drop costs only the in-flight chunk.
- **Already in source**: `crates/openburnbar-iroh/Cargo.toml` imports `iroh-blobs`. UniFFI surface adds two functions: `publish_blob`, `fetch_blob`.
- **Wire format**: `BlobTicket` (base32 text) inside a `attachment.advertise` JSON frame on the existing Hermes control stream — no new transport plumbing.

### B.3 Screen share + video — QUIC streams (not datagrams)

iroh-net datagrams cap at ~1200 bytes MTU. Encoded video frames at 720p+ need fragmentation — would reinvent RTP. Instead:

- **Streams per GOP**: one ordered, reliable QUIC stream per group of pictures (~2 s GOP at 30 fps = 60 frames). Head-of-line isolation between GOPs — a stalled GOP doesn't block the next. Receiver abandons in-flight stream on stale-frame detection and requests a fresh keyframe.
- **One I-frame every 2 s, no B-frames, real-time profile**. Bounds recovery time on stream abandon.
- **Frame envelope**: 16-byte header (frame type, presentation timestamp, GOP id, frame index, flags) + encoded NAL units. Defined in `OpenBurnBarMedia/MediaPacketCodec.swift`.

### B.4 Audio — Opus over QUIC datagrams

Opus packets at 64 kbps mono with 20 ms framing are ~120 bytes — well below datagram MTU. Tolerant of loss. Jitter buffer 60 ms (3 packets) + Opus built-in PLC. Mute/unmute in-band on audio frame header to avoid race with sample alignment.

### B.5 Codec choice

| Surface | Default | Fallback | Rationale |
|---|---|---|---|
| Screen share encode (Mac) | **HEVC** via `VTCompressionSession` (`kCMVideoCodecType_HEVC`, real-time profile) | H.264 on Mac Intel pre-Skylake | HEVC hardware-accelerated on all Apple Silicon + Skylake+ Intel; halves bitrate at equivalent quality. ScreenCaptureKit on macOS 12.3+ delivers BGRA `CMSampleBuffer`. |
| Screen share decode (iOS) | **HEVC** via `VTDecompressionSession` → `AVSampleBufferDisplayLayer` | H.264 | iPhone XS+ and all iPad Pro M-series have hardware HEVC decode; iPad mini 5 (A12) falls back via `VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)`. |
| Video encode (both) | **HEVC** | H.264 on iPhone 11 and below (A13) under thermal pressure | A14+ hardware HEVC encode hits 1.2 Mbps @ 720p 24fps at < 8% battery/30min. A13 falls back to H.264 to keep thermal headroom. |
| Audio | **Opus 48 kHz mono 64 kbps VBR** | None — universally supported | libopus static lib in `Vendor/Opus.xcframework`; thin C wrapper in `OpenBurnBarMedia/AudioEncoder.swift`. |

### B.6 Frame pacing, drop policy, bandwidth estimation

- **Pacing**: producer-side rate limiter using `CADisplayLink` (iOS) / `CVDisplayLink` (macOS) snapped to target frame interval. Drops a frame if prior hasn't drained from QUIC send buffer within 1.5× interval.
- **Drop policy**: stale frames (capture time > 250 ms behind wall clock at send time) dropped at encoder. Re-pace on resume.
- **Bandwidth estimation**: receiver-driven GCC-lite — ~100 LOC port of WebRTC Google Congestion Control core (delay-based loss detection + slow-start ramp). Receiver computes `target_bps` every 200 ms in `media.control` `BweFeedback` frame. Encoder treats as ceiling; congestion-controlled steps: 8 → 4 → 2 → 1 Mbps for screen share; 1.2 → 0.6 → 0.3 Mbps for video.
- **Thermal pressure** (iPhone encode): `ProcessInfo.processInfo.thermalState` listener. `.serious` halves target bitrate + frame rate. `.critical` terminates with `media.terminate(thermal)`.

### B.7 Why direct iroh (not WebRTC)

| Axis | WebRTC over iroh | Direct on iroh |
|---|---|---|
| Encryption | DTLS+SRTP on top of iroh-tls (redundant) | iroh-tls only — `HermesRelayCrypto` AAD already replay-protected |
| Signaling | Re-implement SDP offer/answer | Extend our existing stream-class negotiation |
| Binary size | +~7 MB | +~600 KB (libopus + thin codec wrappers) |
| Telemetry | RTCStatsReport vocabulary | Same `iroh_audit_events`, `streamClass = media.*` added |
| Echo cancellation | WebRTC AEC conflicts with iOS Voice-Processing IO | Apple's tuned AEC via `kAudioUnitSubType_VoiceProcessingIO` |
| Risk | iroh × WebRTC integration unblazed; n0 has no examples | iroh stream pattern proven by Hermes/Pi today |

---

## C. macOS implementation (AgentLens)

### C.1 New module: `AgentLens/Services/Media/`

| File | Role |
|---|---|
| `ScreenCapturePipeline.swift` | `SCStream` + `SCStreamConfiguration` (1920×1080@30 default, `.BGRA`). `SCStreamOutput` delegate ships `CMSampleBuffer` to encoder. Window/display picker via `SCShareableContent.current`, focus-window-only by default. |
| `CameraCapturePipeline.swift` | `AVCaptureSession` with `.builtInWideAngleCamera` at 1280×720@24, `.builtInMicrophone`. |
| `MicrophoneCapturePipeline.swift` | `AVAudioEngine` + Voice-Processing IO unit. Bluetooth routing via `AudioObjectAddPropertyListener` on `kAudioHardwarePropertyDefaultOutputDevice`. |
| `VideoEncoder.swift` | `VTCompressionSession` wrapper (HEVC default, H.264 fallback). NAL-unit packets → `MediaPacketCodec`. |
| `AudioEncoder.swift` | libopus 64 kbps mono, 20 ms frames. |
| `FileTransferService.swift` | iroh-blobs adapter; receives `attachment.fetch` over `media.control`. Drag-and-drop entry via `NSItemProvider`. |
| `MediaSessionCoordinator.swift` | Orchestrates capture → encode → packetize → stream open → BWE feedback → teardown. Publishes `@MainActor` state via Combine / `@Observable`. |
| `MediaCapabilityGate.swift` | Reads `MacCloudEntitlementStore` for `hosted_media_sync` + local quota counters + `ops/media_budget_status/state/current`. Returns `.allowed` / `.denied(reason)`. |
| `MediaSessionLogger.swift` | Rolling 5-min JSONL in sandbox for RTT, bitrate adapt, encoder errors (never frames). |
| `VoIPCallTrigger.swift` | Calls the `triggerVoIPCall` Cloud Function to issue APNs VoIP push to the paired iPhone. |

### C.2 Edits to existing iroh path

- **`AgentLens/Services/IrohRelay/HermesIrohRelayHostClient.swift`** — accept-loop fans out by stream class. Today everything routes to `IrohRelayRequestHandler`. Add switch: control + chat frames stay on current handler; `media.*` streams hand off to `MediaSessionCoordinator`.
- **`AgentLens/Services/IrohRelay/HermesRelayHostFanout.swift`** — extend fanout topology to multiplex multiple media streams under one iroh connection.
- **`AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift`** — `attachment.advertise` handler.
- **`AgentLens/Services/SettingsManager.swift`** — seven new flags (`mediaBlobTransferEnabled`, `mediaBlobUIEnabled`, `mediaScreenShareEnabled`, `mediaAudioEnabled`, `mediaVideoEnabled`, `mediaIPadMulticamEnabled`, `mediaMacOSPiPEnabled`) mirrored to Remote Config, plus `mediaKillSwitch` listener.
- **`AgentLens/Services/MacCloudEntitlementStore.swift`** — add `hostedMediaEntitlement` publisher.

### C.3 macOS UI surfaces (`AgentLens/Views/Media/`)

| Surface | Spec |
|---|---|
| **Paperclip in chat send** | 14pt SF Symbol `paperclip` left of input. Hover: `mercuryGradient` tint with `mercuryShimmer` sweep. Click → `NSOpenPanel` (multi-select). Drag-and-drop on chat panel surface routes through same handler. Queued attachments: 28×28 thumbnail strip above input with `+N` chip beyond 3. |
| **"Start mirror" button in popover header** | 1pt `mercuryGradient` ring around 24×24 caduceus→triangle-play glyph. Disabled (50% opacity + `textMuted`) if no iOS pair, or `mediaScreenShareEnabled` off. Cooldown badge (`monoTiny` countdown) for 60 s after last share end. Tap → confirmation popover ("Mirror to iPhone (Alberto)? · 1920×1080 · ≤60 min") with Start / Cancel. |
| **Incoming-call sheet** | Full-window `NSPanel` (level `.floating`, `.transient + .ignoresCycle`). 1pt `mercuryGradient` hairline border. 96pt avatar circle (device-name initial) with `mercuryPulse` ring while ringing. Body: device name in 20pt semibold, "Pair-debug call" subtitle in `caption` `textSecondary`. Decline (left, `error` outline) + Accept (right, `hermesAureate` fill with `mercuryShimmer` highlight on enter). Entry: `stripExpand` spring. |
| **Call HUD** | 1pt `mercuryGradient` hairline at top edge of call window. `mono` 14pt call timer center (mm:ss, switches to hh:mm:ss past 60 min). 44pt circular control buttons row (Mute mic, Mute camera, Share screen, End) with `surfaceElevated` bg + `hermesAureate` icon. Live indicator: 6pt circle, `mercuryGradient`, `mercuryPulse` 1.5 s. End button: `error` on hover, `snappy` (0.15 s easeOut) on press. |
| **Screen-share viewer (Phase 7 only)** | Minimal NSPanel chrome, 1pt `mercuryGradient` border, optional stats overlay top-right (`monoTiny`, `surfaceElevated` 80% bg, `borderSubtle` stroke, `sm` padding). Toggle via three-finger trackpad tap or Settings → Debug. |
| **Attachment row in chat thread** | `ChatBubbleStyle.toolShape` UnevenRoundedRectangle, 1pt `mercuryGradient`. 28pt SF Symbol file glyph left + filename `body` 14pt + `monoTiny` size · percentage second row. Bottom: 2pt `mercuryGradient` line as progress. Complete: collapses, "Open" / "Save to Photos" chip `hermesAureate`. Error: `error` border + "Retry" chip `ember`. |
| **MediaPermissionsView (Settings → Privacy)** | Three rows — Screen Recording / Camera / Microphone — each with status pill ("Allowed" / "Denied" / "Not requested"), SF Symbol indicator, `body` rationale, `hermesAureate` "Open System Settings" deep-link via `x-apple.systempreferences:com.apple.preference.security`. |
| **Mercury ring in menu-bar** | 14pt SF Symbol `circle` with `mercuryGradient` stroke + `mercuryPulse` while any media session active. Tooltip: "Mercury session live — Mirror, Call, or Transfer." Click reveals coordinator state in popover. |

### C.4 TCC + entitlements (Mac)

| Entitlement | Reason | Justification text in Info.plist |
|---|---|---|
| `com.apple.security.device.camera` | Webcam capture for 1:1 video | "OpenBurnBar uses your Mac's camera for one-on-one calls with your paired iPhone." |
| `com.apple.security.device.audio-input` | Mic capture | "OpenBurnBar uses the Mac microphone so you can speak with your paired iPhone during a call." |
| `com.apple.security.device.bluetooth` | AirPods routing | "OpenBurnBar uses Bluetooth to route audio to your AirPods or Bluetooth headset during a call." |
| `NSScreenCaptureUsageDescription` | ScreenCaptureKit | "OpenBurnBar shares your screen with your paired iPhone or iPad during a pair-debug session, so you can demonstrate Hermes Dashboard activity in real time." |

Hardened Runtime entries justified in App Store Connect notes (§G).

---

## D. iOS / iPadOS implementation (OpenBurnBarMobile)

### D.1 New module: `OpenBurnBarMobile/Services/Media/`

| File | Role |
|---|---|
| `CameraCaptureService.swift` | `AVCaptureSession` (iPhone) / `AVCaptureMultiCamSession` (iPad Pro M-series, gated by `AVCaptureMultiCamSession.isMultiCamSupported`). Front 1280×720@24. |
| `MicrophoneCaptureService.swift` | `AVAudioEngine` + Voice-Processing IO. Route-change on `AVAudioSession.routeChangeNotification`. |
| `VideoEncoder.swift` | `VTCompressionSession` HEVC primary, H.264 on A13 / `.serious` thermal. |
| `AudioEncoder.swift` | libopus. |
| `VideoReceivePipeline.swift` | iroh stream → depacketizer → `VTDecompressionSession` → `CMSampleBuffer` → `AVSampleBufferDisplayLayer` (preferred), `MTKView` fallback for unsupported pixel formats. |
| `AudioReceivePipeline.swift` | Datagram → Opus decode → `AVAudioPlayerNode`. Adaptive jitter buffer (60 ms target, packet-loss-rate-driven). |
| `ScreenSharePiPController.swift` | `AVPictureInPictureController` with `AVPictureInPictureControllerContentSource(sampleBufferDisplayLayer:playbackDelegate:)` (iOS 15+). Requires `UIBackgroundModes: audio`. |
| `VoIPCallService.swift` | `PKPushRegistry(.voIP)`, CallKit `CXProvider` + `CXCallController`. On `didReceiveIncomingPushWith` → `CXProvider.reportNewIncomingCall(with:update:completion:)`. VoIP token transmitted to Mac via existing iroh control stream on each successful connect; Mac caches; on rotation, re-uploaded. |
| `MercuryCallTransitionController.swift` | Implements Decision 1: on `CXAnswerCallAction` checks `UIApplication.shared.applicationState`. `.active` → post `MediaCallIncomingNotification`, present Mercury sheet. Else → fulfill action, app launches to `CallHUD`. |
| `FileTransferService.swift` | iroh-blobs fetch on `attachment.advertise`. Background-friendly: handover to `URLSession` background config when QUIC grace period (~30 s) expires (Phase 2 stretch; Phase 1 baseline = "resumable card on next foreground"). |
| `AttachmentSaver.swift` | Implements Decision 3. Per-partner `UserDefaults` save preference. `UIDocumentPickerViewController` for Files, `PHPhotoLibrary.shared().performChanges` for Photos. Settings → Media → Per-partner save preferences view. |
| `MediaSessionCoordinator.swift` | Mirror of Mac coordinator. |
| `MediaCapabilityGate.swift` | Phase-1 placeholder (always-allow on iOS — Mac is source of truth, Decision 2). Reads `media_kill_switch` Remote Config and `ops/media_budget_status/state/current` to refuse if hard-cap engaged before contacting Mac. |

### D.2 Edits to existing iroh path

- **`OpenBurnBarMobile/Services/IrohRelay/HermesIrohRelayTransport.swift`** — stream-class dispatch.
- **`OpenBurnBarMobile/Services/HermesService.swift`** — split `HermesCompositeRelayTransport` so chat and media are sibling transports sharing one iroh connection.
- **`OpenBurnBarMobile/Info.plist`** — `UIBackgroundModes: [voip, audio]`. Usage strings (§G).
- **`OpenBurnBarMobile/Resources/PrivacyInfo.xcprivacy`** — accessed APIs (DiskSpace, FileTimestamp); collected data (audio, video) marked `Linked: false`, `Tracking: false`.
- **`OpenBurnBarMobile/OpenBurnBarMobile.entitlements`** — `aps-environment: production` (PushKit).

### D.3 iOS UI surfaces (`OpenBurnBarMobile/Views/Media/`)

| Surface | Spec |
|---|---|
| **Paperclip in chat input** | 22pt SF Symbol `paperclip` left of input. Tap → action sheet ("Photo Library / Files"). Queued strip identical to Mac. |
| **Attachment bubble** | Same `mercuryGradient`-stroked tool-card pattern as Mac. Image MIME types: 88pt thumbnail (decoded via iroh-blobs `BlobReader::range(0..256KB)`). Tap → quick-look. |
| **CallKit (primary call UI)** | Native iOS system UI handles ringing + lock-screen accept. After accept → foreground to in-app HUD. |
| **MercuryIncomingSheet (foreground only)** | Per Decision 1, presented when CallKit reports incoming and `applicationState == .active`. Mirror of Mac sheet: 1pt `mercuryGradient` hairline, 96pt avatar with `mercuryPulse`, device name, Decline / Accept. Entry: `stripExpand`. Mercury sheet's Accept fulfills the CallKit `CXAnswerCallAction` internally. |
| **In-app call HUD** | Mirror of Mac HUD: 1pt `mercuryGradient` strip top, `mono` 14pt timer, 56pt control row at bottom safe-area. Local self-view 88×128pt PiP in lower-right with drag-to-corner. Mercury hairline on self-view. |
| **Screen-share viewer** | Full-bleed video on safe area with iOS corner radius. Stats overlay (three-finger tap toggle) `monoTiny` `surface` 80% bg `borderSubtle` 1pt. PiP via standard affordance, system-managed on iOS 15+. |
| **MediaPermissionsView (Settings → Privacy)** | Camera + Microphone rows; deep-links to `UIApplication.openSettingsURLString`. |
| **Per-partner save preferences (Settings → Media)** | Implements Decision 3. List of paired Macs with current save choice (Photos / Files / Ask each time) + "Forget this preference" per row + "Forget all" footer. |

### D.4 iPad Pro multicam (Phase 6 only)

`AVCaptureMultiCamSession` on iPad Pro M-series only. UI: front camera primary, back camera as 88×128 PiP in upper-right of local self-view. Falls back to single-cam on iPad mini / older iPad Pro.

### D.5 Background behavior

| State | Behavior |
|---|---|
| App foreground, call active | `AVAudioSession.Category.playAndRecord, .allowBluetooth`. |
| App background, call active | CallKit keeps process alive. Audio continues. Camera capture pauses; receiver sees "Camera paused" overlay. |
| App suspended, incoming call | Mac → APNs VoIP push → iOS wakes process → CallKit shows native UI even on locked phone. Accept → app launches to foreground; per Decision 1, if app is `.active` post-launch, Mercury sheet briefly transitions; else direct to `CallHUD`. |
| App background, screen share active | PiP keeps `AVSampleBufferDisplayLayer` visible system-wide. `UIBackgroundModes: audio` keeps process alive. |
| App background, blob fetch in flight | < 30 s remaining: continue via iroh QUIC. > 30 s: hand off to `URLSession` background config (Phase 2 stretch) or fail with resumable card on foreground (Phase 1 baseline). |
| Entitlement revoked mid-session | Mac → `media.terminate(entitlement_revoked)` → toast "Subscription paused — call ended." All streams torn down within 3 s. |
| Hard-cap engaged mid-session | Mac evaluates `ops/media_budget_status/state/current` every 60 s. Level `hard_cap` → `media.terminate(budget_hard_cap)` with 60 s grace. iOS toast: "Media paused — try again tomorrow." |

---

## E. UI/UX spec (Mercury Rising-compliant)

All surfaces inherit from `DESIGN.md` § Hermes Mercury. **No new color axis.**

**Color tokens reused:** `hermesMercury`, `hermesAureate`, `mercuryGradient`, `ember`, `whimsy`, `surface`, `surfaceElevated`, `border`, `borderSubtle`, `error`, `textPrimary`, `textSecondary`, `textMuted`.

**Motion tokens reused:** `mercuryShimmer` (3 s easeInOut sweep), `mercuryPool` (1.8 s keyframe droplets — repurposed for "connecting"), `mercuryPulse` (1.5 s spring — live indicators, ringing), `stripExpand` (spring response 0.4, damping 0.85 — sheet entry).

**Typography reused:** `display` (28 pt bold — call participant name on incoming sheet), `body` (14 pt — buttons, rationale), `mono` (14 pt — call timer), `monoTiny` (11 pt — stats overlay).

**Glass surfaces reused:** `GlassCard` for the call HUD container; `ChatBubbleStyle.toolShape` for attachment bubbles, file-transfer rows, screen-share start confirmation.

### E.1 In-call HUD (Mac + iOS, parity)

```
┌─ 1pt mercuryGradient hairline ────────────────────────────────────────┐
│                                  03:42                                │
│                                                                       │
│                          ●  (mercuryPulse 4pt, hermesAureate)         │
│                                                                       │
│   ┌───┐    ┌───┐    ┌───┐    ┌───┐                                    │
│   │mic│    │cam│    │scr│    │end│   (44pt circles, surfaceElevated   │
│   └───┘    └───┘    └───┘    └───┘    bg, hermesAureate icons,        │
│                                       end button hovers to error)    │
└───────────────────────────────────────────────────────────────────────┘
```

Stats toggle (off by default, on via Settings → Debug or three-finger tap on iOS / `⌥⌘I` on Mac):

```
1920×1080 · HEVC · 8.2 Mbps · ↓42ms ↑38ms
```

### E.2 Incoming-call sheet (Mac + iOS-foreground per Decision 1)

```
┌─ 1pt mercuryGradient hairline ────────────────────────────────────────┐
│                                                                       │
│                          ╭───────╮                                    │
│                          │   A   │  (96pt circle, mercuryPulse ring)  │
│                          ╰───────╯                                    │
│                                                                       │
│                     Alberto's iPhone 17 Pro                           │
│                       Pair-debug call                                 │
│                                                                       │
│         ┌─────────────┐              ┌─────────────┐                  │
│         │   Decline   │              │   Accept    │                  │
│         │  (error)    │              │ (aureate)   │                  │
│         └─────────────┘              └─────────────┘                  │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
```

`mercuryShimmer` highlight band sweeps left-to-right once on `stripExpand` entry. Accept button glows `mercuryPulse` while ringing.

### E.3 Attachment row in chat thread (Mac + iOS)

```
┌─ ChatBubbleStyle.toolShape, 1pt mercuryGradient ──────┐
│   ┌──┐                                                │
│   │  │  hermes-dashboard-snapshot.png                 │
│   └──┘  4.2 MB · 87%                                  │
│                                                       │
│   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │ (2pt mercury bar)
└───────────────────────────────────────────────────────┘
```

Completed:
```
┌─ ChatBubbleStyle.toolShape, 1pt mercuryGradient ──────┐
│   ┌──┐                                                │
│   │  │  hermes-dashboard-snapshot.png                 │
│   └──┘  4.2 MB                       Open   Save     │
└───────────────────────────────────────────────────────┘
```

Error:
```
┌─ ChatBubbleStyle.toolShape, 1pt error ────────────────┐
│   ┌──┐                                                │
│   │⚠ │  hermes-dashboard-snapshot.png                 │
│   └──┘  Transfer interrupted          Retry           │
└───────────────────────────────────────────────────────┘
```

### E.4 Screen-share start confirmation (Mac popover)

Mercury-stroked `ChatBubbleStyle.toolShape` modal centered on the popover:
```
Mirror to Alberto's iPhone 17 Pro?
1920×1080 · HEVC · 8 Mbps · ≤60 min

         Cancel        Start mirror
```

`Start mirror` is `hermesAureate` with `mercuryShimmer` highlight on hover.

### E.5 Empty / error states (permission denied)

Single SF Symbol (32 pt, `textMuted`): `video.slash`, `mic.slash`, `display.slash`. Below: `body` semibold headline ("Camera access is off"), `caption` `textSecondary` explainer ("OpenBurnBar uses the camera only during pair-debug calls. You can re-enable it in System Settings."), `hermesAureate` "Open Settings" button.

### E.6 Soft / hard-cap UX

**Soft cap engaged** (toast shown once per day at first denial):
```
"High demand — your media quota is reduced today.
 Daily allowance: 30 min screen share, 20 min/call. Quotas restore when demand drops."
```

**Hard cap engaged** (modal sheet on session-start attempt):
```
"Media paused
 We're at our shared bandwidth cap for the month. Media features resume when the budget resets next month.
 [OK]"
```

### E.7 DESIGN.md addendum (decision log per phase)

| Date | Decision | Rationale |
|---|---|---|
| Phase 1 ship | Attachment row uses `ChatBubbleStyle.toolShape` + `mercuryGradient` 1pt | Inherits from existing tool-card; attachments look like first-class Hermes outputs. |
| Phase 2 ship | Per-partner save preference UI in Settings → Media | Decision 3. Action sheet on first image; persistent `UserDefaults` keyed by `peerDeviceId`. |
| Phase 3 ship | Call HUD top hairline 1pt `mercuryGradient` | Quietest possible "live" affordance; `mercuryPulse` dot completes the signal without screaming. |
| Phase 5 ship | Decline `error`, Accept `hermesAureate` with `mercuryShimmer` | Mercury identity wins on accept; ember reserved for completion-clock; error red unambiguous for decline. |
| Phase 5 ship | CallKit primary + Mercury foreground sheet | Decision 1. CallKit owns the wake-from-suspended path; Mercury sheet swaps in when the app is already active. |

---

## F. Premium gating + quotas

### F.1 SKU strategy (Decision 5)

| SKU | Product ID | Cost | What it gates |
|---|---|---|---|
| `hosted_quota_sync` (existing) | `com.openburnbar.hostedQuotaSync.cloud.monthly` | $4.99/mo | Cloud quota sync, Hermes hosted relay (chat) |
| `hosted_media_sync` (new — Phase 2) | `com.openburnbar.hostedMediaSync.monthly` | $9.99/mo | File transfer, screen share, video calling |
| `burnbar_pro` (umbrella) | `com.openburnbar.pro.monthly` | $14.99/mo | Both |

Entitlement document shape:
```
users/{uid}/entitlements/hosted_media_sync:
  active: true
  productID: "com.openburnbar.hostedMediaSync.monthly"
  expireAt: <timestamp>
  features:
    fileTransfer: true
    screenShare: true
    videoCall: true
```

Phase 1 reuses `hosted_quota_sync` as the gate; Phase 2 introduces the new SKU. Existing `hosted_quota_sync` subscribers receive a 90-day media-grandfather grant via server function `grantMediaGrandfather`.

### F.2 Quota envelope (Firestore + local cache)

```
users/{uid}/media_quota_usage/{YYYY-MM-DD}:
  bytesUploadedFile: int
  bytesDownloadedFile: int
  fileTransfersInitiated: int
  fileTransfersFailed: int
  screenShareSecondsUsed: int
  screenShareSessions: int
  videoCallSecondsUsed: int
  videoCallSessions: int
  updatedAt: timestamp
```

Caps (normal mode):
- File: 5 GB in + 5 GB out · 1 GB / file · 4 concurrent · 50 transfers
- Screen share: 120 min/day · 60 min/session · 1 concurrent
- Video call: 240 min/day · 30 min/call · 1 concurrent

### F.3 Budget-aware auto-tightening (Decision 4)

Cloud Function `evaluateMediaBudget` (scheduled hourly, `functions/src/mediaBudget.ts`):
1. Reads n0 services API for month-to-date hosted-relay bytes.
2. Reads `ops/media_session_daily_rollups/days/*` for the current month.
3. Projects month-end at current daily rate.
4. Writes `ops/media_budget_status/state/current`:
   ```
   {
     level: "normal" | "soft_cap" | "hard_cap",
     projectedMonthEndUSD: number,
     monthToDateUSD: number,
     lastEvaluatedAt: timestamp,
     activeEnvelope: {
       screenShareDailyMinutes: number,
       screenSharePerSessionMinutes: number,
       videoCallDailyMinutes: number,
       videoCallPerCallMinutes: number,
       fileTransferDailyGBIn: number,
       fileTransferDailyGBOut: number
     }
   }
   ```
5. On level transition, fires `media_budget_level_changed` Analytics event.

Both apps cache `ops/media_budget_status/state/current` for 60 s and re-read on session-start. At `hard_cap`, `media_kill_switch` Remote Config flag also flips for belt-and-suspenders.

### F.4 Enforcement (three layers, Decision 2 applied)

1. **Mac host gate (primary)** — `MediaCapabilityGate.check(feature:duration:bytes:)` reads `MacCloudEntitlementStore` + local quota counters + budget status. Returns `.allowed` / `.denied(reason: enum)`. Mac is source of truth (Decision 2).
2. **Control-plane reconcile** — Mac writes `media_quota_usage/{day}` every 30 s during active session in batched updates. Server-side `recomputeMediaQuotaUsage` corrects drift hourly. Firestore rules: owner-only, rate-limited via `_rate_limits/media_quota_writes`.
3. **iroh accept-loop gate (secondary)** — on each new `media.*` stream open, Mac's accept-loop re-checks entitlement freshness (cached 60 s). Refuses streams if entitlement expired, daily cap hit, or kill-switch active. Sends `media.denied(reason)` and closes the stream.

iOS-side check is informational only (Decision 2). It surfaces the same `media_budget_status` toast so the user knows why a call won't start, but the Mac is the actual gate.

Mid-session revocation: `MacCloudEntitlementStore.publisher` fires → `MediaSessionCoordinator.terminateAll(reason: .entitlementRevoked)` → `media.terminate` per stream → 3 s grace → forceful close. Toast on both ends.

---

## G. Privacy & compliance

### G.1 Info.plist usage strings

**iOS (`OpenBurnBarMobile/Info.plist`):**
- `NSCameraUsageDescription`: "OpenBurnBar uses the camera so you can show your iPhone screen, environment, or face to your paired Mac during a pair-debug call."
- `NSMicrophoneUsageDescription`: "OpenBurnBar uses the microphone so your voice can reach your paired Mac during a pair-debug call."
- `NSPhotoLibraryAddUsageDescription`: "OpenBurnBar can save screenshots and exports sent from your Mac directly into your Photos library."
- `UIBackgroundModes`: `[voip, audio]`

**macOS (`AgentLens/Info.plist`):**
- `NSScreenCaptureUsageDescription`: "OpenBurnBar shares your screen with your paired iPhone or iPad during a pair-debug session, so you can demonstrate Hermes Dashboard activity in real time."
- `NSCameraUsageDescription`: "OpenBurnBar uses your Mac's camera for one-on-one calls with your paired iPhone."
- `NSMicrophoneUsageDescription`: "OpenBurnBar uses the Mac microphone so you can speak with your paired iPhone during a call."
- `NSBluetoothAlwaysUsageDescription`: "OpenBurnBar uses Bluetooth to route audio to your AirPods or Bluetooth headset during a call."

### G.2 PrivacyInfo.xcprivacy (both apps)

`NSPrivacyAccessedAPITypes`:
- `NSPrivacyAccessedAPICategoryDiskSpace` (reason: `35F9.1` — gate blob cache against full disk)
- `NSPrivacyAccessedAPICategoryFileTimestamp` (reason: `C617.1` — attachment metadata for chat history)

`NSPrivacyCollectedDataTypes`:
- `NSPrivacyCollectedDataTypeAudioData` — Linked: false · Tracking: false · Purposes: `NSPrivacyCollectedDataTypePurposeAppFunctionality`
- `NSPrivacyCollectedDataTypeVideoOrImages` — same flags

### G.3 App Store review notes addendum

> OpenBurnBar Mercury Rising enables remote pair-debug sessions between a paired Mac and iPhone/iPad. The user explicitly initiates each session ("Start mirror" in menu-bar popover, or "Start call" from chat panel). The macOS menu-bar shows a mercury indicator ring whenever screen recording is active, beyond the system orange-dot indicator Apple already requires. Screen recording is never automatic, never background, and never shares data outside the paired devices — bytes travel directly between the Mac and the iPhone over the iroh peer-to-peer transport with end-to-end encryption.

Includes pre-recorded screen-capture walkthrough video link.

### G.4 GDPR / CCPA

**Centrally logged** (Firebase Analytics + Firestore): session count, duration buckets, RTT buckets, freeze-count buckets, transfer success/failure counts, quota usage aggregates.

**Never logged:** filenames, blob hashes, screen content, camera/mic samples, peer NodeIds in plaintext, chat content alongside media events.

**Local-only:** Mac and iOS cache incoming blobs in app sandbox. Auto-purged after 7 days (configurable in Settings → Storage). One-tap wipe.

**DSR export:** existing flow (`docs/PRIVACY.md`) extended to include `media_session_events` and `media_quota_usage` rollups.

---

## H. Observability

### H.1 Firebase Analytics events (no media payload, all bucketed enums)

| Event | Params |
|---|---|
| `media_session_started` | `feature`, `transport`, `isHostedRelay` |
| `media_session_ended` | `feature`, `durationBucket` (<30s, 30s-2m, 2-10m, 10-30m, 30-60m), `endReason` (user / peer / timeout / error / entitlement / budget), `freezeCountBucket` (0, 1-3, 4-10, >10), `p95RTTBucket` (<50ms, 50-150, 150-400, >400), `p95BitrateBucket` |
| `media_transfer_completed` | `sizeBucket` (<1MB, 1-10MB, 10-100MB, 100MB-1GB, >1GB), `durationBucket`, `didResume` |
| `media_transfer_failed` | `sizeBucket`, `failureCode` (drop / hash / quota / permission / peer) |
| `media_quota_denied` | `feature`, `quotaReason` (entitlement / daily / concurrent / session-cap / soft-cap / hard-cap) |
| `media_budget_level_changed` | `fromLevel`, `toLevel`, `projectedMonthEndUSDBucket` |

### H.2 Reuse `iroh_audit_events`

New event types: `media_stream_opened`, `media_stream_closed`, `media_stream_error`, `media_session_ended`. Always carry `streamClass` (`media.video.out`, `media.audio.in`, etc.). BWE samples summarized in the close event, not streamed.

### H.3 Rollups

NEW scheduled Cloud Function `rollupMediaSessionDaily` (`functions/src/mediaMonitoring.ts`) mirrors `rollupIrohTransportDaily`. Reads `users/{uid}/iroh_audit_events` filtered to `streamClass` starting with `media.` + `users/{uid}/media_session_events`. Outputs `ops/media_session_daily_rollups/days/{YYYY-MM-DD}`: per-feature p50/p95/p99 RTT, freeze rate, success rate, fallback rate, total minutes, total bytes.

### H.4 Budget monitor

`ops/media_budget_status/state/current` is the canonical budget surface. Read by Mac + iOS at session start. Written hourly by `evaluateMediaBudget`. Dashboard: BigQuery export to Looker Studio with a `media-budget-status` board showing daily spend trend, projection, kill-switch state.

### H.5 On-device debug logger

`MediaSessionLogger` writes 5-min rolling JSONL in app sandbox: RTT samples, bitrate adaptations, encoder errors, frame-drop reasons. Never frames. Exportable from Settings → Advanced → "Export last session diagnostics".

---

## I. Phasing summary

Each phase exits with: tests green · `docs/HERMES_IROH_TRANSPORT.md` updated · `CHANGELOG.md` entry · `DESIGN.md` decision-log entry · `docs/runbooks/media-rollout-status.md` entry · ≥ 7-day soak before next phase's flag flips on for > 5% of users.

| Phase | Theme | Flag | Duration |
|---|---|---|---|
| 1 | iroh-blobs file send/receive (no UI) | `media_blob_transfer_enabled` | ~1 week |
| 2 | File send UI in chat (Mac + iOS) + `hosted_media_sync` SKU launch | `media_blob_transfer_ui_enabled` | ~2 weeks |
| 3 | Mac → iOS one-way screen share (no audio) | `media_screen_share_enabled` | ~3 weeks |
| 4 | Mac ⇄ iOS audio | `media_audio_enabled` | ~2 weeks |
| 5 | Mac ⇄ iOS video + CallKit/PushKit + Mercury foreground sheet | `media_video_enabled` | ~4 weeks |
| 6 | iPad multicam + PiP | `media_ipad_multicam_enabled` | ~2 weeks |
| 7 | macOS PiP / always-on-top viewer | `media_macos_pip_enabled` | ~1 week |

**Total:** ~15 weeks of engineering. Plus a ≥ 7-day soak between each adjacent flag step.

---

## J. Tests (project-wide)

### J.1 Unit tests (per-platform)

| Module | Targets |
|---|---|
| `IrohBlobsAdapter` | Ticket round-trip · resume after disconnect at 50% · hash mismatch rejection · 2 GB chunked progress |
| `MediaPacketCodec` | Variable-length frame parse · oversize rejection (>256 KiB) · GOP boundary metadata round-trip · forward compat (unknown field tolerated) |
| `BitrateController` | RTT spike triggers down-adapt within 200 ms · smooth recovery · loss-rate-driven · ceiling enforcement |
| `OpusFramer` | 20 ms framing · jitter buffer reordering 3 out-of-order packets · PLC on 1 lost packet · 60 ms jitter |
| `VideoEncoder` | HEVC round-trip · H.264 probe · keyframe interval = 2 s · thermal adapt |
| `ScreenCaptureKitMock` | Mock SCStream 30 fps over 60 s with 0 drops nominal · drops at `.serious` |
| `MediaCapabilityGate` | Entitlement-missing · expired · daily-cap · concurrent-session · soft-cap · hard-cap |
| `MediaBudgetGate` | Soft-cap envelope applied · hard-cap denial · normal recovery |
| `AttachmentSaver` | Per-partner UserDefaults persistence · Photos vs Files routing · forget-preference |
| `MercuryCallTransition` | App-active → Mercury sheet · app-background → direct CallHUD · CallKit transition < 200 ms |

### J.2 Integration tests

| Test | Scope |
|---|---|
| `MediaLoopbackBlobTransfer` | Single Mac process, two iroh nodes, 100 MB blob send/receive, BLAKE3 round-trip |
| `MediaLoopbackVideoCall` | Two-node loopback, bidirectional video + audio for 30 s, decoded buffers match encoded modulo codec tolerance |
| `MediaLoopbackScreenShare` | Mac → mock-iOS loopback, 5-min HEVC stream, no GOP loss, BWE converges within 5 s |
| `MediaCallKitFlow` | XCUITest simulating PushKit → CallKit → accept → CallHUD across foreground / background states |

### J.3 Device matrix (TestFlight + lab)

| Device | Phase 3 (share) | Phase 4 (audio) | Phase 5 (video) | Phase 6 (multicam) |
|---|---|---|---|---|
| iPhone 13 mini (A15) | ✓ receive | ✓ both | ✓ H.264 outbound | n/a |
| iPhone 15 Pro (A17 Pro) | ✓ | ✓ | ✓ HEVC | n/a |
| iPhone 17 Pro Max | ✓ | ✓ | ✓ HEVC | n/a |
| iPad mini 6 | ✓ | ✓ | ✓ H.264 | n/a |
| iPad Pro M4 | ✓ + PiP | ✓ | ✓ HEVC | ✓ multicam |
| Mac Intel Core i7 (Skylake+) | ✓ encode | ✓ | ✓ HEVC | host-only |
| Mac M1 | ✓ | ✓ | ✓ | host-only |
| Mac M3 / M4 | ✓ | ✓ | ✓ | host-only |

Per device per phase: 10-min soak call · 100 MB file transfer · 5-min screen share. Record p50/p95/p99 RTT, freeze count, encoder failures into `docs/runbooks/media-device-matrix/{phase}.md`.

### J.4 Chaos tests

| Test | Scenario | Expected |
|---|---|---|
| `ChaosMidCallNATChange` | iPhone Wi-Fi → cellular handoff via Network Link Conditioner | iroh holepunch breaks; relay fallback resumes within 4 s; CallKit stays active |
| `ChaosMidTransferDrop` | Kill QUIC stream at 50% of 100 MB blob | Resume from ticket within 8 s · no duplicate bytes · final hash matches |
| `ChaosEntitlementRevoked` | Firestore entitlement flipped to `active: false` mid-call | Mac sends `media.terminate(entitlement_revoked)` within 5 s · UIs degrade within 3 s |
| `ChaosThermalCritical` | Force `.critical` thermal on iPhone during video | Mac receives `media.terminate(thermal)` within 3 s · "Call ended — iPhone overheated" |
| `ChaosBackgroundedMidShare` | iPhone backgrounds during screen-share viewing | PiP enters within 200 ms · audio (if present) continues · re-attach on foreground without re-handshake |
| `ChaosSoftCapEngages` | Manually flip `media_budget_status` to `soft_cap` during active video call | Envelope tightens for next session; current session continues to its 30-min cap then terminates |
| `ChaosHardCapEngages` | Manually flip `media_budget_status` to `hard_cap` during active video call | Both sides receive `media.terminate(budget_hard_cap)` within 5 s; modal sheet shown |
| `ChaosVoIPTokenRotation` | Force iPhone VoIP token rotation while paired Mac is offline | Next iroh connect uploads fresh token; old token's `triggerVoIPCall` fails cleanly with "device unreachable" |

---

## K. Risks (ranked) + mitigations

1. **iOS background suspension during long transfers** — PushKit VoIP push wakes iPhone reliably for incoming calls; CallKit mandates continued execution. `UIBackgroundModes: audio` keeps PiP alive. For blob transfers > 30 s past backgrounding, hand off to `URLSession` background config (Phase 2 stretch); Phase 1 baseline = "fail with resumable card on next foreground."

2. **Battery and thermal cost of HEVC encode on iPhone** — Probe via `MTLDevice.supportsFamily(.apple7)` → A14+ HEVC. A13 and below default to H.264. Thermal monitor downscales on `.serious`, terminates on `.critical`. Max 30 min/call enforced. Measured target: ≤ 8% battery / 30 min on iPhone 15 Pro.

3. **Audio echo / route changes when AirPods connect mid-call** — Voice-Processing IO (Apple AEC). Listen to `AVAudioSession.routeChangeNotification` (iOS) + `AudioObjectAddPropertyListener` (Mac). Pause audio 200 ms during reinit, crossfade. Test matrix: AirPods Pro 2, AirPods Max, generic BT, wired USB-C.

4. **App Store review pushback on always-on screen recording** — (a) macOS menu-bar mercury ring while recording (visual indicator beyond Apple's orange dot); (b) screen share starts only on explicit "Start mirror" tap; (c) Privacy Manifest explicit; (d) pre-recorded reviewer walkthrough video; (e) toggleable per-feature in Settings → Privacy.

5. **Inconsistent NAT traversal on cellular IPv6 (CGNAT)** — iroh-relay path exists. `iroh-relay` transport in audit events triggers UI hint "Connected via relay — direct unavailable." User action: Wi-Fi for screen share; calls work fine over relay (within bandwidth quota).

6. **iroh-0.91 unstable API surface (especially iroh-blobs)** — Pin exact version. CI workflow fails on blob-crate version mismatch. Re-spin xcframework on iroh upgrade with full Phase A regression. iroh-blobs surface limited to two UniFFI functions — easy to re-pin to a stable shim.

7. **VoIP push token rotation race** — iPhone re-uploads token via existing iroh control stream on every successful connect. Mac caches; on `triggerVoIPCall` failure (APNs invalid-token), Mac drops cache and requests fresh on next iroh connection. iPhone offline at rotation time → "call invite" via Firestore long-poll fallback transport.

8. **Hosted-relay bandwidth blowout** — Per-user daily envelope + `evaluateMediaBudget` projection + soft/hard caps (Decision 4). n0 dashboard alerts at 75% / 100% / 150%. Kill-switch via Remote Config + `ops/media_budget_status/state/current`.

9. **Encoder-decoder version skew** (Mac on new VT API, iOS on older) — Capability handshake in `media.control` opening frame. Both sides advertise codecs + profiles; encoder picks intersection (HEVC main → H.264 baseline → fail with `unsupported_codec` toast).

10. **Race on iroh `accept_one` between media and chat streams** — Stream-class dispatch table in accept-loop is constant-time. Each accepted stream gets a typed handler within 1 ms. Telemetry on accept-loop p99 latency in `iroh_audit_events`.

11. **CallKit foreground-transition flash** (Decision 1 cost) — Keep transition < 200 ms via pre-warmed `CallHUD` rendering and `MercuryIncomingSheet` instance held by the app delegate. `MercuryCallTransition` integration test asserts the < 200 ms budget.

12. **Per-partner save-preference key collision** — `peerDeviceId` is the iroh `NodeId` (52 chars base32, globally unique). No collision risk. Settings UI exposes "Forget all" to clear stale partners.

---

## L. Files-to-touch inventory

### Shared SwiftPM (`OpenBurnBarCore/Sources/`)
- **NEW** `OpenBurnBarMedia/` target
  - `MediaFrame.swift` · `MediaPacketCodec.swift` · `MediaStreamClass.swift` · `BitrateController.swift` · `MediaSessionMetadata.swift` · `MediaCapabilityGate.swift` (protocol) · `MediaBudgetEnvelope.swift`
- **NEW** `OpenBurnBarMediaTests/` target
- **EDIT** `OpenBurnBarCore/Package.swift` — add `OpenBurnBarMedia` target with conditional Opus binary target dependency

### Rust (`crates/openburnbar-iroh/`)
- **EDIT** `src/lib.rs` — expose `publish_blob`, `fetch_blob`, `bytes_in_flight` UniFFI functions
- **EDIT** `Cargo.toml` — `iroh-blobs` feature-gate stays; no version bump unless needed
- **NEW** `crates/openburnbar-iroh/src/blobs.rs` — module that wraps the iroh-blobs surface (`BlobStore`, `BlobTicket`, `publish`, `fetch`)

### macOS (`AgentLens/Services/Media/` — NEW directory)
- `ScreenCapturePipeline.swift` · `CameraCapturePipeline.swift` · `MicrophoneCapturePipeline.swift` · `VideoEncoder.swift` · `AudioEncoder.swift` · `FileTransferService.swift` · `MediaSessionCoordinator.swift` · `MediaCapabilityGate.swift` (impl) · `MediaSessionLogger.swift` · `VoIPCallTrigger.swift` · `MediaBudgetReader.swift`
- **EDIT** `AgentLens/Services/IrohRelay/HermesIrohRelayHostClient.swift` — stream-class fanout
- **EDIT** `AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift` — `attachment.advertise` handler
- **EDIT** `AgentLens/Services/IrohRelay/HermesRelayHostFanout.swift` — multi-stream session multiplexing
- **EDIT** `AgentLens/Services/SettingsManager.swift` — seven new flags + `mediaKillSwitch` listener + media SKU entitlement listener
- **EDIT** `AgentLens/Services/MacCloudEntitlementStore.swift` — add `hostedMediaEntitlement` publisher
- **EDIT** `AgentLens/Info.plist` — usage strings (§G.1)
- **EDIT** `AgentLens/AgentLens.entitlements` — `device.camera`, `device.audio-input`, `device.bluetooth`

### macOS UI (`AgentLens/Views/Media/` — NEW directory)
- `IncomingCallSheet.swift` · `CallHUD.swift` · `ScreenShareViewer.swift` · `AttachmentChipRow.swift` · `MediaPermissionsView.swift` · `MercuryRing.swift` (menu-bar live-share indicator) · `MediaBudgetBanner.swift` (soft-cap notice)
- **EDIT** `AgentLens/Views/Chat/<current dashboard chat panel>.swift` — paperclip glyph + attachment queue strip
- **EDIT** `AgentLens/Views/Popover/<popover header>.swift` — "Start mirror" mercury-bordered button + Mercury ring container
- **EDIT** `AgentLens/Settings/<settings root>.swift` — new "Media & Sharing" panel

### iOS (`OpenBurnBarMobile/Services/Media/` — NEW directory)
- `CameraCaptureService.swift` · `MicrophoneCaptureService.swift` · `VideoEncoder.swift` · `AudioEncoder.swift` · `VideoReceivePipeline.swift` · `AudioReceivePipeline.swift` · `ScreenSharePiPController.swift` · `VoIPCallService.swift` · `MercuryCallTransitionController.swift` · `FileTransferService.swift` · `AttachmentSaver.swift` · `MediaSessionCoordinator.swift` · `MediaCapabilityGate.swift` (impl, Phase-1-placeholder) · `MediaBudgetReader.swift`
- **EDIT** `OpenBurnBarMobile/Services/IrohRelay/HermesIrohRelayTransport.swift` — stream-class dispatch
- **EDIT** `OpenBurnBarMobile/Services/HermesService.swift` — split `HermesCompositeRelayTransport`; expose sibling `MediaRelayTransport`
- **EDIT** `OpenBurnBarMobile/Info.plist` — usage strings · `UIBackgroundModes: [voip, audio]`
- **EDIT** `OpenBurnBarMobile/Resources/PrivacyInfo.xcprivacy` — accessed APIs + collected data
- **EDIT** `OpenBurnBarMobile/OpenBurnBarMobile.entitlements` — `aps-environment: production` (PushKit)

### iOS UI (`OpenBurnBarMobile/Views/Media/` — NEW directory)
- `CallHUDView.swift` · `ScreenShareViewerView.swift` · `AttachmentBubble.swift` · `MediaPermissionsView.swift` · `SelfPiPView.swift` · `MercuryIncomingSheet.swift` · `PerPartnerSavePreferencesView.swift` · `MediaBudgetBanner.swift`
- **EDIT** `OpenBurnBarMobile/Views/Chat/<chat row>.swift` — attachment slot
- **EDIT** `OpenBurnBarMobile/Views/Chat/<chat input>.swift` — paperclip glyph
- **EDIT** `OpenBurnBarMobile/Settings/<settings root>.swift` — "Media & Privacy" panel

### Cloud Functions (`functions/src/`)
- **NEW** `mediaMonitoring.ts` — `rollupMediaSessionDaily`
- **NEW** `mediaQuota.ts` — `recomputeMediaQuotaUsage`
- **NEW** `mediaBudget.ts` — `evaluateMediaBudget` + `grantMediaGrandfather`
- **NEW** `voipPush.ts` — `triggerVoIPCall(uid, deviceToken, payload)` (verifies Mac-side entitlement per Decision 2)
- **EDIT** `functions/src/types.ts` — `MediaSessionEventDoc`, `MediaQuotaUsageDoc`, `MediaAttachmentManifestDoc`, `MediaSessionDailyRollupDoc`, `MediaBudgetStatusDoc`. Cloud-visible metadata only; never payload.
- **EDIT** `functions/src/index.ts` — exports

### Rules
- **EDIT** `firestore.rules` — gate `users/{uid}/media_quota_usage/{day}`, `users/{uid}/media_session_events/{eventId}`, `users/{uid}/media_attachment_manifests/{id}`, `users/{uid}/entitlements/hosted_media_sync`, `ops/media_budget_status/{doc}` (server-only writes, public read). Helper `hasActiveHostedMediaEntitlement(userId)` mirroring existing entitlement helpers.
- **No edit** to `storage.rules`. Media bytes are E2E peer-to-peer; nothing new in Firebase Storage.

### Design + docs
- **EDIT** `DESIGN.md` — "Mercury HUD" subsection (in-call HUD geometry, call-timer typography, control buttons, attachment row, viewer chrome, decision log per phase)
- **EDIT** `docs/HERMES_IROH_TRANSPORT.md` — "Media stream classes" section
- **NEW** `docs/HERMES_MEDIA_TRANSPORT.md` — full architecture spec (this plan, pruned to operator/engineer reference)
- **NEW** `docs/runbooks/media-quota.md` — quota disputes, manual reset
- **NEW** `docs/runbooks/media-budget.md` — soft / hard cap operations, n0 dashboard runbook
- **NEW** `docs/runbooks/media-rollout-status.md` — phase log mirroring `iroh-rollout-status.md`
- **NEW** `docs/runbooks/media-device-matrix/` — per-phase device-matrix results
- **EDIT** `CHANGELOG.md` — entry per phase ship

### CI / Tooling
- **NEW** `Vendor/Opus.xcframework` — precompiled libopus for macOS + iOS + iOS Simulator (parallels `Vendor/OpenBurnBarIroh.xcframework`)
- **NEW** `scripts/build-opus-xcframework.sh` — reproducible recipe
- **NEW** `.github/workflows/media-loopback-test.yml` — runs `MediaLoopback*Tests` on `macos-14-large`

---

## Per-phase implementation specs

---

### Phase 1 — iroh-blobs file send/receive foundation (no UI polish)

**Goal:** smallest end-to-end slice — real Mac sends real 5 MB screenshot over iroh-blobs to real iPhone in TestFlight build.
**Flag:** `media_blob_transfer_enabled` (Remote Config + UserDefaults). Off by default.
**Duration estimate:** ~1 week.

**Inclusion:**
- Rust: `publish_blob(local_path: String) -> BlobTicket` and `fetch_blob(ticket: BlobTicket, destination: String, progress: ProgressCallback) -> Result<TransferStats>` exposed via UniFFI in `crates/openburnbar-iroh/src/lib.rs`. New `src/blobs.rs` module wraps the iroh-blobs surface.
- Re-spin `Vendor/OpenBurnBarIroh.xcframework` via `scripts/build-iroh-xcframework.sh`. Re-run CI workflow `OpenBurnBarIroh xcframework`.
- NEW SwiftPM target `OpenBurnBarMedia` in `OpenBurnBarCore/Package.swift` with `MediaFrame.swift` (defines `MediaFrame.attachmentAdvertise(BlobTicket, MediaAttachmentMeta)`), `MediaStreamClass.swift` (`.blob`), `MediaPacketCodec.swift` (reuses `IrohRelayFrameCodec` length-prefix base).
- Mac (`AgentLens/Services/Media/FileTransferService.swift`): calls `publish_blob`; emits `attachment.advertise` on existing Hermes control stream. Entry: hidden Cmd+Option+Click on `HermesDashboardChatPanel` input → `NSOpenPanel` (file types `[.image, .png, .jpeg, .pdf, .plainText, .json]`, ≤ 100 MB Phase-1 cap).
- iOS (`OpenBurnBarMobile/Services/Media/FileTransferService.swift`): on receiving `attachment.advertise` over Hermes control stream → `fetch_blob` to `Library/Caches/MediaInbox/{blobHash}.{ext}`. Stub UI: `Text("📎 \(filename) · Save…")` button triggers `UIDocumentPickerViewController` (export) or `PHPhotoLibrary.shared().performChanges` for image MIME types.
- New stream class `media.blob` registered in iroh ALPN list. Stream-class dispatch in `HermesIrohRelayHostClient` (Mac) and `HermesIrohRelayTransport` (iOS).

**Cloud / rules:** `functions/src/types.ts` defines `MediaAttachmentManifestDoc { uid, manifestId, blobHash (string), filename, mime, size, peerDeviceId, createdAt }` — compile-only, no writes yet. No Firestore rules change in Phase 1.

**Privacy:** `OpenBurnBarMobile/Info.plist`: `NSPhotoLibraryAddUsageDescription` only (no iOS background mode changes; no Mac changes).

**Tests:**
- **Rust**: `cargo test -p openburnbar-iroh blob_round_trip` — same-node publish + fetch round trip.
- **Swift unit**: `IrohBlobsAdapterTests`, ticket serialization, error mapping, progress monotonicity (≥ 4 tests).
- **Swift integration**: `MediaLoopbackBlobTransferTests` — single-process loopback via `LoopbackIrohRelayTransport`, 5 MB blob with BLAKE3 round-trip assertion (≥ 2 tests).
- **End-to-end manual**: real Mac (M3) on Wi-Fi → real iPhone 17 Pro on cellular, 5 MB PNG screenshot. `iroh_audit_events` shows `iroh_stream_opened` with `streamClass: "media.blob"` and `iroh_stream_closed` success. Wall-clock < 15 s on 50 Mbps. Zero plaintext crosses Firebase. Photos shows saved image with intact EXIF.

**Docs:**
- Append "Phase 1 media stream class" subsection to `docs/HERMES_IROH_TRANSPORT.md`.
- NEW `docs/HERMES_MEDIA_TRANSPORT.md` skeleton (Phase 1 details).
- NEW `docs/runbooks/media-rollout-status.md` (Phase 1 entry).
- `CHANGELOG.md`: `feat(media): iroh-blobs file transfer foundation — Phase 1 (off by default)`.
- `DESIGN.md` decision-log: "Phase 1 file transfer: no UI polish; chat thread shows minimal `📎` chip; `mercuryGradient` styling lands in Phase 2."

**Acceptance gate (all four):**
1. CI workflow `OpenBurnBarIroh xcframework` green on PR head commit.
2. `swift test` green in `OpenBurnBarCore/` with new `OpenBurnBarMedia` target (≥ 8 new tests).
3. TestFlight build accepts 5 MB blob from paired Mac and saves to Photos. 3 consecutive runs across 2 network topologies (LAN + LTE).
4. `iroh_audit_events` exports under `docs/runbooks/media-rollout-status.md` showing expected stream open/close for each run, zero `iroh_fallback_to_wss`.

**Out of scope (deferred to Phase 2):**
- Paperclip UI · `hosted_media_sync` SKU · drag-and-drop on Mac · attachment thumbnail in chat · per-partner save preference · MediaPermissionsView · anything camera / mic / screen.

---

### Phase 2 — File send UI + `hosted_media_sync` SKU launch

**Goal:** production-quality file transfer UX on both platforms and the new entitlement live in StoreKit.
**Flag:** `media_blob_transfer_ui_enabled`.
**Duration estimate:** ~2 weeks.

**Inclusion:**
- **Mac UI**: paperclip glyph in chat send (left of input), drag-and-drop on chat panel surface, multi-file queue strip with `+N` chip, `AttachmentChipRow` inline in chat thread (3 states: in-flight / complete / error per §E.3). Touches `AgentLens/Views/Chat/<dashboard chat panel>.swift`.
- **iOS UI**: paperclip in chat input, action-sheet entry (Photo Library / Files), `AttachmentBubble` in chat thread with thumbnail preview (image MIME types: 88pt thumbnail decoded from partial blob via `BlobReader::range(0..256KB)`). `Quick Look` on tap → full image with Save to Photos / Share Sheet.
- **Per-partner save preference (Decision 3)**: `AttachmentSaver.swift` reads `UserDefaults.media.savePreference.<peerDeviceId>`. First image from a partner: action sheet "Save to Photos / Save to Files"; choice persisted. Settings → Media → `PerPartnerSavePreferencesView` lists peers with current choice + per-row "Forget" + global "Forget all".
- **SKU migration**:
  - StoreKit: new product `com.openburnbar.hostedMediaSync.monthly` ($9.99) configured in App Store Connect (manual step — coordinate with Alberto).
  - Server: new Cloud Function `grantMediaGrandfather` runs once for each existing `hosted_quota_sync` subscriber, writing `users/{uid}/entitlements/hosted_media_sync` with `expireAt` = now + 90 days, `features: { fileTransfer: true, screenShare: false, videoCall: false }`.
  - Firestore rules: gate `users/{uid}/entitlements/hosted_media_sync` (existing pattern via helper `hasActiveHostedMediaEntitlement`).
- **MediaAttachmentManifestDoc** writes go live (`functions/src/types.ts` already defined in Phase 1). Stores filename, MIME, size, BLAKE3 hash, peer device id. Firestore rules: owner-only, schema-validated.
- **MediaQuotaUsage** writes go live. `recomputeMediaQuotaUsage` Cloud Function (scheduled hourly) ships.

**Cloud / rules:**
- NEW `functions/src/mediaQuota.ts` (`recomputeMediaQuotaUsage`).
- NEW `functions/src/mediaSku.ts` (`grantMediaGrandfather`, `validateMediaPurchase`).
- EDIT `functions/src/types.ts` — `MediaQuotaUsageDoc` exported and used.
- EDIT `firestore.rules` — three new collections gated.

**Privacy:** No new permissions in Phase 2 beyond Phase 1's photo-library-add.

**Tests:**
- **Unit**: `AttachmentSaverTests` (per-partner preference persistence, Photos vs Files routing, forget-preference, forget-all). `MediaQuotaGateTests` (daily-cap denial, concurrent-cap denial).
- **Integration**: snapshot UI tests for `AttachmentBubble` (light / dark / large-type / error states) on both platforms. Quota-cap enforcement test (simulate 50 GB uploaded → expect denial).
- **Manual**: end-to-end SKU purchase flow on TestFlight; existing `hosted_quota_sync` subscriber sees grandfather grant; new purchase activates within 60 s.

**Docs:**
- `DESIGN.md` decision-log: "Per-partner save preferences in Settings → Media; action sheet only on first image per partner."
- `docs/HOSTED_QUOTA_SYNC.md` — extend with media SKU section.
- NEW `docs/HOSTED_MEDIA_SYNC.md` — SKU details, grandfather window, per-feature toggles.
- `CHANGELOG.md` entry.

**Acceptance gate:**
1. App Store-connect new SKU live in production.
2. ≥ 10 TestFlight users complete end-to-end image send + receive on first try (no error).
3. Grandfather grant confirmed for all existing `hosted_quota_sync` subscribers (Firestore query).
4. UI snapshot tests green; quota-cap enforcement test green; ≥ 12 new unit tests.
5. 7-day soak with flag on for internal users; ≤ 2% transfer failure rate.

**Out of scope (Phase 3+):**
- Screen sharing · audio · video · CallKit · iPad multicam · macOS PiP · soft / hard budget caps (rolled in alongside Phase 5).

---

### Phase 3 — Mac → iOS one-way screen share, no audio

**Goal:** triage and pair-debug use case shipping; Mac shares display to iPhone/iPad.
**Flag:** `media_screen_share_enabled`.
**Duration estimate:** ~3 weeks.

**Inclusion:**
- **Mac**: `ScreenCapturePipeline.swift` (ScreenCaptureKit, `SCStream`, `SCStreamConfiguration` 1920×1080@30 default, focus-window-only picker via `SCShareableContent.current`). `VideoEncoder.swift` (`VTCompressionSession` HEVC, H.264 fallback for pre-Skylake Intel). `MediaPacketCodec` packetization. `MediaSessionCoordinator` orchestration.
- **iOS**: `VideoReceivePipeline.swift` (`VTDecompressionSession` HEVC, H.264 fallback, → `AVSampleBufferDisplayLayer` via `UIViewRepresentable`). `ScreenShareViewerView.swift` (full-bleed, stats overlay).
- **New stream class** `media.screen.video` (one stream per GOP). Stream-class dispatch updated on both sides.
- **BWE**: `BitrateController` (GCC-lite receiver-driven, 100 LOC). `media.control` `BweFeedback` frames. Encoder adapts in 4 steps (8 → 4 → 2 → 1 Mbps).
- **Mac UI**: "Start mirror" button in popover header (mercury-bordered) with cooldown. Screen-share start confirmation modal (mercury tool-shape). `MercuryRing` menu-bar indicator while sharing.
- **iOS UI**: `ScreenShareViewerView`, stats toggle via three-finger tap.
- **`hosted_media_sync` toggle** `screenShare` now enforced (was `false` post-grandfather; activate for new SKU buyers).
- **Quota**: `screenShareSecondsUsed`, `screenShareSessions` tracked in `media_quota_usage`.

**Cloud / rules:** No new rules. Schema additions in Phase 2 already cover.

**Privacy:** `AgentLens/Info.plist` — `NSScreenCaptureUsageDescription` (text in §G.1). Hardened Runtime entitlement `com.apple.security.device.bluetooth` reserved for Phase 4 audio (no-op in Phase 3).

**Tests:**
- **Unit**: `ScreenCaptureKitMockTests` (30 fps over 60 s nominal, drops at `.serious` thermal). `BitrateControllerTests`. `VideoEncoderTests` (HEVC settings, keyframe interval 2 s, H.264 fallback probe).
- **Integration**: `MediaLoopbackScreenShare` (5-min HEVC stream, no GOP loss, BWE converges within 5 s).
- **Device matrix**: per §J.3 Phase 3 row — all listed devices, 5-min share each, p50/p95/p99 RTT logged.
- **Manual**: Mac M3 → iPhone 17 Pro across Wi-Fi + cellular topologies; 60-min cap enforcement; thermal-state down-adapt validation.

**Docs:**
- `docs/HERMES_MEDIA_TRANSPORT.md` — full screen-share section.
- `DESIGN.md` decision-log: "Call HUD top hairline 1pt `mercuryGradient`; `mercuryPulse` dot completes the live signal."
- `docs/runbooks/media-device-matrix/phase-3.md` — per-device results.
- `CHANGELOG.md` entry.

**Acceptance gate:**
1. ≥ 95% screen-share-session success rate across device matrix over 7-day soak.
2. p95 glass-to-glass latency ≤ 250 ms on LAN, ≤ 400 ms on cellular.
3. Thermal down-adapt confirmed: on `.serious` bitrate halves within 3 s.
4. 60-min session cap enforced; daily cap (120 min normal / 30 min soft cap) enforced.
5. App Store re-submission accepted (`NSScreenCaptureUsageDescription` added) with reviewer walkthrough.

**Out of scope (Phase 4+):**
- Audio · video · CallKit · soft / hard caps · iPad PiP · iOS-side capture.

---

### Phase 4 — Mac ⇄ iOS audio

**Goal:** voice channel between Mac and iPhone, with echo cancellation tuned.
**Flag:** `media_audio_enabled`.
**Duration estimate:** ~2 weeks.

**Inclusion:**
- **Mac**: `MicrophoneCapturePipeline.swift` (AVAudioEngine + Voice-Processing IO). `AudioEncoder.swift` (libopus 64 kbps mono, 20 ms framing).
- **iOS**: `MicrophoneCaptureService.swift` + `AudioReceivePipeline.swift` + `AudioEncoder.swift` (same Opus settings). Voice-Processing IO.
- **New stream class**: `media.audio.{out,in}` as QUIC datagrams.
- **libopus**: NEW `Vendor/Opus.xcframework`, NEW `scripts/build-opus-xcframework.sh`. Wired into `OpenBurnBarCore/Package.swift`.
- **Mute/unmute** in-band on audio frame header. Surfaces in Mac call HUD + iOS in-app HUD (mute button shown).
- **Route change handling**: `AVAudioSession.routeChangeNotification` (iOS) + `AudioObjectAddPropertyListener` on `kAudioHardwarePropertyDefaultOutputDevice` (Mac). Pause 200 ms, crossfade on reinit.
- **AirPods / Bluetooth routing**: `com.apple.security.device.bluetooth` entitlement activated on Mac; `NSBluetoothAlwaysUsageDescription` text confirms.

**Cloud / rules:** No new schema. `media_session_events` already captures audio sessions.

**Privacy:**
- iOS `NSMicrophoneUsageDescription` (already in Info.plist; phase 4 makes it functional).
- macOS `NSMicrophoneUsageDescription` + `NSBluetoothAlwaysUsageDescription`.

**Tests:**
- **Unit**: `OpusFramerTests` (20 ms framing, jitter reorder, PLC on loss).
- **Integration**: AEC convergence test (Mac speaker → Mac mic loop, measure echo dB attenuation), route-change reinit test (forced device disconnect mid-call).
- **Device matrix**: per-device audio quality test — record 30 s, transmit, measure PESQ score on receiver. Test matrix: AirPods Pro 2, AirPods Max, generic BT, wired USB-C.
- **Manual**: 10-min Mac ⇄ iPhone call (audio only) across topologies; AirPods connect mid-call test.

**Docs:**
- `docs/HERMES_MEDIA_TRANSPORT.md` — audio pipeline section.
- `docs/runbooks/media-device-matrix/phase-4.md`.
- `CHANGELOG.md` entry.

**Acceptance gate:**
1. Echo cancellation: ≥ 35 dB attenuation on Mac-mic-hears-Mac-speaker loop.
2. Route-change handoff completes within 500 ms with no glitch > 50 ms.
3. PESQ MOS ≥ 3.5 across device matrix.
4. p95 audio latency ≤ 150 ms LAN, ≤ 250 ms cellular.
5. 7-day soak; ≤ 1% audio-session failure rate.

**Out of scope (Phase 5+):**
- Video · CallKit · Mercury foreground sheet · iPad multicam · PiP.

---

### Phase 5 — Mac ⇄ iOS video + CallKit + PushKit + Mercury foreground sheet

**Goal:** full 1:1 video calling shipping; iPhone wakes from suspended via PushKit; Mercury foreground sheet swaps in when iOS app already active.
**Flag:** `media_video_enabled`.
**Duration estimate:** ~4 weeks.

**Inclusion:**
- **Mac**: `CameraCapturePipeline.swift` (AVCaptureSession, front camera). Reuse `VideoEncoder` and `AudioEncoder` from Phase 3 + Phase 4. `VoIPCallTrigger.swift` (calls `triggerVoIPCall` Cloud Function).
- **iOS**: `CameraCaptureService.swift` (AVCaptureSession on iPhone). `VoIPCallService.swift` (PKPushRegistry + CallKit `CXProvider` + `CXCallController`). `MercuryCallTransitionController.swift` implementing Decision 1 (app-active → Mercury sheet, app-background → direct CallHUD).
- **New stream classes**: `media.video.{out,in}` (per-GOP). Bidirectional. Audio already in datagrams from Phase 4.
- **Mac UI**: Incoming-call sheet (`IncomingCallSheet.swift`) — full-window NSPanel with mercury hairline, avatar with mercuryPulse, Decline / Accept. Call HUD on Mac includes Camera control button.
- **iOS UI**: CallKit native UI handles ringing + lock-screen accept (primary). `MercuryIncomingSheet.swift` (foreground only) per Decision 1. In-app `CallHUDView.swift` for active call. `SelfPiPView.swift` for local self-view (88×128, drag-to-corner).
- **Thermal handling**: iPhone `ProcessInfo.processInfo.thermalState`. `.serious` halves bitrate + frame rate. `.critical` triggers `media.terminate(thermal)`.
- **Codec fallback**: A13 and below → H.264 outbound. Probed via `MTLDevice.supportsFamily(.apple7)`.
- **PushKit token sync**: iPhone uploads VoIP token via existing iroh control stream on each successful connect. Mac caches in `MacCloudEntitlementStore` (yes — same store; it's about cached per-peer state). On `triggerVoIPCall` failure with `BadDeviceToken`, Mac requests fresh on next iroh connection.
- **Entitlement (Decision 2)**: `triggerVoIPCall` Cloud Function verifies the calling Mac's `hosted_media_sync` entitlement before forwarding APNs push. iPhone-side `MediaCapabilityGate` does not check entitlement (Mac-side only).
- **Budget caps (Decision 4)**: Phase 5 ships `evaluateMediaBudget` + `ops/media_budget_status/state/current` + `media_kill_switch` Remote Config flag + auto-tightening envelope reading in both Mac and iOS. `MediaBudgetReader.swift` on both sides. Toasts + modal sheets per §E.6.

**Cloud / rules:**
- NEW `functions/src/voipPush.ts` — `triggerVoIPCall` callable with Mac-entitlement check.
- NEW `functions/src/mediaBudget.ts` — `evaluateMediaBudget` scheduled hourly.
- EDIT `functions/src/types.ts` — `MediaBudgetStatusDoc`.
- EDIT `firestore.rules` — `ops/media_budget_status/{doc}` (server-only writes, public read).
- EDIT `firestore.rules` — `users/{uid}/voip_tokens/{deviceId}` (owner-only, ciphertext envelope mirroring existing iroh pairing pattern; token is sensitive).

**Privacy:**
- iOS `NSCameraUsageDescription` activated.
- iOS `UIBackgroundModes: voip` activated.
- macOS `NSCameraUsageDescription` activated.
- macOS `com.apple.security.device.camera` Hardened Runtime entitlement.
- iOS `OpenBurnBarMobile.entitlements` adds `aps-environment: production`.

**Tests:**
- **Unit**: `VoIPCallServiceTests` (PushKit registration, CallKit reporting, token rotation). `MercuryCallTransitionTests` (foreground → Mercury sheet within 200 ms; background → direct CallHUD). `MediaBudgetGateTests` (soft-cap envelope applied, hard-cap denial, normal recovery).
- **Integration**: `MediaCallKitFlow` XCUITest (PushKit → CallKit → accept → CallHUD across foreground / background). `MediaLoopbackVideoCall` (30 s bidirectional video + audio, byte-for-byte modulo codec tolerance).
- **Chaos**: `ChaosVoIPTokenRotation`, `ChaosThermalCritical`, `ChaosSoftCapEngages`, `ChaosHardCapEngages`.
- **Device matrix**: all listed devices (J.3 Phase 5 row); 10-min soak call per device.
- **Manual**: 100 calls across team (TestFlight); incoming call on locked iPhone; AirPods connect mid-call; thermal-pressure on iPhone 13 mini.

**Docs:**
- `docs/HERMES_MEDIA_TRANSPORT.md` — full video + call section.
- `docs/runbooks/media-budget.md` — soft / hard cap operations runbook.
- `DESIGN.md` decision-log: "Decline `error`, Accept `hermesAureate` with `mercuryShimmer`; CallKit primary + Mercury foreground sheet (Decision 1)."
- `docs/runbooks/media-device-matrix/phase-5.md`.
- `CHANGELOG.md` entry.

**Acceptance gate:**
1. ≥ 95% call-setup success rate across device matrix over 7-day soak.
2. CallKit foreground-to-Mercury transition < 200 ms (assertion in `MercuryCallTransitionTests`).
3. PushKit wake from suspended iPhone within 3 s on 4G + Wi-Fi.
4. Thermal terminate test: `.critical` triggers `media.terminate` within 3 s on iPhone 13 mini.
5. Soft-cap test: budget projection > $600 → envelope tightens automatically; iOS shows toast.
6. Hard-cap test: kill-switch → all sessions terminate within 60 s; modal sheet shown.
7. App Store re-submission accepted with PushKit + camera + microphone permissions; reviewer pre-recorded walkthrough included.

**Out of scope (Phase 6+):**
- iPad multicam · PiP · macOS always-on-top · iOS-side screen capture.

---

### Phase 6 — iPad multicam + PiP

**Goal:** iPad Pro M-series users get split front+back camera; incoming Mac screen share enters PiP automatically.
**Flag:** `media_ipad_multicam_enabled`.
**Duration estimate:** ~2 weeks.

**Inclusion:**
- **iPad**: `AVCaptureMultiCamSession` on iPad Pro M-series only (gated by `AVCaptureMultiCamSession.isMultiCamSupported`). UI: front camera primary, back camera as 88×128 PiP in upper-right of local self-view. Falls back to single-cam on iPad mini / older iPad Pro.
- **PiP**: `ScreenSharePiPController.swift` activates for incoming Mac screen share. Standard `AVPictureInPictureController` with `AVPictureInPictureControllerContentSource(sampleBufferDisplayLayer:playbackDelegate:)`. Auto-enters on app background.
- **UI**: `SelfPiPView` extended to show back-cam mini PiP on iPad. Settings → Media → "Use back camera in calls" toggle (iPad Pro only).
- **Audio**: no change. Single audio path.

**Cloud / rules:** No change.

**Privacy:** No new permissions.

**Tests:**
- **Unit**: `CameraCaptureServiceTests` — multicam probe correct on simulator + device, single-cam fallback path.
- **Integration**: multicam frame alignment test (front + back timestamps synced within 1 frame).
- **Device matrix**: iPad Pro M4 (✓ multicam), iPad mini 6 (✓ single-cam fallback), iPad Pro M1 (✓ multicam).
- **Manual**: 10-min iPad Pro multicam call; PiP enter/exit on backgrounding.

**Docs:**
- `docs/HERMES_MEDIA_TRANSPORT.md` — iPad multicam section.
- `DESIGN.md` decision-log: "iPad Pro M-series back-cam PiP in self-view upper-right."
- `CHANGELOG.md` entry.

**Acceptance gate:**
1. Multicam probe correctly enables on iPad Pro M-series, disables elsewhere.
2. PiP enters within 200 ms of backgrounding.
3. Frame alignment within 1 frame (~33 ms at 30 fps).
4. 7-day soak ≥ 95% session success on iPad Pro multicam.

**Out of scope:** macOS PiP (Phase 7).

---

### Phase 7 — macOS PiP / always-on-top viewer + WSS retirement parity

**Goal:** Mac users get a floating, always-on-top viewer for incoming iOS camera preview during a call; WSS legacy infrastructure formally retired (referencing `docs/HERMES_IROH_RETIREMENT.md`).
**Flag:** `media_macos_pip_enabled`.
**Duration estimate:** ~1 week.

**Inclusion:**
- **Mac**: `ScreenShareViewer.swift` extended with NSPanel-based always-on-top mode. `NSWindow.level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`. Toggle in `CallHUD` ("Pop out" button next to End).
- **UI**: floating panel sized 240×320 default with mercury hairline border, draggable corners, double-click to dock.
- **WSS retirement** (separate but parallel): execute `docs/HERMES_IROH_RETIREMENT.md` Phase 7 gates. **Gated on**: ≥ 99.5% iroh success / 0 WSS fallback / ≥ 75% iroh-direct / ≤ 100% hosted-relay budget for 14 consecutive days post-Phase-6. The media rollout doesn't block this; running them in parallel surfaces ops collapse.

**Cloud / rules:** No change for PiP. WSS retirement deletes `services/hermes-realtime-relay/` infrastructure per the retirement runbook.

**Privacy:** No new permissions.

**Tests:**
- **Unit**: `ScreenShareViewerWindowTests` — full-screen aux behavior, multi-Space behavior.
- **Manual**: Spaces test (drag panel to space 2, switch — panel follows). Full-screen-app test (panel visible over Safari fullscreen YouTube). Multi-monitor test.

**Docs:**
- `docs/HERMES_MEDIA_TRANSPORT.md` — macOS PiP section.
- `docs/HERMES_IROH_RETIREMENT.md` — final retirement timestamp.
- `CHANGELOG.md` entry.
- `DESIGN.md` decision-log: "macOS PiP uses mercury hairline border; toggle from CallHUD 'Pop out'."

**Acceptance gate:**
1. Floating panel visible over fullscreen apps and across Spaces.
2. WSS retirement gates green for 14 consecutive days; Cloud Run service + Memorystore Redis decommissioned per runbook.
3. 7-day soak on Phase 7 flag.

**Out of scope:**
- iOS-side screen capture (deferred indefinitely — not in this plan's mandate).

---

## Verification recipe (E2E for the integrating engineer)

After any phase lands, before flag flips on for >5% rollout:

```bash
# Rust crate
cd crates/openburnbar-iroh && cargo test --release

# SwiftPM tests
cd OpenBurnBarCore && swift test --filter "OpenBurnBarMediaTests"
cd OpenBurnBarCore && swift test --filter "MediaLoopback"

# Mac build + tests
xcodebuild test \
  -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:OpenBurnBarTests/Media

# iOS build + tests
xcodebuild test \
  -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBarMobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:OpenBurnBarMobileTests/Media

# Functions
cd functions && npm ci && npx tsc --noEmit && npm run test:media

# Manual end-to-end (TestFlight) — per phase
# Follow phase-specific acceptance gate above.
# Capture screenshots and `iroh_audit_events` exports under
# docs/runbooks/media-device-matrix/{phase}.md and
# docs/runbooks/media-rollout-status.md.
```

---

## Rollout governance

Each phase gate is reviewed against telemetry in this order:

1. Test suites green (auto-blocking).
2. Device-matrix manual results captured (manual sign-off in `docs/runbooks/media-device-matrix/{phase}.md`).
3. ≥ 7-day soak with flag on for internal users; success rate ≥ 95%, fallback rate ≤ 5%.
4. `iroh_audit_events` shows expected streamClass distribution; zero unexpected fallbacks.
5. App Store review pass (Phases 2, 3, 5 require re-submission for new permissions / capabilities).
6. Budget projection from `evaluateMediaBudget` shows < $400/mo at current trajectory before Phase 5 broad rollout.
7. Alberto approves Remote Config percentage step (5% → 25% → 50% → 100% with ≥ 24 h between).

Roll back at any time by flipping the phase's Remote Config flag to `false`. Roll back the whole feature with `media_kill_switch=true`. The legacy iroh + WSS chat path is unaffected by any media rollback.

---

## Decisions index

| # | Decision | Implementation phase | Lives at |
|---|---|---|---|
| 1 | CallKit primary + Mercury foreground sheet | Phase 5 | `MercuryCallTransitionController.swift` |
| 2 | Mac-side entitlement gate only | Phase 5 | `triggerVoIPCall` Cloud Function · `MediaCapabilityGate` (iOS = placeholder) |
| 3 | iOS image save: prompt once, remember per partner | Phase 2 | `AttachmentSaver.swift` · `PerPartnerSavePreferencesView.swift` |
| 4 | $600 soft / $1000 hard hosted-relay budget cap | Phase 5 | `evaluateMediaBudget` · `MediaBudgetReader.swift` · `ops/media_budget_status/state/current` |
| 5 | New `hosted_media_sync` SKU (not extending `hosted_quota_sync`) | Phase 2 | StoreKit · `grantMediaGrandfather` · Firestore entitlement doc |
| 6 | Direct iroh transport, no WebRTC | Phase 3+ | `MediaPacketCodec` · `BitrateController` · libopus |
| 7 | iroh-blobs for file transfer | Phase 1 | `publish_blob` / `fetch_blob` UniFFI · `attachment.advertise` frame |

---

## Glossary

- **GOP**: Group of Pictures — sequence between two I-frames in a video stream. We use ~2 s GOPs at 30 fps = 60 frames. One QUIC stream per GOP for head-of-line isolation.
- **GCC-lite**: Trimmed port of WebRTC's Google Congestion Control algorithm — delay-based loss detection + slow-start ramp. ~100 LOC.
- **BWE**: Bandwidth estimation — receiver-driven, fed back to encoder as `target_bps` ceiling.
- **PLC**: Packet Loss Concealment — Opus's built-in interpolation for lost packets.
- **AEC**: Acoustic Echo Cancellation — Voice-Processing IO unit on Apple platforms.
- **Mercury**: Hermes chat color identity. Tokens: `hermesMercury` (warm silver `#C8BFB5` dark / `#AEA69C` light) + `hermesAureate` (dark platinum `#A2ACBA` dark / `#3F4651` light) + `mercuryGradient`.
- **Pair-debug**: assisted setup / field debugging use case — Mac operator helps iPhone user troubleshoot Hermes Dashboard activity by mirroring or calling.
- **`hosted_media_sync`**: new entitlement SKU introduced Phase 2. $9.99/mo. Per-feature toggles (`fileTransfer`, `screenShare`, `videoCall`).
- **`media_kill_switch`**: Remote Config flag flipped on hard-cap budget breach. Disables all new media sessions.
- **n0 services**: iroh's hosted-relay provider. Production tier $199/mo per `docs/runbooks/iroh-rollout-status.md`.

---

## Cross-references

- `AGENTS.md` — completion bar (do the whole thing, tests + docs, no drive-by refactors).
- `DESIGN.md` — Mercury identity, tokens, motion (extended per phase decision-log).
- `docs/HERMES_REALTIME_RELAY.md` — legacy Cloud Run + WSS relay (retired Phase 7).
- `docs/HERMES_IROH_TRANSPORT.md` — current iroh transport spec (extended with media stream classes).
- `docs/HERMES_IROH_PRODUCTION_HANDOFF.md` — iroh rollout gates (Phases A → G in that doc; informs media rollout governance).
- `docs/HERMES_IROH_RETIREMENT.md` — WSS retirement gates (Phase 7 in this plan executes them).
- `docs/runbooks/iroh-rollout-status.md` — iroh phase status log (template for `docs/runbooks/media-rollout-status.md`).
- `functions/src/types.ts` — canonical schema (extended with media doc types).
- `firestore.rules` — security rules (extended with media collections + entitlements).

End of master plan.
