# OpenBurnBar iroh library

Rust library providing Ed25519-authenticated P2P QUIC connections via UniFFI-generated bindings. Powers Mercury media (file transfer, screen share, 1:1 calls) and Agent Watch on both iOS and Android.

**Location:** `crates/openburnbar-iroh/`

## Purpose

A thin Rust crate wrapping the [iroh](https://crates.io/crates/iroh) QUIC + NAT-traversal stack with:
- UniFFI `#[export]` attributes generating Swift and Kotlin bindings from one Rust source
- `iroh-blobs` for content-addressed file transfer (Mercury Phase 1)
- A `datagrams.rs` UniFFI surface for the `MercuryAudioDatagramChannel` (low-latency audio)
- Ed25519 key representation via iroh's built-in secret key type (signing/verification stays in Swift CryptoKit)

## Build artifacts

| Artifact | Platform | Location |
|---|---|---|
| `OpenBurnBarIroh.xcframework` | iOS / macOS | `Vendor/OpenBurnBarIroh.xcframework` |
| `openburnbar-iroh.aar` | Android | `Vendor/openburnbar-iroh.aar` |

## Building the iOS xcframework

```bash
scripts/build-iroh-ios-xcframework.sh  # if present
# or via Xcode Package Resolution pointing at the local xcframework
```

The crate produces a `staticlib` for linking into the xcframework binary and a `cdylib` used by `uniffi-bindgen` at host time.

## Building the Android AAR

```bash
scripts/build-iroh-android-aar.sh
```

- Runs `cargo-ndk` for four ABIs: `arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64`
- Generates Kotlin bindings via `uniffi-bindgen-kotlin` pinned to `0.28.3`
- Packages binary + `classes.jar` + manifest into `Vendor/openburnbar-iroh.aar`
- Auto-installs NDK, `cargo-ndk`, and required Rust targets if missing

## Kotlin module

The `:openburnbar-iroh-relay` Gradle module (`android/openburnbar-iroh-relay/`) is a Kotlin 1:1 port of the Swift `OpenBurnBarIrohRelay` package — same wire format, same ALPN strings, same big-endian u32 length prefix, same `HermesRealtimeRelayFrame` JSON envelope, same Ed25519 pairing signature verification (via Tink, since JDK Ed25519 only ships on API 31+).

## Fallback behavior

`OpenBurnBarIrohFfiBackend` checks for the AAR/xcframework at runtime and gates cleanly when absent:

- **Dev:** loopback transport — same API surface, in-process delivery
- **Prod:** Firestore real-time listeners for signaling; no direct P2P

The app and daemon build without the AAR. Mercury media features are unavailable until the AAR is present.

## Dependency pins

```toml
iroh = "=1.0.0-rc.0"
iroh-dns = "=1.0.0-rc.0"
iroh-blobs = "0.101.0"
iroh-services = "=1.0.0-rc.0"
```

Pins are exact for xcframework build reproducibility. `iroh-blobs` must stay in lockstep with `iroh` — mismatched major lines produce duplicate endpoint types the UniFFI bridge cannot safely mix.

## Crate types

```toml
crate-type = ["staticlib", "cdylib", "rlib"]
```

- `staticlib` — linked into the xcframework binary
- `cdylib` — used by `uniffi-bindgen` CLI for introspection at build time
- `rlib` — for Rust unit tests and downstream Rust consumers
