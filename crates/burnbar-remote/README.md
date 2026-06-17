# BurnBar Remote Engine

This nested Cargo workspace is the Rust foundation for the next-generation
remote desktop, screen-share, and human-in-the-loop control substrate. It is
isolated under `crates/burnbar-remote/` so it can evolve without destabilizing
the existing Swift/Kotlin/Functions worktree or the current UniFFI
`openburnbar-iroh` bridge.

`burnbar-remote-ffi` is the cross-platform UniFFI facade for that foundation.
It currently exports a stable readiness surface, permission checks, dimension
scaling, and the adaptive-quality controller used by the media path. Build
artifacts mirror the iroh bridge:

```bash
cargo test --manifest-path crates/burnbar-remote/Cargo.toml -p burnbar-remote-ffi
./scripts/build-burnbar-remote-xcframework.sh
./scripts/build-burnbar-remote-android-aar.sh
```

The Apple build emits `Vendor/BurnBarRemote.xcframework` plus generated Swift
bindings under `OpenBurnBarCore/Sources/BurnBarRemote/Generated/`. The Android
build emits `Vendor/burnbar-remote.aar` plus generated Kotlin bindings under
`android/burnbar-remote/src/main/java/uniffi/burnbar_remote/`. The app-facing
Swift/Kotlin wrappers compile without those artifacts and report
`nativeBridgeAvailable=false` until the generated bindings are present.

The transport crate uses the repo-pinned `iroh =1.0.0-rc.0` API directly:
endpoint identity, authenticated QUIC connections, relay fallback, reliable
streams, unreliable datagrams, path events, RTT, datagram MTU, and datagram
send-buffer telemetry.

See `docs/architecture/008-remote-control-engine.md` for the architecture,
feasibility assessment, performance assumptions, and P0 risks.

Security hardening details and proof commands live in `SECURITY.md`. The short
version: session authorization is now a wire handshake, signed grants verify
against trusted workspace signers and the client request nonce, macOS secure
storage is implemented behind the `macos-keychain` feature, and the file audit
sink is tamper-evident JSONL with sensitive details stored only as hashes.
