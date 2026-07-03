# `windows/native/` — native shim (W2)

The **native shim** — the C-ABI / FFI bridge that surfaces the Rust crates
(`crates/openburnbar-iroh`, `crates/burnbar-remote`) and the DB/crypto engine (SQLCipher + FTS5,
swift-crypto substitute) to the managed WinUI shell. This is where the `cdylib` C-ABI headers and
their `.dll`/`.lib` consumers, plus any C#/C++ interop glue, live.

The Rust **crate-build** workflows that produce the `x86_64-pc-windows-msvc` /
`aarch64-pc-windows-msvc` artifacts (`build-iroh-windows.yml`, `build-burnbar-remote-windows.yml`)
are owned by **W-RUST / RUST-005** — this tree consumes their output; it does not build the crates.

**Status:** skeleton placeholder. Native shim projects land here and register into
[`../OpenBurnBar.sln`](../OpenBurnBar.sln).

Source files here (`.cpp` / `.h` / `.rs` / …) are ratcheted by the per-tree budget under the
`native` area.
