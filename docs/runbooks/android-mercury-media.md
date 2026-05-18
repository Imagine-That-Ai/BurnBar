# Android Mercury Media runbook

Companion to `docs/runbooks/media-rollout-status.md`. This file is the
on-call playbook for Android-side Mercury Media (file transfer,
screen-share viewer, 1:1 video + audio calls).

## Layers

```
HermesService (chat)
       │
HermesIrohRelayTransport ──▶ MediaControlStreamCoordinator ──▶ control stream (openburnbar/1 ALPN)
       │                              │
       │                              ├─▶ AndroidFileTransferService (iroh-blobs)
       │                              ├─▶ VideoReceivePipeline (HEVC / H.264 via MediaCodec)
       │                              ├─▶ AudioReceivePipeline (Opus, jitter buffer, AudioTrack)
       │                              ├─▶ CameraCaptureService → VideoSendPipeline (per-GOP iroh streams)
       │                              └─▶ MicrophoneCaptureService → MercuryAudioDatagramChannel
       │
       └─ Mercury data FCM → MercuryFcmService → IncomingCallActivity (CallStyle full-screen)
```

## Foreground service contract

The `MediaSessionForegroundService` runs as a single service with
aggregated foreground types:

```xml
<service
    android:name="com.openburnbar.services.media.MediaSessionForegroundService"
    android:foregroundServiceType="microphone|camera|mediaProjection|phoneCall"
    android:exported="false" />
```

Required permissions (declared in `AndroidManifest.xml`):

| Permission | Purpose |
|---|---|
| `RECORD_AUDIO` | mic capture during a call |
| `CAMERA` | front camera during a call |
| `USE_FULL_SCREEN_INTENT` | incoming-call activity over the lock screen (Android 14+) |
| `MANAGE_OWN_CALLS` | self-managed `PhoneAccount` so the call shows in the system call screen |
| `FOREGROUND_SERVICE` | base |
| `FOREGROUND_SERVICE_MICROPHONE` | granular foreground service type (Android 14+) |
| `FOREGROUND_SERVICE_CAMERA` | granular foreground service type |
| `FOREGROUND_SERVICE_MEDIA_PROJECTION` | screen-share viewer (we don't capture, but the type covers PiP) |
| `FOREGROUND_SERVICE_PHONE_CALL` | call-style notification |
| `POST_NOTIFICATIONS` | Android 13+ runtime notif permission |

The service posts a CallStyle ongoing notification with accept/decline
intents bound to the connection ID. Tap routes back into `CallHUDView`.

## Full-screen-intent permission grant flow

Android 14+ added `USE_FULL_SCREEN_INTENT` to the install-time permission
set, but **the system can revoke it per app at any time** (Settings →
Apps → BurnBar → Notifications → "Allow full-screen notifications").

Detection: in `IncomingCallActivity`, before launching the full-screen
intent, we read `NotificationManager.canUseFullScreenIntent()` (API 31+).
If false, post a high-priority heads-up notification instead and surface
a one-time settings deep link in the media settings panel.

Grant flow for new users:
1. App requests `RECORD_AUDIO` + `CAMERA` runtime permissions before the
   first outbound or accepted call (see `CallSessionCoordinator.bootstrap()`).
2. On first inbound call, if `canUseFullScreenIntent()` returns false,
   show a banner in `MediaSettingsView` deep-linking to
   `Settings.ACTION_APP_NOTIFICATION_SETTINGS` with extra
   `EXTRA_APP_PACKAGE`.

## Per-partner save preferences

Stored in DataStore Proto at `data_store/media_partner_save_prefs.pb`.
Schema parity with iOS `MediaPartnerSavePreferenceStore.swift`:

```kotlin
data class MediaPartnerSavePreference(
    val partnerId: String,       // peer NodeId
    val savePolicy: SavePolicy,  // SAVE_TO_PHOTOS | SAVE_TO_FILES | ASK_EVERY_TIME
    val pinnedFolderUri: String? // SAF tree URI when SAVE_TO_FILES
)
```

Forget per partner: `MediaPartnerSavePreferenceStore.forget(partnerId)`.
Forget all: `MediaPartnerSavePreferenceStore.forgetAll()`. Both update
in real time; the media settings UI re-renders via the store's
`StateFlow`.

Photos save uses `MediaStore.Images.Media.EXTERNAL_CONTENT_URI` (scoped
storage, Android 10+). Files save uses
`ActivityResultContracts.OpenDocumentTree` to remember the tree, then
`DocumentsContract.createDocument` for subsequent writes. Audio +
video use `MediaStore.Audio` / `MediaStore.Video`.

## Wire format

Same envelopes as iOS:
- File: `media.blob.advertise` → `media.blob.ack` carrying base32 iroh-blobs ticket
- Screen-share: 16-byte frame envelope + NAL units over a fresh iroh
  bidirectional stream per GOP
- Call audio: Opus packets over `MercuryAudioDatagramChannel`
  (`openburnbar/mercury/audio/1` ALPN)
- Call video: 16-byte envelope + HEVC payload over per-GOP iroh streams
- Call control: `media.control.{KeyframeRequest, BandwidthUpdate, Mute,
  Terminate}` on the control stream

## Capability gate

`AndroidMediaCapabilityGate` is a **read-only mirror** of `MacMediaCapabilityGate`
(Decision 2 — Mac is authoritative). On Android, denial reason surfaces
in `MediaSettingsView` as a banner and in the inbound-call sheet as a
disabled-state tooltip.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Incoming call notification but no full-screen | `USE_FULL_SCREEN_INTENT` revoked by user | Show the deep-link banner; surface via `MediaSettingsView` |
| Audio glitches | jitter buffer too small for the connection's RTT | Tune `JitterBuffer.targetMillis` (default 60ms) up to 120ms |
| Video freezes after BWE drop | encoder bitrate not honoring `BandwidthUpdate` | Check `VideoSendPipeline.applyTargetBitrate` is hooked to the control stream |
| File transfer stalls at 100% | `media.blob.ack` lost | Sender retransmits after the ack timeout (default 10s); manual retry from the attachment row |
| `OpusCodec.isAvailable()` returns false | `Vendor/opus-android.aar` missing | Run `scripts/build_opus_android.sh` |

## See also

- `docs/runbooks/media-rollout-status.md` — Mercury rollout state
- `docs/runbooks/media-budget.md` — quota policy
- `docs/runbooks/android-iroh-transport.md` — underlying QUIC transport
- `docs/runbooks/wss-retirement-checklist.md` — when WSS can be removed
- `plans/2026-05-15-mercury-media-master-plan.md` — design rationale
