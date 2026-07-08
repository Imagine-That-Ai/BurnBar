# WPD-0001: How Windows consumes the Rust crates — C# binding via uniffi-bindgen-cs

- **Status:** Accepted (Phase 0)
- **Date:** 2026-07-03
- **Contract:** `VAL-P0-FFI-007`
- **Scope:** How the Windows build calls into `crates/burnbar-remote` (and, later,
  `crates/openburnbar-iroh`). Windows-runtime execution is `VAL-P0-FFI-008`
  (PENDING).

## Context

The macOS and Android apps reach the Rust remote engine through **UniFFI 0.28**,
which emits **Swift and Kotlin only** — there is no first-party C# emitter (a
repo-wide search finds zero `dotnet`/`csharp` references). The Windows port needs
a third foreign binding, and the interface it must carry is not trivial: the
engine surface uses **async calls, foreign callbacks, and typed errors**
(the representative `encode_quality_decision` added in `burnbar-remote-ffi`
exercises all three at once).

Two candidate paths:

1. **`uniffi-bindgen-cs`** (NordSecurity) — a net-new, third-party C# emitter that
   plugs into UniFFI the same way the Swift/Kotlin emitters do: it reads the
   compiled cdylib's UniFFI metadata and generates a complete C# binding.
2. **Raw C-ABI header** — hand-write a P/Invoke shim against the `extern "C"`
   symbols the `cdylib` already exports (`ffi_burnbar_remote_rustbuffer_*`,
   `uniffi_burnbar_remote_fn_*`, the callback vtable init, the async
   foreign-future poll functions).

## Decision

**Use `uniffi-bindgen-cs`.** Generate the C# binding from the compiled
`burnbar-remote-ffi` cdylib (library mode), commit the generated source, and
regenerate it in CI with a parity check — exactly mirroring how the Swift and
Kotlin bindings are produced from the same `#[uniffi::export]` surface.

- Pinned generator: `uniffi-bindgen-cs v0.9.2+v0.28.3` (its `+v0.28.3` suffix
  locks it to the crate's UniFFI 0.28.3 ABI — a mismatch fails the generated
  runtime checksum on first call, so drift is caught, not shipped).
- Config: `crates/burnbar-remote/burnbar-remote-ffi/uniffi.toml`
  (`access_modifier = "public"` so the binding is a normal reusable library).
- Binding + round-trip test: `crates/burnbar-remote/bindings/csharp/`.

## Why not the raw C-ABI header

The raw header is viable only for trivial synchronous, no-callback functions. The
three features Windows actually needs make it the wrong tool:

- **Async** uses UniFFI's foreign-future ABI — a `RustFuture` handle plus a poll
  function the foreign side must drive with a continuation callback and a
  completion-status out-param. Hand-rolling this in C# is a large, fragile
  re-implementation of the generator's `PollFuture`/`TaskCompletionSource` plumbing.
- **Callbacks** use a per-interface vtable of function pointers with `RustBuffer`
  argument marshaling and a clone/free reference protocol. Hand-writing and
  hand-maintaining that per interface is error-prone.
- **Typed errors** cross the boundary as a `RustCallStatus` out-param carrying a
  serialized error `RustBuffer` that must be lifted into the right exception
  subclass.

UniFFI's internal ABI is explicitly **not stable across versions**, so a
hand-written shim would need re-auditing on every `uniffi` bump. The generator
tracks that ABI for us and version-locks to it.

## Consequences

- **New tool dependency**, pinned to the UniFFI version and installed the same
  way `cargo-ndk` is in the Android lanes:
  `cargo install uniffi-bindgen-cs --git … --tag v0.9.2+v0.28.3`.
- **Generated code is committed** (like the Kotlin bindings) and must be
  regenerated via `bindings/csharp/regenerate.sh` whenever the export surface
  changes; a CI parity check (the FFI-008 lane) guards drift.
- **Consistency:** one source of truth — the Rust `#[uniffi::export]` surface —
  drives Swift, Kotlin, and now C#. No third hand-maintained marshaling layer.
- **Bus factor:** `uniffi-bindgen-cs` is third-party. Mitigation: the generated
  file is fully committed and self-contained (no run-time dependency on the
  generator), the version is pinned, and the round-trip test fails loudly on any
  ABI mismatch.

## Evidence (proven on macOS — `VAL-P0-FFI-007`)

`dotnet test` (net10.0) round-trips a byte-identical committed golden wire vector
(`burnbar-remote-ffi/tests/golden/quality_decision_v1.wire`) through the C#
binding against the **natively-built macOS** `libburnbar_remote.dylib`:

```
Passed!  - Failed: 0, Passed: 5, Skipped: 0, Total: 5
```

The five tests exercise the async encode (with an in-order foreign callback),
decode of the golden, encode→decode identity, and both typed error paths
(`WireTruncated`, `WireVersionMismatch`). The identical Rust unit tests lock the
same golden on the encoder side. Only the msvc-runtime repeat of this round-trip
remains for `VAL-P0-FFI-008`.
