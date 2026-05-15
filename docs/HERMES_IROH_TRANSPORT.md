# Hermes Realtime Relay → iroh peer-to-peer transport

> **Status (Phase 1, May 2026):** Foundation landed. The Rust crate, Swift
> Package target, frame codec, Ed25519 pairing primitives, and an end-to-end
> encrypted echo path over an in-process loopback transport are all green
> in CI. The xcframework build is wired up in
> `.github/workflows/iroh-xcframework.yml`; the real
> `IrohRelayTransport` (xcframework-backed) is scheduled for Phase 2.

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
| `scripts/build-iroh-xcframework.sh` | Builds the crate as an xcframework for `macos-arm64`, `ios-arm64`, and `ios-arm64-simulator + ios-x86_64-simulator`. |
| `.github/workflows/iroh-xcframework.yml` | CI: builds + caches the xcframework, attaches it to a release tag. |
| `scripts/ci/iroh-services.env.example` | Template for the n0 services API secret used by Phase 6+ (owned hosted relay). |
| `scripts/ci/load-iroh-services-secret.sh` | Loader that materializes `.secrets/iroh-services.env` from CI secrets. |
| `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/` | SwiftPM target. Contains the wire codec, transport protocol, in-process loopback transport, pairing helpers, and the encrypted echo path. |
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

## Pairing

A device's iroh `NodeId` is *not* secret, but it must be authenticated to
prevent connection-hijacking. `IrohRelayPairing` solves this:

* On first launch the Mac (or the iOS app) generates an Ed25519 keypair
  via `CryptoKit.Curve25519.Signing.PrivateKey`. The private key is held
  in the Keychain via `HermesRelayKeyStore`. The public key is published
  to Firestore as `provider_accounts/{uid}.irohPairingPublicKey` (same
  document the existing relay uses).
* When a Mac wants to advertise an iroh `NodeId`, it signs
  `"openburnbar.iroh.v1|{uid}|{connectionId}|{nodeId}|{publishedAtMillis}"`
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

The migration is sliced so each milestone is shippable on its own. Phase
1 covers the foundation in this PR. Phases 2–7 follow.

| Phase | Scope | PR status |
| --- | --- | --- |
| **1. Spine + crypto + transport contract** | Rust crate, xcframework workflow, Swift package target, frame codec, pairing primitives, in-process loopback transport, encrypted echo, full test coverage. | **✅ this PR** |
| 2. Real iroh transport (xcframework-backed) | `IrohRelayTransport` implementation that talks to the Rust crate through UniFFI. Replaces the loopback transport behind the same `IrohRelayTransport` protocol. | next PR |
| 3. Pairing handshake in production | Mac publishes signed `irohNodeId`; iOS reads, verifies, dials. Firestore rules + `functions/src/types.ts` schema updated; `scripts/deploy-iroh-relay.sh` ships the rule changes. | next PR |
| 4. Real Hermes payload over iroh | `HermesRelayHostService` and `HermesService` both gain a transport selector. Feature-flagged via `SettingsManager.hermesIrohTransportEnabled`. Falls back to WSS on any iroh handshake failure. | follow-up |
| 5. Quota and audit | Mac-side quota controls preserved; Firestore audit log updated with `transport: "iroh"` and observed RTT distributions. | follow-up |
| 6. Owned hosted relay | Cut over from n0 public relay to the $200/mo n0 hosted tier via the services API; secret loader is already in place. | follow-up |
| 7. Cloud Run relay retirement | Once iroh carries 100% of relay traffic for 14 consecutive days with zero fallback, the Cloud Run service + Memorystore instance are decommissioned. | follow-up |

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
