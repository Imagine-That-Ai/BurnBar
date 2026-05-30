# Packages

Swift packages and Rust crates that are consumed by multiple targets (macOS app, iOS app, Android app, daemon) and must stay in sync.

## OpenBurnBarCore

Swift package containing shared wire types, protocols, and schema models. Used by the macOS app, iOS companion, and the daemon. The strict process boundary between the app and daemon requires both sides to agree on every Codable key — this package is that agreement.

→ [OpenBurnBarCore](openburnbar-core.md)

## iroh library

Rust crate providing Ed25519-authenticated P2P connections via UniFFI-generated bindings for Swift (xcframework) and Kotlin (AAR). The same Rust source powers Mercury media and Agent Watch on both iOS and Android.

→ [OpenBurnBar iroh library](openburnbar-iroh.md)
