# iroh transport

Ed25519-authenticated P2P QUIC transport for Mercury media (file transfer, screen share, 1:1 calls) and Agent Watch (live Mac screen mirror to iOS/Android).

## Rust crate

**Location:** `crates/openburnbar-iroh/`  
**Cargo.toml:** `crates/openburnbar-iroh/Cargo.toml`

```
[package]
name = "openburnbar-iroh"
version = "0.1.0"
crate-type = ["staticlib", "cdylib", "rlib"]
```

Key dependencies: `iroh = "=1.0.0-rc.0"`, `iroh-blobs = "0.101.0"`, `uniffi = "0.28"`, `tokio`.

## UniFFI bindings

The crate exposes `#[uniffi::export]` attributed APIs — no `.udl` file needed. UniFFI generates both Swift (xcframework) and Kotlin (AAR) bindings from the same Rust source.

## Platform packages

| Platform | Artifact | How it gets built |
|---|---|---|
| iOS / macOS | `Vendor/OpenBurnBarIroh.xcframework` | Xcode package resolution or `scripts/build-iroh-ios-xcframework.sh` |
| Android | `Vendor/openburnbar-iroh.aar` | `scripts/build-iroh-android-aar.sh` |

### Building the Android AAR

```bash
scripts/build-iroh-android-aar.sh
```

Runs `cargo-ndk` for four ABIs: `arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64`. Generates Kotlin bindings via `uniffi-bindgen-kotlin` (pinned to `0.28.3`). Packages binary + `classes.jar` + manifest into `Vendor/openburnbar-iroh.aar`.

Auto-installs NDK, `cargo-ndk`, and Rust targets if missing.

## ALPN channels

| ALPN | Purpose |
|---|---|
| `openburnbar/1` | Relay channel — HermesRealtimeRelayFrame JSON envelope for screen share, audio, control, Agent Watch |
| `openburnbar/mercury/audio/1` | Audio datagrams — MercuryAudioDatagramChannel (exposed via `datagrams.rs` UniFFI surface) |

## Wire format

- **Length prefix:** big-endian u32 (4 bytes) preceding every frame
- **Envelope:** `HermesRealtimeRelayFrame` JSON
- **Pairing signature:** Ed25519, computed in Swift CryptoKit (canonical signer/verifier). Rust side only carries the iroh secret-key representation; no re-derivation of Ed25519 in Rust.

## Fallback behavior

`OpenBurnBarIrohFfiBackend` gates cleanly when the AAR or xcframework is absent:

- **Dev:** loopback transport
- **Prod:** Firestore real-time listeners

The Android app still builds and runs without the AAR; iroh-based media features are simply unavailable until the AAR is present.

## Content-addressed blob transfer

`iroh-blobs = "0.101.0"` rides the same endpoint family as the relay channel. Used by Mercury Phase 1 file transfer (`publish_blob` / `fetch_blob`). Must stay in lockstep with the `iroh` major line — mismatched versions produce duplicate endpoint types the UniFFI bridge cannot safely mix.

## Related files

| File | Purpose |
|---|---|
| `AgentLens/Services/IrohRelay/HermesIrohRelayHostClient.swift` | ~24KB Mac-side relay host client |
| `AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift` | ~53KB request handler |
| `AgentLens/Services/IrohRelay/IrohRelayKeyStore.swift` | Key storage |
| `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/` | Transport-agnostic relay protocol, pairing, loopback transport |
| `android/openburnbar-iroh-relay/` | Kotlin 1:1 port of Swift `OpenBurnBarIrohRelay` package |
