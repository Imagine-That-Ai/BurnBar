# `windows/native/` — native shim (W2)

The **native shim** — the managed↔Rust FFI bridge that surfaces the Rust crates
(`crates/openburnbar-iroh`, `crates/burnbar-remote`) to the managed WinUI shell. The
DB/crypto engine seam lives separately under [`../storage/`](../storage/) (C# SQLCipher, WPD-0005).

Binding decision: **committed, drift-gated uniffi-bindgen-cs C# bindings** —
[`docs/windows-port/decisions/0001-csharp-binding-path.md`](../../docs/windows-port/decisions/0001-csharp-binding-path.md).
One `#[uniffi::export]` surface drives Swift, Kotlin, **and C#**; nothing here is hand-marshaled.

## Layout

| Project | TFM | What |
|---|---|---|
| [`OpenBurnBar.Native/`](OpenBurnBar.Native/) | net8.0 | The shared **loader kernel**: `NativeLibraryLocator` (hardened absolute-path probe: `OPENBURNBAR_NATIVE_DIR` → app base dir → `runtimes/<rid>/native`; never CWD, never PATH — the managed face of the R19 posture in [`../dist/DLL_HARDENING.md`](../dist/DLL_HARDENING.md)), `NativeShimLoader` (`NativeLibrary.SetDllImportResolver` registration + availability probes), and `NativeShimUnavailableException` (the graceful NotSupported surface). |
| [`OpenBurnBar.Native.BurnBarRemote/`](OpenBurnBar.Native.BurnBarRemote/) | net8.0 | Shim over the gen-2 remote engine cdylib **`burnbar_remote`**. References the generated binding at [`crates/burnbar-remote/bindings/csharp/`](../../crates/burnbar-remote/bindings/csharp/); `BurnBarRemoteNative` fronts readiness/encode/decode/policy/controller with availability gating. |
| [`OpenBurnBar.Native.Iroh/`](OpenBurnBar.Native.Iroh/) | net8.0 | Shim over the iroh QUIC transport cdylib **`openburnbar_iroh`**. References the generated binding at [`crates/openburnbar-iroh/bindings/csharp/`](../../crates/openburnbar-iroh/bindings/csharp/); `IrohNative` fronts protocol constants/ALPNs/keygen/blob-tickets/endpoint creation with availability gating. |

Tests: [`../tests/native/`](../tests/native/) (`OpenBurnBar.Native.Tests`, 29 tests) — the hardened
locator, the NotSupported surface, and generated-binding API shape run on **any** host with no Rust
build; the **loopback** tests drive real FFI round-trips (golden-wire byte parity + in-order foreign
callbacks + typed errors + stateful controller; iroh constants/keygen/endpoint lifecycle) whenever a
cargo-built cdylib is present. Optional developer hosts skip the 13 loopback tests when the libraries
are absent. The full-suite and physical release-certification harnesses set
`OPENBURNBAR_REQUIRE_NATIVE_SHIMS=1`; those proofs fail unless both libraries are present and
loadable, and their TRX verifier permits only the two separately reviewed live/manual skips.

## Where the native libraries come from

This tree consumes cdylibs; it never builds Rust (per-tree ownership, master plan §6.3):

- **Windows CI artifacts** — [`build-iroh-windows.yml`](../../.github/workflows/build-iroh-windows.yml) /
  [`build-burnbar-remote-windows.yml`](../../.github/workflows/build-burnbar-remote-windows.yml)
  (owned by W-RUST / RUST-005) produce `openburnbar_iroh.dll` + `burnbar_remote.dll` for
  `x86_64-pc-windows-msvc` and `aarch64-pc-windows-msvc`.
- **Exact full-suite gate** — [`pr-windows-full.yml`](../../.github/workflows/pr-windows-full.yml)
  builds both cdylibs from their locked, pinned Rust toolchains on native x64 and ARM64 runners,
  atomically stages them beside the exact-commit domain core, executes all loopback tests, and rejects
  a missing, unloadable, wrong-architecture, or unexpectedly skipped shim.
- **macOS dev host** — `cargo build -p burnbar-remote-ffi` (in `crates/burnbar-remote`) and
  `cargo build` (in `crates/openburnbar-iroh`) produce the `.dylib`s; the test csproj copies them next
  to the test binary when present, or point `OPENBURNBAR_NATIVE_DIR` at any absolute directory
  containing them.

No compiled artifact is ever committed (no-tracked-binaries tripwire in
[`scripts/debt/check-windows-tree-budget.sh`](../../scripts/debt/check-windows-tree-budget.sh)).

## Keeping the bindings honest (drift gate)

The generated C# bindings are committed (like the Kotlin bindings) and pinned to
`uniffi-bindgen-cs v0.9.2+v0.28.3` (locks the crates' uniffi 0.28.3 ABI):

- Regenerate after changing an export surface: `crates/<crate>/bindings/csharp/regenerate.sh`.
- Drift gate: [`scripts/windows-port/check-csharp-binding-drift.sh`](../../scripts/windows-port/check-csharp-binding-drift.sh)
  rebuilds each cdylib, regenerates with the pinned generator, and diffs against the committed file —
  run in CI by [`csharp-binding-drift.yml`](../../.github/workflows/csharp-binding-drift.yml) on any
  `crates/**` change.

## Status

- **Implemented:** loader + both bindings + facades + 29-test suite + drift gate; real FFI loopback
  passes on macOS against cargo-built dylibs, while optional no-Rust hosts retain graceful skips.
- **FFI-008 gate:** the full x64 and ARM64 workflows now build, stage, require, load, and exercise the
  matching `*-pc-windows-msvc` libraries. FFI-008 is release-proven only when both exact-candidate
  hosted legs pass; authored workflow text alone is not accepted as proof.

Source files here are ratcheted by the per-tree budget under the `native` area.
