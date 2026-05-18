# openburnbar-iroh

Rust core that backs the `OpenBurnBarIroh` Swift package. Wraps
[iroh](https://docs.iroh.computer) and exposes a tiny UniFFI surface — eight
functions, total — that the Swift side compiles into the
`OpenBurnBarIroh.xcframework`:

| Rust symbol | Swift wrapper | Purpose |
|---|---|---|
| `IrohEndpointHandle::new` | `OpenBurnBarIrohEndpoint.makeHandle()` | Allocate an empty handle |
| `IrohEndpointHandle::bootstrap` | `OpenBurnBarIrohEndpoint.bootstrap(secret:)` | Spawn iroh endpoint with persisted secret key |
| `IrohEndpointHandle::identity` | `OpenBurnBarIrohEndpoint.identity()` | Read cached `NodeId` |
| `IrohEndpointHandle::connect` | `OpenBurnBarIrohEndpoint.connect(toNodeId:timeout:)` | Dial peer, open bidirectional stream |
| `IrohEndpointHandle::accept_one` | `OpenBurnBarIrohEndpoint.acceptOne(timeout:)` | Wait for inbound bidirectional stream |
| `IrohEndpointHandle::shutdown` | `OpenBurnBarIrohEndpoint.shutdown()` | Tear down endpoint + tokio runtime |
| `generate_secret_key_material` | `IrohSecretKeyMaterial.generate()` | New 32-byte secret (cold start) |
| `openburnbar_alpn` / `openburnbar_iroh_protocol_version` | Constants in `IrohRelayProtocol` | Wire-version pinning |

Stream lifecycle is owned by Swift; the Rust side just length-prefixes JSON
frames (big-endian u32 + payload) and forwards them to/from iroh's QUIC
streams. The frame format is `HermesRealtimeRelayFrame` JSON, encrypted by
`HermesRelayCrypto`, exactly like the current Cloud Run relay — see the spec
in `docs/HERMES_IROH_TRANSPORT.md`.

## Why so small

n0 paused the official iroh-ffi releases in Feb 2025
(<https://www.iroh.computer/blog/ffi-updates>). Community bindings exist but
drift on someone else's schedule. Owning an 8-function surface in-tree is
cheap and removes a runtime-stability risk from the critical path.

## Build

```bash
# host-side validation (used by `scripts/build-iroh-xcframework.sh`):
cargo check -p openburnbar-iroh
cargo test  -p openburnbar-iroh

# full xcframework:
./scripts/build-iroh-xcframework.sh
```

Outputs land at `Vendor/OpenBurnBarIroh.xcframework/`, consumed by the
`OpenBurnBarIroh` SwiftPM target in `OpenBurnBarCore/Package.swift`.
