# ADR 008: Iroh-First Remote Control Engine

## Status

Accepted as an implementation spine for `crates/burnbar-remote/`.

## Blunt Feasibility Assessment

Building a Parsec/Splashtop/AnyDesk-class remote-control substrate on Iroh is feasible, but only if the product treats Iroh as the encrypted authenticated connectivity layer and keeps media, authorization, congestion policy, and audit semantics at the application layer.

The direct-path targets are plausible only on favorable hardware and OS paths:

| Path | Target | Assumptions | Bottlenecks | Fallback |
| --- | --- | --- | --- | --- |
| LAN / excellent P2P 1080p60 | P50 <16 ms motion-to-photon, P95 <28 ms, P99 <50 ms | ScreenCaptureKit/Windows Graphics Capture/PipeWire DMA-BUF produce GPU frames, hardware encoder is in low-latency mode, decode/render stay on GPU, display vsync is favorable | OS capture cadence, encoder queue depth, decode reorder, display compositor | drop frames, lower resolution, cursor-only updates |
| LAN / excellent P2P 4K60 | P50 <33 ms, P95 <55 ms, P99 <90 ms | hardware AV1/HEVC encode and decode, wired or clean Wi-Fi, no relay | encoder throughput, GPU interop copies, display sync | 1440p or 1080p stream upscaled client-side |
| 4K120 | aspirational | high-end GPU encoder/decoder, high-refresh display, excellent direct path, no OS compositor stalls | capture and display timing dominate | fall back to 4K60/1440p120 |
| WAN direct | responsiveness over fidelity | RTT and loss vary; readable UI beats fixed 4K | jitter, packet loss, queue buildup | fast downshift bitrate/fps/resolution before adding latency |
| Iroh relay | graceful degraded mode | relay bandwidth is scarce and expensive | relay egress, higher RTT, possible MTU limits | aggressive caps, client upscale, bandwidth-saver profile |

Instrumentation must report capture, encode, packetize, send, receive, decode, render, input-to-effect, and glass-to-glass timings as P50/P95/P99. The current Rust skeleton includes telemetry structs and a synthetic controller harness; platform capture/codec timing probes are separate OS-specific work.

## Decision

Create a nested Rust workspace at `crates/burnbar-remote/` with Iroh isolated in the network crate:

```text
crates/burnbar-remote/
  burnbar-remote-core/           shared ids, permissions, session state, frame metadata, bounded queues
  burnbar-remote-protocol/       binary stream/datagram framing, version constants, control serialization
  burnbar-remote-observability/  network telemetry, receiver reports, latency histograms
  burnbar-remote-security/       device authorization, session grants, anti-replay window
  burnbar-remote-media/          capture/encoder/decoder/renderer/input traits, adaptive controller
  burnbar-remote-network/        Iroh endpoint manager, stream classification, datagram media path
  burnbar-remote-host/           host-side composition seam
  burnbar-remote-client/         client-side composition seam
  burnbar-remote-bench/          synthetic stage-level benchmark harness
```

The workspace is nested instead of repo-root because the current repository already has an independent UniFFI Iroh crate and an active dirty Swift/Kotlin/Functions worktree.

## Architecture Diagram

```text
            host machine                                      client / phone / supervisor
┌─────────────────────────────────────┐                ┌────────────────────────────────────┐
│ OS capture                          │                │ IrohTransportManager               │
│ ScreenCaptureKit / WGC / PipeWire   │                │  ├─ media datagrams recv            │
│        │                            │                │  ├─ control stream send             │
│        ▼                            │                │  └─ telemetry stream send           │
│ HardwareEncoder                     │                │        │                            │
│ AV1/HEVC/H264 low-latency           │                │        ▼                            │
│        │                            │                │ HardwareDecoder → Upscaler → Render │
│        ▼                            │                │        ▲                            │
│ Packetizer                          │                │        │ receiver reports             │
│        │ media datagrams            │                │        │                            │
│        ▼                            │     Iroh       │ Input capture ─ reliable control ──┤
│ IrohTransportManager ◀══════════════════════════════▶│ Authorization-bound session         │
│  ├─ Endpoint identity / QUIC / NAT   │ direct/relay   │                                    │
│  ├─ reliable control streams         │ encrypted      └────────────────────────────────────┘
│  ├─ unreliable media datagrams       │
│  └─ path telemetry adapter           │
│        ▲                            │
│        │                            │
│ SessionAuthorizer → consent → RBAC → InputInjector
│        │
│ Audit sink / kill switch / revocation
└─────────────────────────────────────┘
```

## Core Data Paths

### Capture to Iroh Send

1. `ZeroCopyCapture::next_frame` returns a `GpuFrame` descriptor plus platform handle.
2. `HardwareEncoder::encode` consumes the frame using low-latency settings.
3. `DatagramPacketizer::packetize` emits bounded datagrams with fixed 32-byte media headers.
4. `AuthorizedConnection::try_send_media_datagram` uses Iroh `Connection::send_datagram`, never `send_datagram_wait`.
5. If datagram buffer space is insufficient, the packet is dropped and telemetry increments `dropped_media_datagrams`.

### Iroh Receive to Render

1. Client receives datagrams with `Connection::read_datagram`.
2. Protocol decodes `MediaDatagramHeader`.
3. `DatagramDepacketizer` reassembles complete frames by `(stream_id, frame_id)` and drops stale partial frames when deadlines expire.
4. `HardwareDecoder` decodes to GPU frame.
5. Optional `Upscaler` performs spatial/temporal/text-preserving upscaling.
6. `Renderer` presents at the target time and emits receiver reports.

### Client Input to Host Injection

1. Client opens a reliable bi-stream and writes `StreamClass::Control` as byte 0.
2. Input envelopes are length-prefixed control frames.
3. Host verifies the session grant, permissions, expiry, replay sequence, rate limit, kill switch, high-risk confirmation, focus state, and local consent.
4. `InputInjector` performs OS-specific injection only after authorization.
5. High-risk actions go through policy checks and audit.

### Telemetry to Controller

1. Iroh path state supplies selected path, relay/direct classification, RTT, datagram MTU, and datagram buffer space.
2. Receiver reports supply frame age, decode/render time, loss, and keyframe pressure.
3. `AdaptiveQualityController` fast-downshifts on loss, stale frames, queue pressure, relay, or slow decode/render.
4. Recovery is slow and hysteretic to avoid oscillation.

## Iroh Transport Manager

Implemented in `burnbar-remote-network` against `iroh =1.0.0-rc.0`.

Real public API used:

- `Endpoint::builder(presets::N0)`
- `Builder::secret_key`
- `Builder::alpns`
- `Builder::relay_mode`
- `Builder::transport_config`
- `Endpoint::connect`
- `Endpoint::accept`
- `Connection::remote_id`
- `Connection::{open_bi,accept_bi}`
- `Connection::{send_datagram,read_datagram,max_datagram_size,datagram_send_buffer_space}`
- `Connection::{paths,path_events,close}`

Traffic separation:

| Traffic | Channel | Delivery |
| --- | --- | --- |
| video packets | Iroh datagrams | unreliable, unordered, stale packets dropped |
| audio packets | Iroh datagrams | unreliable with jitter-buffer/PLC downstream |
| input | reliable `StreamClass::Control` | ordered, session-bound, replay-protected |
| permissions/session lifecycle | reliable `StreamClass::Control` | ordered |
| telemetry/receiver reports | reliable `StreamClass::Telemetry` or datagram reports | latest-state-wins where safe |
| clipboard/file metadata | reliable stream | ordered and bounded |

## Media Platform Paths

| Platform | Intended path | Copy class target | Key risk |
| --- | --- | --- | --- |
| macOS | ScreenCaptureKit → IOSurface/CVPixelBuffer → VideoToolbox → wgpu/Metal | GPU-to-GPU zero-copy when IOSurface interop holds | CVPixelBuffer/IOSurface lifetime and Metal texture wrapping |
| Windows | Windows.Graphics.Capture/DXGI → D3D texture → NVENC/AMF/QuickSync/MF → wgpu/DX12 | GPU-to-GPU zero-copy | cross-adapter texture sharing |
| Linux | PipeWire DMA-BUF → VAAPI/NVENC/AMF/Vulkan Video → wgpu/Vulkan | true zero-copy or single-copy depending driver | DMA-BUF modifier import/export mismatch |

The traits explicitly allow `TrueZeroCopy`, `GpuToGpuZeroCopy`, `SingleCopyFallback`, `CpuFallback`, and `Unsupported`. No platform is assumed to be universally zero-copy.

`MediaCapabilitySet::choose_codec` makes codec selection conditional:

- Quality / bandwidth saver: AV1, then HEVC, then H264 when hardware encode/decode supports the target dimensions and fps.
- Responsiveness: H264, then HEVC, then AV1 because encoder latency can matter more than bitrate savings.
- Unsupported hardware paths do not win selection just because the codec is theoretically better.

## Security Invariants

- Iroh endpoint identity is not authorization.
- A relay ticket, endpoint ID, or URL is not authorization.
- Remote control requires a short-lived `SessionGrant`.
- Session grants bind account, workspace, host device, client device, mode, permissions, issue time, and expiry.
- View-only and control are separate modes.
- Control events require permission checks and anti-replay sequence validation.
- Revoked devices cannot reconnect.
- Expired sessions cannot resume control.
- Relays are not trusted with plaintext.
- Local consent and visible session indication are host responsibilities, not transport conveniences.
- `ControlPolicyGate` enforces kill switch, high-risk confirmation, anti-replay, rate limiting, and grant permission checks before OS input injection.
- `PairingTicket` is short-lived and converts into a paired device record only before expiry.
- `SignedSessionGrant` signs a domain-separated postcard-serialized grant with Ed25519 and rejects tampered grant payloads.
- `SecureKeyStore` is a trait boundary; production implementations must use Keychain, DPAPI, Secret Service/KWallet, Secure Enclave, Android Keystore, or equivalent OS-native storage where available.
- `AuditSink` is append-only at the trait boundary; production sinks must be content-addressed and tamper-evident before high-risk control is enabled by default.

## Test And Benchmark Plan

Implemented now:

- `cargo test --workspace` covers bounded media queues, binary protocol framing, datagram packetization/reassembly, same-frame-id multi-stream reassembly, stale partial-frame discard, codec target filtering, adaptive downshift/recovery, pairing expiry, key storage, consent, replay, rate limiting, high-risk confirmation, signed-grant domain separation and tamper rejection, audit append, and kill switch.
- `burnbar-remote-bench` produces synthetic P50/P95/P99 upper-bound summaries for capture, encode, packetize, network send, network receive, decode, render, input-to-effect, and glass-to-glass stages.

Required before production:

- Hardware capture timestamp probe per platform.
- Encoder queue-depth and encode-latency probe per codec/vendor.
- Iroh direct-vs-relay benchmark with packet loss and jitter injection.
- End-to-end glass-to-glass camera rig or OS compositor timestamp correlation.
- Allocation profiling for capture/encode/packetize/send and receive/decode/render hot paths after platform implementations land.
- Remote-control safety harness proving no input injection occurs without consent, grant, replay acceptance, rate-limit allowance, and inactive kill switch.

## Assumptions Requiring Verification

- Iroh `1.0.0-rc.0` path statistics remain stable enough for production controller inputs.
- Close `PathStats` expose sufficient loss/bytes counters for session summaries; live loss may still require receiver reports.
- Datagram MTU and buffer-space behavior under relay matches the controller’s drop policy.
- Iroh Services hosted relay telemetry can be correlated to app session IDs without leaking content.
- OS-specific GPU handle lifetimes can be represented safely without forcing CPU copies.
- Hardware AV1 encode latency is acceptable on the target Mac/Windows/Linux GPU matrix.
- VideoToolbox, NVENC, AMF, QuickSync, VAAPI, and Vulkan Video low-latency knobs can be unified without lying about unsupported settings.

## P0 Engineering Risks

1. GPU interop copies silently blow the latency budget.
2. Encoder queues preserve quality instead of dropping stale frames.
3. Relay cost/egress becomes the product bottleneck under abuse or poor NAT populations.
4. Control stream starvation under media load if priorities are not enforced.
5. Authorization drift between local device trust, account/workspace RBAC, and transport identity.
6. Replay protection gaps during reconnect/resume.
7. Platform permission UX allows confusing or silent control.
8. Incomplete audit chain around high-impact actions.
9. Controller oscillation under jitter if receiver reports are noisy.
10. Cross-platform codec negotiation picks AV1 where encode latency or decode support is worse than HEVC/H264.

## Consequences

The first implementation is not a full remote desktop product. It is the compile-checked spine for the product: bounded queues, fixed wire classes, real Iroh datagram/stream use, authorization callbacks before session construction, explicit media/control separation, packetization/reassembly, security policy gates, stage-level benchmark reporting, and testable adaptive policy.

The next production steps are platform-specific:

- macOS ScreenCaptureKit + VideoToolbox prototype with IOSurface lifetime tests.
- Real audit sink and OS keychain-backed device identity.
- End-to-end LAN benchmark harness with real capture/encode/network/decode/render timestamps.
- Platform input-injection adapters with permission prompt/state detection and host-visible session indicator.
