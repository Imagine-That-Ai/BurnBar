# Packages

Workspace packages that other parts of the codebase import.

## OpenBurnBarCore

Shared Swift package containing wire types, RPC contracts, and utilities used by the macOS app, iOS app, and daemon.

→ [OpenBurnBarCore](openburnbar-core.md)

## OpenBurnBar iroh

Rust crate (`crates/openburnbar-iroh/`) compiled to `Vendor/openburnbar-iroh.xcframework` (iOS/macOS) and `Vendor/openburnbar-iroh.aar` (Android) via UniFFI. Single source of truth for P2P transport.

→ [OpenBurnBar iroh](openburnbar-iroh.md)
