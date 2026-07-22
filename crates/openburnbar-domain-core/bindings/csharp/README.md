# C# bindings

`OpenBurnBarDomainCore.Ffi/generated/openburnbar_domain_ffi.cs` is generated
from the compiled UniFFI library. Do not edit it by hand.

Regenerate after changing an exported Rust type or function:

```bash
crates/openburnbar-domain-core/bindings/csharp/regenerate.sh
scripts/windows-port/check-csharp-binding-drift.sh domain-core
```

The generator pin is `uniffi-bindgen-cs 0.9.2+v0.28.3`, matching UniFFI
`0.28.3` in the crate workspace.
