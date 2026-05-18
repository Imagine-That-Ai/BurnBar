# Hermes Media Transport

Architecture spec for the Mac ⇄ iPhone/iPad media capabilities (file transfer, screen share, 1:1 video calling) layered on the existing iroh QUIC mesh.

The plan of record — including locked decisions, capability matrix, premium gating, privacy posture, observability, phasing, tests, and risks — lives at `plans/2026-05-15-mercury-media-master-plan.md`. **Read that first.** This document is the operator/engineer reference: it stays narrow on transport, codec, frame layout, and on-disk contract. Surfaces, copy, and SKU policy live in the plan.

## Status

Phase 1 (iroh-blobs file send/receive foundation) is scaffolded. Phases 2-7 are not started. Live status tracked in `docs/runbooks/media-rollout-status.md`.

## Stream classes

All media rides the same iroh QUIC mesh and the same `openburnbar/1` ALPN as Hermes chat + Pi telemetry. Stream classes are negotiated **in band** via the first frame on each new bi-stream rather than via a new ALPN, so existing peers stay interoperable.

| Stream class | Cardinality | Direction | QUIC discipline | Phase |
|---|---|---|---|---|
| `media.blob.advertise` | 1 per attachment, on existing Hermes control stream | Sender → receiver | Reliable, ordered (JSON envelope) | 1 |
| `media.blob.fetch` | 1 per attachment, dedicated stream | Receiver dials sender | Reliable, ordered (iroh-blobs) | 1 |
| `media.screen.video` | 1 per GOP (~60 frames at 30 fps) | Mac → iOS | Reliable, ordered, stream-per-GOP for head-of-line isolation | 3 |
| `media.video.{out,in}` | 1 per direction per GOP | Bidirectional | Reliable, ordered, stream-per-GOP | 5 |
| `media.audio.{out,in}` | none — datagrams | Bidirectional | QUIC datagrams (RTP-style) | 4 |
| `media.control` | 1 per session | Bidirectional | Reliable — RTCP-style sender reports, BWE, mute, terminate | 3 |

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

## Cross-references

- `plans/2026-05-15-mercury-media-master-plan.md` — full design + phasing + tests + risks.
- `docs/HERMES_IROH_TRANSPORT.md` — the underlying iroh transport this layers on.
- `docs/runbooks/media-rollout-status.md` — phase-by-phase rollout log.
- `docs/runbooks/media-quota.md` — daily envelope + per-feature caps + dispute resolution.
- `docs/runbooks/media-budget.md` — n0 hosted-relay $600 soft / $1000 hard cap operations.
- `docs/runbooks/media-device-matrix/` — per-phase device-matrix soak results.
