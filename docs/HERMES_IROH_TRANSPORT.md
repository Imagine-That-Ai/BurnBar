# Hermes Realtime Relay → iroh peer-to-peer transport

> **Status (production rollout, May 15 / May 16 UTC, 2026):** Phase A and
> Phase B are green on branch `chore/router-brand-coherent-rail`. The Rust
> crate checks in debug + release, all packaged Apple Rust targets
> cross-compile, the xcframework recipe produces local artifacts,
> `OpenBurnBarCore` builds/tests with and without the local binary artifact,
> macOS + iOS device + iOS Simulator app builds pass, Functions type-checks,
> and fresh GitHub checks are green on the repaired pushed branch head:
> Workflow Lint, OpenBurnBar Functional QA, OpenBurnBarIroh xcframework,
> openburnbar-iroh AAR (Android), OpenBurnBar PR Harness, and CodeQL.
>
> Phase B has a production monitoring path in source:
> `rollupIrohTransportDaily` aggregates raw Firestore `iroh_audit_events`
> into daily operator rollups under
> `ops/iroh_transport_daily_rollups/days/{YYYY-MM-DD}`. The Function is now
> production-live in `burnbar` as a scheduled Node 22 gen2 Function.
>
> Phase D hosted-relay validation is now in progress. Production Firestore
> rules are deployed, including the CLI mission `requestedModelID` /
> `selectedModelID` rule allowance needed for phone-selected model fidelity.
> The Iroh Services hosted relay is running at
> `https://use1-1.relay.alberto8793.burnbar.iroh.link/`, and Firebase Remote
> Config publishes that URL through `hermes_iroh_hosted_relay_url`. The first
> physical-iPhone hosted-relay E2E is green: the iPhone verified the Mac
> pairing, opened an iroh stream, the host decrypted and forwarded
> `/v1/chat/completions`, local Hermes returned HTTP `200`, the host emitted
> `response.complete`, and the stream closed without a newer WSS fallback.
> The mobile mission contract now also carries `requestedModelID` through
> CLI agent missions, and the trusted Mac runner applies that selected model
> to Hermes, Pi, OpenClaw, Codex, and Claude rather than falling back silently;
> live mission proofs completed for all five harnesses on May 16 UTC. Hosted
> relay response-frame sends currently show ~30 s per audited response frame,
> so the host/client chat timeouts are intentionally split at 300 s / 360 s
> while the remaining topology gate is gathered. The first scheduled monitoring
> readback was repaired after adding the required Firestore timestamp indexes.
> After the earlier `08:35Z` timeout reset the counter, the same-LAN
> physical-iPhone hosted-relay quota produced a clean historical 10-run streak:
> 10 consecutive Hermes completions from `2026-05-16T09:07Z` through `09:42Z`
> completed over `iroh-direct` with `requestedModel=gpt-5.4-mini`, iOS
> `ios_response_complete`, zero WSS fallbacks, and zero failure events. The
> installed iOS debug build now records `NWPath` network-interface audit detail
> on the iroh path. A later `09:54Z` topology preflight proved the phone was
> still on `wifi`, not cellular, then failed with `connection lost` and WSS
> fallback, so the formal Gate C/D streak is not closed. The final rollout gates
> are a renewed clean sequence that includes different-network/cellular topology
> and the Phase E TestFlight soak. See
> `docs/runbooks/iroh-rollout-status.md`.

This document is the engineering reference for migrating
[`HERMES_REALTIME_RELAY.md`](HERMES_REALTIME_RELAY.md) off Cloud Run +
Memorystore Redis + WSS onto an [iroh](https://www.iroh.computer/) QUIC
mesh between the Mac running AgentLens and the iOS/iPadOS clients running
OpenBurnBarMobile. The relay's role does not change: the Mac stays the
sole owner of the upstream Hermes session, the iPhone/iPad stays an
ephemeral client, and every payload remains AES-GCM-encrypted end-to-end
with `HermesRelayCrypto`. What changes is the wire: instead of two
WebSockets meeting inside a Cloud Run container, the two endpoints meet
over an iroh direct connection (NAT-holepunched) and fall back to an iroh
relay when holepunching fails.

## Why iroh

| Property | Cloud Run + WSS today | iroh tomorrow |
| --- | --- | --- |
| Pairing | Firestore handle exchange + Cloud Run socket auth | Firestore Ed25519-signed `irohNodeId` record + iroh QUIC mTLS |
| Wire | Two WSS hops via the relay container | One QUIC stream end-to-end, holepunched, with relayed fallback |
| Encryption | TLS to the relay + `HermesRelayCrypto` payload | iroh-tls to the peer + the same `HermesRelayCrypto` payload (unchanged) |
| Cold start | Up to ~3 s on Cloud Run autoscale | < 200 ms with cached NodeId after first pairing |
| Cost | Cloud Run vCPU/s + Memorystore | $200/mo n0 hosted relay tier (Phase 6+); $0 while staying on n0 public |
| Failure modes | Relay-side incident == full outage | Relay-only fallback == only LAN-blocked users see outage |

The relay contract — `HermesRealtimeRelayFrame`, `HermesRelayCrypto`
envelope, replay-protected AAD, `relayKeyVersion` — is unchanged. The
iroh transport is a drop-in replacement at the byte layer.

## Architecture

```
┌────────────────────────────┐          ┌───────────────────────────────┐
│  iOS / iPadOS (Hermes)     │          │  Mac (AgentLens)              │
│                            │          │                               │
│  HermesService             │          │  HermesRelayHostService       │
│        │                   │          │        │                      │
│  IrohRelayTransport ──┐    │  QUIC    │   ┌── IrohRelayTransport      │
│  (xcframework via FFI)│◀══════════════════▶│ (xcframework via FFI)    │
│        │              │    │          │   │       │                   │
│  IrohRelayFrameCodec  │    │          │   │  IrohRelayFrameCodec      │
│        │              │    │          │   │       │                   │
│  HermesRelayCrypto    │    │          │   │  HermesRelayCrypto        │
└────────────────────────────┘          └───────────────────────────────┘
              │                                          │
              └──── Firestore (pairing records) ─────────┘
                     /users/{uid}/iroh_pairing/{conn}
                     Ed25519-signed, replay-protected,
                     readable only by the pair.
```

`HermesRelayHostService` and `HermesService` keep their existing public
APIs. Only the transport object behind them changes; everything above
(`HermesRelayKeyStore`, `HermesRelayCrypto`, frame serialization) is
reused byte-for-byte.

## Repository layout

| Path | Role |
| --- | --- |
| `crates/openburnbar-iroh/` | Rust crate that wraps `iroh-net` + `iroh-blobs` and exposes a UniFFI surface (`bootstrap`, `identity`, `connect`, `accept_one`, `send_frame`, `recv_frame`, `shutdown`, `close`). |
| `scripts/build-iroh-xcframework.sh` | Builds the crate as an xcframework for `macos-arm64`, `ios-arm64`, and `ios-arm64-simulator + ios-x86_64-simulator`. It generates a pinned UniFFI Swift helper locally instead of relying on a global `uniffi-bindgen-swift` install. |
| `.github/workflows/iroh-xcframework.yml` | CI: builds + caches the xcframework and uploads it as a workflow artifact. |
| `scripts/ci/iroh-services.env.example` | Template for the n0 services API secret used by Phase 6+ (owned hosted relay). |
| `scripts/ci/load-iroh-services-secret.sh` | Loader that materializes `.secrets/iroh-services.env` from CI secrets. |
| `scripts/e2e/ios-iroh-chat.sh` | Physical-iPhone hosted-relay smoke runner. Starts the debug Mac host, launches the hidden Hermes E2E prompt route on iPhone, polls Firestore `iroh_audit_events`, and fails unless the expected phone `networkInterfaces` value plus `ios_response_complete` appear with no WSS fallback. |
| `scripts/e2e/ios-iroh-gate.sh` | Gate C/D sequence runner. Starts one debug Mac host, calls `ios-iroh-chat.sh` repeatedly, writes per-run Firestore event exports under `docs/runbooks/iroh-dev-validation/`, and stops on the first stream failure or WSS fallback. |
| `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/` | SwiftPM target. Contains the wire codec, transport protocol, in-process loopback transport, pairing helpers, audit contract, and the encrypted echo path. |
| `OpenBurnBarCore/Sources/OpenBurnBarIroh/Generated/` | UniFFI-generated Swift/C/modulemap bindings. Used only when `Vendor/OpenBurnBarIroh.xcframework` exists locally or in CI. |
| `OpenBurnBarCore/Tests/OpenBurnBarIrohRelayTests/` | XCTest suite (18 tests, all green on macOS arm64). |
| `services/hermes-realtime-relay/` | Existing Cloud Run relay. Stays in place while we burn down WSS traffic, then is decommissioned in Milestone 7. |

## Wire format

The wire is a length-prefixed JSON stream. `IrohRelayProtocol.WireFormat`
declares the constants:

```
[ u32 big-endian payload length ][ JSON-encoded HermesRealtimeRelayFrame ]
```

This is byte-identical to the existing relay's `serializeFrame` helper,
so the iroh transport can be A/B-tested against the WSS relay on the
same `HermesService` build by toggling the transport factory.

Two independent guards:

1. **`IrohRelayFrameCodec.maxFrameBytes`** (default 256 KiB) — drops
   frames before they hit the JSON decoder. Matches the Cloud Run relay
   payload ceiling.
2. **`HermesRealtimeRelayProtocol.maxFrameBytes`** — the existing in-app
   guard, kept identical so producers cannot silently exceed the
   transport limit.

`Data.removeFirst(_:)` does not re-base indices in Foundation. Both
`IrohRelayFrameCodec.decode` and `LoopbackStreamReceiveBuffer.drain`
explicitly re-base their buffers through `Data(buffer)` so the JSON
decoder always sees a zero-based view (see commit notes for the regression
test that exposed the bug).

## Media stream classes

The Mercury media rollout (`plans/2026-05-15-mercury-media-master-plan.md`) layers three new capabilities — file transfer, screen share, 1:1 video calling — onto this transport without bumping the ALPN. Stream classes are negotiated **in band** via the first frame on each new bi-stream.

| Stream class | Cardinality | Direction | QUIC discipline | Phase |
|---|---|---|---|---|
| `media.blob.advertise` | 1 per attachment, on existing Hermes control stream | Sender → receiver | Reliable, ordered (JSON envelope) | 1 |
| `media.blob.fetch` | 1 per attachment, dedicated stream | Receiver dials sender | Reliable, ordered (iroh-blobs) | 1 |
| `media.screen.video` | 1 per GOP (~60 frames at 30 fps) | Mac → iOS | Reliable, ordered, stream-per-GOP for head-of-line isolation | 3 |
| `media.video.{out,in}` | 1 per direction per GOP | Bidirectional | Reliable, ordered, stream-per-GOP | 5 |
| `media.audio.{out,in}` | none — datagrams | Bidirectional | QUIC datagrams (RTP-style) | 4 |
| `media.control` | 1 per session | Bidirectional | Reliable — RTCP-style sender reports, BWE, mute, terminate | 3 |

The chat-stream JSON envelope is extended (without breaking older peers) with three new `HermesRealtimeRelayFrameType` cases — `media.classify`, `media.blob.advertise`, `media.blob.ack` — and one new optional field `media: HermesRealtimeRelayMediaPayload?` on `HermesRealtimeRelayFrame`. Older clients omit the field on encode and skip the unknown frame types on decode, so chat traffic stays byte-identical pre-rollout. Full architecture, on-disk contract, and forward-compat reasoning live in `docs/HERMES_MEDIA_TRANSPORT.md`.

## Pairing

A device's iroh `NodeId` is *not* secret, but it must be authenticated to
prevent connection-hijacking. `IrohRelayPairing` solves this:

* On first launch the Mac generates an Ed25519 keypair via
  `CryptoKit.Curve25519.Signing.PrivateKey`. The private key is held in the
  Keychain via `IrohPairingKeyStore` (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
  The public key is published by `IrohPairingPublicKeyPublisher` to
  `users/{uid}/iroh_pairing_keys/host` (a dedicated singleton collection,
  not the per-account provider records) so iOS can fetch one canonical
  verifier per user without scanning provider docs. Schema:
  `IrohPairingPublicKeyDoc` in `functions/src/types.ts`.
* When a Mac wants to advertise an iroh `NodeId`, it signs
  `"openburnbar.iroh.pairing.v1|{uid}|{connectionId}|{nodeId}|{publishedAtMillis}"`
  with the Ed25519 key and writes the signed record to
  `/users/{uid}/iroh_pairing/{connectionId}`.
* When iOS reads the record, `IrohPairingSignature.verify` checks the
  signature against the published Ed25519 key, enforces a 24h freshness
  window, and rejects malformed/tampered records. Only after a clean
  verification does iOS dial the `NodeId`.

Firestore rules updates (Phase 2) restrict `/users/{uid}/iroh_pairing/*`
to `request.auth.uid == uid` for both reads and writes, mirroring the
existing relay handle rules.

## Encrypted echo path

`HermesIrohEcho` is the smallest end-to-end exchange we can ship without
booting the Mac-side Hermes gateway. It exists so the foundation PR can
be reviewed in isolation:

1. iOS encrypts `"hello iroh"` with a fresh AES-GCM symmetric key,
   wraps the key with the Mac's ECDH public key from `HermesRelayCrypto`,
   and sends a `request.start` frame over the iroh stream.
2. Mac decrypts the wrapped key, opens the payload, re-encrypts the body
   back to the same symmetric key, and emits `response.chunk` +
   `response.complete`.
3. iOS decrypts the chunk and confirms the round trip.

`testEchoRoundTripThroughLoopbackTransport` proves this works over the
in-process loopback transport. The xcframework transport will reuse the
exact same client/host code; only the `IrohRelayTransport` factory
changes.

## Migration milestones

The migration is sliced so each milestone is shippable on its own. All
seven phases now land in this PR.

| Phase | Scope | Status |
| --- | --- | --- |
| **1. Spine + crypto + transport contract** | Rust crate, xcframework workflow, Swift package target, frame codec, pairing primitives, in-process loopback transport, encrypted echo, full test coverage. | ✅ |
| **2. Real iroh transport (xcframework-backed)** | `IrohXcframeworkTransport` (Swift) + `IrohEndpointBackend` protocol + `OpenBurnBarIrohFFIBackend` (UniFFI bridge). Conditionally compiled with `#if canImport(OpenBurnBarIrohFFI)` so the SwiftPM package builds before the xcframework binary is published. | ✅ |
| **3. Pairing handshake in production** | `IrohPairingDirectory` protocol + `InMemoryIrohPairingDirectory` + `FirestoreIrohPairingDirectory` (Mac + iOS variants). `firestore.rules` gates `/users/{uid}/iroh_pairing/*` and `/users/{uid}/iroh_audit_events/*`. `functions/src/types.ts` ships `IrohPairingRecordDoc` + `IrohTransportAuditEventDoc`. `scripts/deploy-iroh-relay.sh` rolls the changes. | ✅ |
| **4. Real Hermes payload over iroh** | `HermesIrohRelayHostClient` (Mac) — accept-loop, request handler, pairing-record heartbeat. `HermesIrohRelayTransport` (iOS) — conforms to `HermesRelayTransporting`. Composite chain becomes iroh → WSS → Firestore. Feature flag `SettingsManager.hermesIrohTransportEnabled`. | ✅ |
| **5. Audit + RTT telemetry** | `IrohTransportAuditLogging` protocol + `FirestoreIrohAuditLogger`. Every stream open / close / failure / pairing event / fallback hop emits `IrohTransportAuditEventDoc` with `transport`, `rttMillis`, and `detail`. `rollupIrohTransportDaily` converts the raw per-user stream into daily success/fallback/RTT rollups for rollout gates. | ✅ |
| **6. Owned hosted relay** | Rust crate's `bootstrap()` takes a `relay_url` parameter; Swift transport exposes a `relayURLProvider` closure. Iroh Services provisions the managed relay in the dashboard; `scripts/cutover-n0-hosted-relay.sh` then publishes the captured URL through Firebase Remote Config so all devices pick it up on next boot. | ✅ |
| **7. Cloud Run relay retirement** | `docs/HERMES_IROH_RETIREMENT.md` — the operational runbook, gates, decommissioning steps, rollback playbook, and cost analysis. Cloud Run service deletion is the final step; the WSS adapter remains in source until 14 consecutive days of zero-fallback traffic. | ✅ |

## Failure model

* **iroh holepunch fails** — fall back to the n0 public (Phase ≤5) or
  hosted (Phase ≥6) relay. Observed in
  `HermesRelayHostService.connectionTransport == "iroh-relay"`.
* **iroh transport fails entirely** — fall back to the legacy Cloud Run
  WSS relay. Surfaced as `HermesRelayHostService.transportFailureCount`.
* **Pairing record stale** — iOS refuses to dial and surfaces a "Mac
  unreachable" banner identical to the current "host offline" state.
* **Pairing record signature invalid** — same as stale; surfaces as a
  "Could not verify Mac" banner with a re-pair affordance.

## Testing surface

The Phase 1 PR ships 18 tests:

* `IrohRelayFrameCodecTests` (5) — wire format symmetry, length-prefix
  endianness, oversize rejection, truncated-envelope rejection.
* `IrohRelayPairingSignatureTests` (6) — Ed25519 sign/verify happy path,
  tampering rejection, freshness window enforcement, wrong-key
  rejection, malformed signature handling, invalid public key handling.
* `IrohRelayLoopbackPrimitiveTests` (2) — transport handshake, dial /
  accept ordering.
* `HermesIrohEchoLoopbackTests` (3) — end-to-end encrypted echo over the
  loopback transport, host rejecting tampered ciphertext, dial failing
  on an unknown peer.
* `IrohRelayCryptoSpotCheckTests` (2) — `HermesRelayCrypto.wrap/unwrap`
  symmetric-key round trip and request/chunk AAD round trip.

The xcframework workflow runs the same XCTest plan plus a
device-attached round-trip against the real iroh stack (Phase 2).

## References

* iroh: <https://www.iroh.computer/>
* `iroh-ffi` status (paused by n0): <https://github.com/n0-computer/iroh-ffi>
* `HERMES_REALTIME_RELAY.md` (current Cloud Run relay)
* `HERMES_MOBILE_TOOLS.md` (consumer of the relay)
* `services/hermes-realtime-relay/` (relay source)
