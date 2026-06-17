# BurnBar Remote Engine

This nested Cargo workspace is the Rust foundation for the next-generation
remote desktop, screen-share, and human-in-the-loop control substrate. It is
isolated under `crates/burnbar-remote/` so it can evolve without destabilizing
the existing Swift/Kotlin/Functions worktree or the current UniFFI
`openburnbar-iroh` bridge.

The transport crate uses the repo-pinned `iroh =1.0.0-rc.0` API directly:
endpoint identity, authenticated QUIC connections, relay fallback, reliable
streams, unreliable datagrams, path events, RTT, datagram MTU, and datagram
send-buffer telemetry.

The cross-platform FFI surface lives in `burnbar-remote-ffi` and is exported
with UniFFI to both app stacks:

- `./scripts/build-burnbar-remote-xcframework.sh` rebuilds
  `Vendor/BurnBarRemote.xcframework` and the committed Swift bindings under
  `OpenBurnBarCore/Sources/BurnBarRemote/Generated/`.
- `./scripts/build-burnbar-remote-android-aar.sh` rebuilds
  `Vendor/burnbar-remote.aar` and the committed Kotlin bindings under
  `android/burnbar-remote/src/main/java/uniffi/burnbar_remote/`.
- The Swift `BurnBarRemoteEngine` package product and Android
  `:burnbar-remote` module keep deterministic fallback behavior when the native
  artifact is absent, and the CI smoke tests require a real native round trip
  when the artifact is present.

Follow-up: keep `burnbar-remote` and `openburnbar-iroh` on the same Iroh line.
Both remain intentionally pinned to the release-candidate family until the repo
can migrate the kept crates to Iroh 1.0 stable in one reviewed pass.

See `docs/architecture/008-remote-control-engine.md` for the architecture,
feasibility assessment, performance assumptions, and P0 risks.

Security hardening details and proof commands live in `SECURITY.md`. The short
version: session authorization is now a wire handshake, signed grants verify
against trusted workspace signers and the client request nonce, macOS secure
storage is implemented behind the `macos-keychain` feature, and the file audit
sink is tamper-evident JSONL with sensitive details stored only as hashes.
