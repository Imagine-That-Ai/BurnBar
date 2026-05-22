# Hermes Media Transport

Architecture spec for the Mac ⇄ iPhone/iPad/Android media capabilities (file transfer, screen share, 1:1 video calling) layered on the existing iroh QUIC mesh.

The plan of record — including locked decisions, capability matrix, premium gating, privacy posture, observability, phasing, tests, and risks — lives at `plans/2026-05-15-mercury-media-master-plan.md`. **Read that first.** This document is the operator/engineer reference: it stays narrow on transport, codec, frame layout, and on-disk contract. Surfaces, copy, and SKU policy live in the plan.

The Mercury Mirror streaming upgrade is evidence-gated by
[`docs/runbooks/mercury-streaming-evidence-gates.md`](runbooks/mercury-streaming-evidence-gates.md).
Do not ship AV1-first routing, video datagrams, RPS recovery, FEC, temporal
layers, or ROI hints until the corresponding gate is green. MediaFrame v2 is
allowed only when both live peers advertise v2 support and the receiver has the
dual-stack decode path.

## Status

Phase 1 (iroh-blobs file send/receive foundation) is scaffolded, and the
Phase 8 mirror control frames are live on the existing `media.control` stream.
As of the 2026-05-20 Mercury Mirror streaming upgrade, both Apple and Android
surfaces can advertise optional streaming capability snapshots, and the Mac
screen-share starter routes through the evidence-gated codec policy.

Live screen-share transport is dual-stack and intentionally conservative:

- `MediaFrame` v1 remains the compatibility floor.
- Mac, iOS, and Android live mirror requests/presence heartbeats advertise
  v1+v2 frame support on paths that have a dual-stack receiver. When both peers
  advertise v2, the Mac sender emits MediaFrame v2 envelopes on the existing
  `media.stream.frame` control-stream payload.
- MediaFrame v2 metadata carries the selected codec and any VideoToolbox LTR
  acknowledgement token returned on the encoded sample. iOS and Android ACK the
  token only after their `VideoReceivePipeline` accepts the frame for decode.
- Video datagrams, temporal layers, FEC, and ROI hints stay behind the evidence
  gates in
  `docs/runbooks/mercury-streaming-evidence-gates.md`.

Live status tracked in `docs/runbooks/media-rollout-status.md`.

## Stream classes

All media rides the same iroh QUIC mesh and the same `openburnbar/1` ALPN as Hermes chat + Pi telemetry. Stream classes are negotiated **in band** via the first frame on each new bi-stream rather than via a new ALPN, so existing peers stay interoperable.

| Stream class | Cardinality | Direction | QUIC discipline | Phase |
|---|---|---|---|---|
| `media.blob.advertise` | 1 per attachment, on existing Hermes control stream | Sender → receiver | Reliable, ordered (JSON envelope) | 1 |
| `media.blob.fetch` | 1 per attachment, dedicated stream | Receiver dials sender | Reliable, ordered (iroh-blobs) | 1 |
| `media.screen.video` | 1 per GOP (~60 frames at 30 fps) | Mac → iOS | Reliable, ordered, stream-per-GOP for head-of-line isolation | 3 |
| `media.video.{out,in}` | 1 per direction per GOP | Bidirectional | Reliable, ordered, stream-per-GOP | 5 |
| `media.audio.{out,in}` | none — datagrams | Bidirectional | QUIC datagrams (RTP-style) | 4 |
| `media.control` | 1 per session | Bidirectional | Reliable — RTCP-style sender reports, BWE, mute, terminate, mirror request/ack, presence heartbeat | 3 |
| `media.mirror.request` | 1 per request | iOS/Android → Mac | Reliable, on existing control stream (JSON envelope) | Phase 8 |
| `media.mirror.ack` | 1 per request | Mac → iOS | Reliable, on existing control stream (JSON envelope) | Phase 8 |
| `media.mirror.stop` | 1 per ended mirror | iOS/Android → Mac | Reliable, on existing control stream (JSON envelope) | Phase 8 |
| `media.mirror.display.select` | 0..n per mirror session | iOS/Android → Mac | Reliable, on existing control stream (JSON envelope) | Phase 8 |
| `media.presence.heartbeat` | 1 per 2.5s during active mirrors; 1 per 60s otherwise | Bidirectional | Reliable, on existing control stream (JSON envelope) | Phase 8 |
| `media.ltr.ack` | 0..n per mirror session | Receiver → encoder | Reliable, on existing control stream (JSON envelope) | Gated streaming substrate |

## Phase 1 — file transfer over iroh-blobs

### Wire layout

The advertise frame rides the existing Hermes JSON envelope on the chat control stream. New frame types added to `HermesRealtimeRelayFrameType`:

- `media.classify` — first frame on any new media-class bi-stream after the existing `request.start` negotiation. Carries `{ "media": { "streamClass": "<class>" } }` so the receiver routes the rest of the stream to the correct pipeline.
- `media.blob.advertise` — sender publishes a blob and announces the ticket. Carries `{ "media": { "attachment": { manifestId, blobHash, filename, mime, size, peerDeviceId, createdAt }, "blobTicket": "<base32>" } }`.
- `media.blob.ack` — receiver confirms (or rejects) the manifest. Carries `{ "media": { "ack": { "manifestId": "...", "status": "received" | "rejected", "reason": "..." } } }`.

Older clients that do not understand the new types skip them silently (the existing `IrohRelayRequestHandler.serve()` has a `continue` branch for unknown chat-stream cases). This is the forward-compat substrate for Phases 3-7 to extend without an ALPN bump.

### Rust surface

`crates/openburnbar-iroh/src/blobs.rs` exposes two UniFFI functions:

```rust
publish_blob(local_path: String) -> Result<BlobTicket, IrohFfiError>
fetch_blob(ticket: BlobTicket, destination: String, progress_handle: Arc<dyn ProgressHandle>) -> Result<TransferStats, IrohFfiError>
```

`BlobTicket` is the iroh-blobs `BlobTicket` newtype rendered as a base32 string. `TransferStats` is `{ bytes_total, bytes_resumed, blake3_hash, duration_millis }`. Errors map onto the existing `IrohFfiError` enum.

### iroh-blobs dependency

`Cargo.toml` pins `iroh-blobs = "0.91"` to match `iroh = "0.91"`. Bumping `iroh-blobs` in lockstep with `iroh` is required and is enforced by the existing xcframework CI workflow which fails on minor-version skew between the two crates.

### On-disk contract

Inbox: `Library/Caches/MediaInbox/{blobHash}.{ext}` on iOS, `~/Library/Caches/com.openburnbar.AgentLens/MediaInbox/{blobHash}.{ext}` on macOS. Auto-purged after 7 days (configurable in Settings → Storage in Phase 2). One-tap wipe in the same panel.

### Forward-compat

- `HermesRealtimeRelayFrame.media` is optional and defaulted to `nil` on encode. `JSONEncoder` omits absent optionals so chat traffic that does not touch media is byte-identical to the pre-Phase-1 wire form.
- `HermesRealtimeRelayMediaPayload` itself is a flat optional-field record; new fields can be added in later phases without breaking older decoders.
- `MediaStreamClass` is a `String` newtype rather than a closed enum so receivers can route an unknown class to a no-op handler instead of failing to decode.

## Phases 2-7

Stubs to be filled in as each phase ships. Each phase append:

- New stream class(es) added to the table above.
- Wire-layout deltas (frame fields, datagram framing).
- New UniFFI surface, if any.
- Migration / compat notes if any prior frame field changed semantics.

## Mirror request / ack / presence (Phase 8)

These frame types ride the existing `media.control` stream — no new ALPN. The Mac's `MacFileTransferService` read-loop routes them to `MercuryRouter`; the phone-side `MediaControlStreamCoordinator` read-loop handles acknowledgements and sends periodic heartbeats.

### `media.mirror.request` (iOS/Android → Mac)

The phone user taps "Ask to Mirror" in the Mercury Live sheet. The frame carries:

```json
{
  "type": "media.mirror.request",
  "uid": "u1",
  "connectionId": "c1",
  "requestId": "req_abc",
  "media": {
    "mirrorRequest": {
      "requestId": "req_abc",
      "requestedAt": "2026-05-20T23:30:00.000Z",
      "requesterDisplayName": "Alberto's iPhone",
      "streamClass": "media.screen.video",
      "streamingCapabilities": {
        "source": "apple-videotoolbox",
        "mediaFrameVersions": { "supportsV1": true, "supportsV2": false },
        "videoDatagrams": { "maxPayloadBytes": null },
        "codecCapabilities": [
          {
            "codec": "hevc",
            "canEncode": true,
            "canDecode": true,
            "hardwareAccelerated": true,
            "lowLatencyEncode": true,
            "longTermReference": true,
            "temporalLayers": false,
            "screenContentCoding": false
          }
        ]
      }
    }
  }
}
```

- `requestId`: iOS-generated UUID, echoed in the ack for correlation.
- `streamClass`: which `MediaStreamClass` the requester wants (v1 always `media.screen.video`).
- `streamingCapabilities` (optional): requester-side Phase 0/2 capability
  snapshot. Older clients omit it. The Mac uses this request snapshot first,
  then falls back to the last presence heartbeat, then falls back to existing
  v1 behavior.
- The Mac arbitrates via `MercuryRouter`, consulting cooldown and consent state before ringing the user.

### `media.mirror.ack` (Mac → iOS)

The Mac's reply, emitted on every request path:

```json
{
  "type": "media.mirror.ack",
  "uid": "u1",
  "connectionId": "c1",
  "requestId": "req_abc",
  "media": {
    "mirrorAck": {
      "requestId": "req_abc",
      "decision": "accepted"
    }
  }
}
```

Decision enum: `accepted`, `denied`, `cooling_down`, `unsupported`, `busy`.

- `cooldownSecondsRemaining` (int, optional): populated only when `decision == "cooling_down"`. Omitted from the wire otherwise so older decoders stay byte-identical.
- `detail` (string, optional): free-text surfaced in the iOS banner.

On `.accepted`, the iOS `mirrorAckHandler` pushes to `ScreenShareViewerView`. Other decisions surface a toast in `MercuryLiveSheet`.

### `media.mirror.stop` (iOS/Android → Mac)

The phone sends this when the accepted mirror viewer closes, including explicit
close, system/back dismissal, and activity/sheet teardown. The Mac treats the
frame as a session teardown signal, stops `MediaSessionCoordinator`, clears the
active mirror slot, and returns to `.idle` without applying the decline
cooldown. That keeps close → reconnect and another paired device → connect
available immediately after a normal hangup.

```json
{
  "type": "media.mirror.stop",
  "uid": "u1",
  "connectionId": "c1",
  "requestId": "req_abc",
  "media": {
    "mirrorStop": {
      "requestId": "req_abc",
      "stoppedAt": 801000002.0,
      "reason": "viewer_closed"
    }
  }
}
```

- `requestId`: must match the active accepted mirror request. Mismatches are
  ignored so stale teardown from an old viewer cannot kill a new mirror.
- `stoppedAt`: Swift `JSONEncoder` Date seconds since 2001-01-01 UTC. Swift
  decoders also tolerate ISO-8601 where custom date decoding is installed.
- `reason`: best-effort diagnostic string such as `viewer_closed`,
  `viewer_disappeared`, `sheet_disappeared`, or `activity_destroyed`.

### `media.presence.heartbeat` (bidirectional)

Phones send this every 60s once the control stream is `.live`; the Mac replies
on the same control stream, and active mirror sinks continue sending Mac
heartbeats every 2.5s while video is live. Fire-and-forget (no ack):

```json
{
  "type": "media.presence.heartbeat",
  "uid": "u1",
  "connectionId": "c1",
  "media": {
    "presence": {
      "sentAt": "2026-05-20T23:31:00.000Z",
      "deviceDisplayName": "Alberto's iPhone",
      "displayName": "Alberto's iPhone",
      "capabilities": ["mirror.viewer", "file.send", "file.receive", "call.receive"],
      "peerDeviceId": "iphone-1",
      "streamingCapabilities": {
        "source": "apple-videotoolbox",
        "mediaFrameVersions": { "supportsV1": true, "supportsV2": false },
        "videoDatagrams": { "maxPayloadBytes": null },
        "codecCapabilities": []
      }
    }
  }
}
```

- `capabilities`: string array of `MercuryPeer.Feature` raw values. Unknown strings are silently dropped by `MercuryPeer.Feature` decoding so future capabilities don't break old peers. Macs include `mirror.auto_accept` after the user has accepted mirror consent, letting phones open the mirror directly instead of presenting a "check your Mac" pending state.
- `deviceDisplayName` is canonical. `displayName` is still emitted and decoded
  as an Android compatibility alias.
- `peerDeviceId` (optional): lets the receiver associate the latest capability
  snapshot with the active control-stream peer.
- `streamingCapabilities` (optional): same wire shape as mirror requests. The
  Mac stores the latest snapshot and uses it if a later mirror request omits
  request-local capabilities.
- The Mac `MercuryRouter.handleFrame` feeds the payload into `MercuryPeerSource.ingestHeartbeat` so the popover's "Call iPhone" / "Send File" buttons gate on online state.

### `media.ltr.ack` (receiver → encoder)

Receiver-side decode success for a v2 frame can acknowledge the long-term
reference token carried in that frame's metadata:

```json
{
  "type": "media.ltr.ack",
  "uid": "u1",
  "connectionId": "c1",
  "requestId": "req_abc",
  "media": {
    "longTermReferenceAck": {
      "requestId": "req_abc",
      "tokenValue": 9001,
      "decodedAt": "2026-05-20T23:32:00.000Z"
    }
  }
}
```

- iOS emits the ACK only after `VideoReceivePipeline` successfully submits the
  v2 frame to VideoToolbox decode.
- Mac control-stream dispatch routes the ACK through `MercuryRouter` to the
  active `MediaSessionCoordinator`, which forwards the raw token value to
  `VideoEncoder`.
- Live mirror can now carry the token metadata on negotiated v2 screen-share
  frames. RPS policy is still evidence-gated, so peers must fall back to IDR
  refresh when v2/LTR is unavailable or decode does not ACK a token.

### Ordering rules

- Mirror request and ack are **synchronous request-response**: the phone waits for the ack before presenting the viewer.
- Mirror stop is **terminal and non-cooldown**: a normal viewer hangup clears
  the Mac's active session immediately and does not block the next request.
- Cooldown is **server-authoritative**: the Mac rejects requests during cooldown; iOS never pre-emptively enforces it.
- Presence is **bidirectional**: phone heartbeats advertise viewer capability,
  and Mac-originated mirror health heartbeats continue during visually idle
  desktops so receivers do not mistake "no changed pixels" for a stalled video
  stream.
- All three ride the same reliable stream as file-transfer traffic. Ordering within stream is preserved.

## Mercury streaming capability handshake

The streaming snapshot wire structs live in
`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRealtimeRelayTypes.swift`
and mirror Android DTOs in
`android/openburnbar-iroh-relay/src/main/java/com/openburnbar/irohrelay/HermesRealtimeRelayFrame.kt`.
Conversion helpers bridge them to platform-native `MercuryStreamingCapabilitySnapshot`
models on Swift and Kotlin.

Compatibility rules:

- All snapshot fields are optional at the control-frame level.
- Missing snapshot data means "keep v1 behavior", not "enable the new stack".
- Dates decode from both Swift JSONEncoder numeric dates and ISO-8601 strings;
  custom-encoded mirror/presence dates are emitted as ISO-8601 strings.
- Android's legacy `displayName` heartbeat key remains accepted.
- Mac, iOS, and Android advertise v1+v2 only on live paths that can send or
  receive the v2 envelope. Older peers and unsupported paths remain v1.
- v2 is selected only when both peers advertise support; otherwise the sender
  writes the v1 `MediaFrame` payload.

## Cross-references

- `plans/2026-05-15-mercury-media-master-plan.md` — full design + phasing + tests + risks.
- `docs/HERMES_IROH_TRANSPORT.md` — the underlying iroh transport this layers on.
- `docs/runbooks/media-rollout-status.md` — phase-by-phase rollout log.
- `docs/runbooks/media-quota.md` — daily envelope + per-feature caps + dispute resolution.
- `docs/runbooks/media-budget.md` — n0 hosted-relay $600 soft / $1000 hard cap operations.
- `docs/runbooks/media-device-matrix/` — per-phase device-matrix soak results.
