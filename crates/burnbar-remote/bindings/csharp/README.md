# burnbar-remote — C# / .NET binding (Windows port)

C# binding for the [`burnbar-remote-ffi`](../../burnbar-remote-ffi) cdylib, plus a
`dotnet test` project that round-trips a byte-identical wire vector against it.
This is the Phase-0 spike proof for the Windows engine-consumption path
(`VAL-P0-FFI-007`); the binding-path decision and rationale live in
[`docs/windows-port/decisions/0001-csharp-binding-path.md`](../../../../docs/windows-port/decisions/0001-csharp-binding-path.md).

## Layout

| Path | What |
|---|---|
| `BurnBarRemote.Ffi/generated/burnbar_remote.cs` | **Generated** binding (uniffi-bindgen-cs). Do not hand-edit. |
| `BurnBarRemote.Ffi/BurnBarRemote.Ffi.csproj` | Reusable binding class library (`net10.0`). |
| `BurnBarRemote.Ffi.Tests/WireRoundTripTests.cs` | The round-trip proof: async + callback + error against the native cdylib. |
| `BurnBarRemote.Ffi.Tests/NativeLibraryResolver.cs` | Loads the copied cdylib per-OS (`.dylib` / `.dll` / `.so`). |
| `regenerate.sh` | Rebuild the cdylib + regenerate `generated/burnbar_remote.cs`. |
| `BurnBarRemote.Ffi.slnx` | Solution wiring both projects. |

The golden wire vector is a single committed file shared with the Rust unit
tests: [`../../burnbar-remote-ffi/tests/golden/quality_decision_v1.wire`](../../burnbar-remote-ffi/tests/golden/quality_decision_v1.wire)
(the Rust test embeds it via `include_bytes!`; the test csproj copies it next to
the test binary).

## Run the round-trip (macOS today, Windows for FFI-008)

```bash
# 1. Build the native cdylib (debug) — the test csproj copies it next to the binary.
cargo build -p burnbar-remote-ffi                     # from crates/burnbar-remote

# 2. Run the round-trip.
export DOTNET_ROOT="$(brew --prefix dotnet)/libexec"  # if dotnet is not already on PATH
dotnet test BurnBarRemote.Ffi.slnx
```

Expected: `Passed! - Failed: 0, Passed: 5`. The five tests cover the async encode
(with an in-order foreign callback), decode of the golden, encode→decode
identity, and the two typed error paths (`WireTruncated`, `WireVersionMismatch`).

FFI-008 runs the **same** project on a `*-pc-windows-msvc` runtime; override the
native library location with `-p:BurnBarRemoteNativeDir=<dir>` so it copies
`burnbar_remote.dll` instead of the macOS `.dylib`.

## Regenerating the binding

Re-run [`regenerate.sh`](regenerate.sh) after changing the `#[uniffi::export]`
surface in `burnbar-remote-ffi/src/lib.rs`, then commit the diff. The generator
must match the crate's uniffi version (0.28.3):

```bash
cargo install uniffi-bindgen-cs \
  --git https://github.com/NordSecurity/uniffi-bindgen-cs \
  --tag v0.9.2+v0.28.3
./regenerate.sh
```
