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

See `docs/architecture/008-remote-control-engine.md` for the architecture,
feasibility assessment, performance assumptions, and P0 risks.
