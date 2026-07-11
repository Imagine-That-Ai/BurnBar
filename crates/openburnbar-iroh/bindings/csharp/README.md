# openburnbar-iroh — C# / .NET binding (Windows port)

C# binding for the [`openburnbar-iroh`](../..) cdylib — the iroh QUIC transport
the Windows native shim (`windows/native/OpenBurnBar.Native.Iroh`) consumes.
Generated with the same pinned `uniffi-bindgen-cs` and the same
committed-generated-source + drift-check discipline as
[`crates/burnbar-remote/bindings/csharp/`](../../../burnbar-remote/bindings/csharp/);
the binding-path decision lives in
[`docs/windows-port/decisions/0001-csharp-binding-path.md`](../../../../docs/windows-port/decisions/0001-csharp-binding-path.md).

## Layout

| Path | What |
|---|---|
| `OpenBurnBarIroh.Ffi/generated/openburnbar_iroh.cs` | **Generated** binding (uniffi-bindgen-cs). Do not hand-edit. |
| `OpenBurnBarIroh.Ffi/OpenBurnBarIroh.Ffi.csproj` | Reusable binding class library (`net8.0`). |
| `regenerate.sh` | Rebuild the cdylib + regenerate `generated/openburnbar_iroh.cs`. |

Unlike the burnbar-remote binding there is no crate-side test project here: the
loopback proof lives with the shim it serves —
[`windows/tests/native/`](../../../../windows/tests/native/) round-trips
`openburnbar_iroh_protocol_version` / `openburnbar_alpn` /
`generate_secret_key_material` / `IrohEndpointHandle` against the natively
built cdylib on macOS, and skips (never fails) when the cdylib is absent.

## Regenerating the binding

Re-run [`regenerate.sh`](regenerate.sh) after changing the `#[uniffi::export]`
surface under `src/`, then commit the diff. The generator must match the
crate's uniffi version (0.28.x):

```bash
cargo install uniffi-bindgen-cs \
  --git https://github.com/NordSecurity/uniffi-bindgen-cs \
  --tag v0.9.2+v0.28.3
./regenerate.sh
```

Drift between the committed binding and the Rust export surface is caught by
[`scripts/windows-port/check-csharp-binding-drift.sh`](../../../../scripts/windows-port/check-csharp-binding-drift.sh)
(run in CI by `.github/workflows/csharp-binding-drift.yml`).
