# OpenBurnBar iroh

The Rust crate that powers P2P transport across macOS, iOS, and Android via UniFFI bindings.

## Purpose

Provide a single source of truth for Ed25519-authenticated P2P transport. One crate compiles to both `Vendor/openburnbar-iroh.xcframework` (iOS/macOS) and `Vendor/openburnbar-iroh.aar` (Android).

## Directory layout

```
crates/openburnbar-iroh/
  src/
    lib.rs              # Main crate entry: node management, connection setup
    datagrams.rs        # Mercury audio datagram channel over ALPN
    pairing.rs          # Ed25519 pairing and verification
  Cargo.toml
  build.rs             # UniFFI scaffolding generation
```

## Key abstractions

| Type | File | Purpose |
|------|------|---------|
| `OpenBurnBarIrohNode` | `src/lib.rs` | iroh node lifecycle: start, stop, dial |
| `MercuryAudioDatagramChannel` | `src/datagrams.rs` | Audio datagrams over ALPN `openburnbar/mercury/audio/1` |
| `PairingVerifier` | `src/pairing.rs` | Ed25519 signature verification |

## How it works

1. **UniFFI bindings** — `uniffi-bindgen-kotlin` and `uniffi-bindgen-swift` generate bindings from the same UDL file, pinned to UniFFI 0.28.3.
2. **Compilation** — `scripts/build-iroh-android-aar.sh` runs `cargo-ndk` for four ABIs and packages the binary + classes.jar + manifest.
3. **Wire format** — big-endian u32 length prefix followed by JSON `HermesRealtimeRelayFrame`. ALPN `openburnbar/1` for general transport, `openburnbar/mercury/audio/1` for audio.
4. **Fallback** — Android's `OpenBurnBarIrohFfiBackend` gates cleanly when the AAR is missing, falling back to loopback transport for dev and Firestore for prod.

## Integration points

- **macOS/iOS** — linked as `Vendor/openburnbar-iroh.xcframework`.
- **Android** — linked as `Vendor/openburnbar-iroh.aar` in the `:openburnbar-iroh-relay` module.

## Entry points for modification

- Change Rust logic in `crates/openburnbar-iroh/src/`.
- Rebuild with `scripts/build-iroh-android-aar.sh` (Android) or Xcode build (iOS/macOS).
- Update tests in `OpenBurnBarMobileTests/` or `:openburnbar-iroh-relay:testDebugUnitTest`.

## Related pages

- [Iroh transport](../systems/iroh-transport.md)
- [Mercury media](../features/mercury-media.md)
- [Hermes relay](../systems/hermes-relay.md)
