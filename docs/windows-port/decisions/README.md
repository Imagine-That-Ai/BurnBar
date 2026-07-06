# Windows-port decision records (WPD)

Phase-by-phase decision records for the Windows port
([`docs/WINDOWS_PORT_MASTER_PLAN.md`](../../WINDOWS_PORT_MASTER_PLAN.md)). These
capture **context / decision / rationale / consequences** for choices made while
executing the port under Zenith + the software factory. They are distinct from
the cross-cutting engineering [ADRs](../../ARCHITECTURE/README.md): a WPD becomes
an ADR only if the choice outlives the port and governs the whole codebase.

| WPD | Topic | Contract |
|-----|-------|----------|
| [0001-csharp-binding-path.md](0001-csharp-binding-path.md) | Windows consumes the Rust crates via a `uniffi-bindgen-cs` C# binding (vs a raw C-ABI header) | `VAL-P0-FFI-007` |
| [0002-rust-windows-msvc-targets.md](0002-rust-windows-msvc-targets.md) | `*-pc-windows-msvc` targets in the crate build config + the macOS cross-compile attempt result | `VAL-P0-RUST-005` |
| [0003-defer-project-code-static-parser-windows.md](0003-defer-project-code-static-parser-windows.md) | Defer `project-code-static-parser`'s Windows target past Phase 0 | `VAL-P0-RUST-005` |
| [0004-windows-storage-datastore-seam.md](0004-windows-storage-datastore-seam.md) | Windows opens the shared SQLCipher DB via C# `Microsoft.Data.Sqlite` + `bundle_e_sqlcipher` (the sanctioned raw-SQLCipher-C fallback) behind the DataStore seam; byte-compat proven across SQLCipher version + provider | `VAL-P0-DB-010` |
| [0005-windows-storage-architecture.md](0005-windows-storage-architecture.md) | The C# storage seam is the **permanent** Windows storage owner — the Swift Engine on Windows is compute-only ("Engine computes, shell persists"); the storage prune (`OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD`) is architecture, not a waived gap; retires R2 + the storage-prune waiver; file-format parity claimed (D6), API parity explicitly not | `VAL-P0-DB-010` / R2 |
| [0006-windows-daemon-strategy.md](0006-windows-daemon-strategy.md) | No monolithic `OpenBurnBarDaemon` port for v1 — per-capability Tier-C substitution (the WinUI app process + portable C# cores absorb daemon duties); 34-row disposition matrix; revive path = Linux boundary build hosted as a Windows Service | Remediation plan Wave 4 §3 / gap #10 |
| [0007-windows-app-backend.md](0007-windows-app-backend.md) | In-process Swift Engine (C-ABI/UniFFI) + net8.0 forwarding facades over the net10.0 storage/PAL stack; no Windows service for the data-wiring lanes (WS-B0 architecture decision) | `VAL-WS-B0-ARCH` |