# WPD-0002: `*-pc-windows-msvc` targets in the Rust crate build config

- **Status:** Accepted (Phase 0)
- **Date:** 2026-07-03
- **Contract:** `VAL-P0-RUST-005`
- **Scope:** Add the two Windows MSVC triples to the build config of
  `openburnbar-iroh`, the `burnbar-remote` workspace, and its `burnbar-remote-ffi`
  member; author their Windows crate-build workflows; attempt a macOS
  cross-compile.

## Targets

| Triple | Windows | CI status |
|---|---|---|
| `x86_64-pc-windows-msvc` | 10/11 on x64 | build **+ test** (native on `windows-latest`) |
| `aarch64-pc-windows-msvc` | 11 on ARM64 | **build-only** (cannot execute ARM64 on the x64 runner) |

## Decision — how the targets are "added to the build config"

Two coordinated, idiomatic locations, chosen to be **non-breaking** for the
shipping macOS/iOS/Android lanes:

1. **CI workflows (the primary build config)** — one per crate, mirroring the
   existing `build-*-android-aar.yml` (which is where the *Android* targets are
   declared — via the toolchain action's `targets:` field, not any Cargo file):
   - [`.github/workflows/build-iroh-windows.yml`](../../../.github/workflows/build-iroh-windows.yml)
   - [`.github/workflows/build-burnbar-remote-windows.yml`](../../../.github/workflows/build-burnbar-remote-windows.yml)

   Both run on `windows-latest`, install the toolchain with
   `targets: x86_64-pc-windows-msvc,aarch64-pc-windows-msvc`, build (and, for
   x64, test) every target, and — for `burnbar-remote` — build the
   `burnbar-remote-ffi` cdylib **by name** so a workspace-graph change can never
   silently drop the crate the C# shim consumes. This lane **owns** these two
   files; CI-002/W-SCAFFOLD only references them (factory shared-file discipline,
   master plan §6.3).

2. **Per-crate `.cargo/config.toml` (a declarative record + local convenience)**:
   - [`crates/openburnbar-iroh/.cargo/config.toml`](../../../crates/openburnbar-iroh/.cargo/config.toml)
   - [`crates/burnbar-remote/.cargo/config.toml`](../../../crates/burnbar-remote/.cargo/config.toml)
     (workspace root — applies to `burnbar-remote-ffi`, which has FFI-specific
     aliases naming it explicitly)

   Each names the supported Windows triples in a comment and adds cargo
   **aliases** (`cargo build-win-x64`, `build-win-arm64`, `test-win-x64`,
   `build-win-x64-ffi`, …).

### Why aliases, not `[build] target` or `rust-toolchain.toml`

- **`[build] target = [...]`** in `.cargo/config.toml` would *force* those targets
  onto every plain `cargo build`/`cargo test`, breaking the native macOS
  build/test the xcframework and host-side CI lanes depend on. Rejected.
- **`rust-toolchain.toml` `targets = [...]`** would make rustup auto-install the
  Windows std for *every* invocation in these crates — including the Apple and
  Android CI lanes and every contributor's local `cargo check` — coupling those
  lanes to a Windows download they never use. Rejected.
- **Cargo aliases** only *name* the targets; they never change what a bare
  `cargo build` does, so the shipping lanes are untouched, while
  `cargo build-win-x64` is a real, usable shortcut on a native Windows host. This
  is the smallest non-breaking way to record the targets per crate. Accepted.

## Decision — scope the Android-only `jni` dependency

`openburnbar-iroh` declared `jni = "0.22"` as an **unconditional** dependency, but
it is used **only** by `src/android_context.rs`, which is gated behind
`#[cfg(target_os = "android")]`. Adding non-Android targets made this dead weight
on Windows (and Apple). The dependency is now scoped:

```toml
[target.'cfg(target_os = "android")'.dependencies]
jni = "0.22"
```

The Android AAR build is unaffected (it targets `*-linux-android`, where the
section is active); the Windows and Apple builds no longer compile the JNI
bindings. Verified: a native macOS `cargo check -p openburnbar-iroh` still builds.

## macOS cross-compile attempt (`cargo build --target x86_64-pc-windows-msvc`)

Two attempts were run from this macOS (`aarch64-apple-darwin`) workspace after
`rustup target add x86_64-pc-windows-msvc aarch64-pc-windows-msvc` (the rust-std
for all four triples installed cleanly).

### 1. Bare cross-compile — precise, reproducible blocker (expected)

`cargo build -p burnbar-remote-ffi --target x86_64-pc-windows-msvc` compiles
**all Rust code** for the MSVC target — the crate and every dependency — and fails
**only at the final link step**:

```
error: linker `link.exe` not found
  = note: No such file or directory (os error 2)
note: the msvc targets depend on the msvc linker but `link.exe` was not found
```

This is the expected blocker: macOS has the Windows rust-std but not the MSVC
linker/CRT. Crucially, it proves the **source is Windows-target-clean** — nothing
in the crate fails to compile for `*-pc-windows-msvc`; only a native Windows
linker/CRT is missing. Reproducible on any macOS host without an MSVC toolchain.

### 2. cargo-xwin (clang + downloaded MSVC CRT) — **FFI cdylib cross-compiles**

`cargo-xwin` supplies the missing half: it downloads the MSVC CRT (~46s, once)
and links with `rust-lld`, no Visual Studio required. With it, the
`burnbar-remote-ffi` cdylib — the crate the C# shim consumes, and a pure-Rust
subtree (no `ring`/C build deps) — cross-compiles cleanly from macOS to **both**
Windows triples:

```
cargo xwin build -p burnbar-remote-ffi --target x86_64-pc-windows-msvc   # → burnbar_remote.dll  (PE32+ x86-64)
cargo xwin build -p burnbar-remote-ffi --target aarch64-pc-windows-msvc  # → burnbar_remote.dll  (PE32+ Aarch64)
```

Both outputs are verified real Windows PE binaries (`file` → `PE32+ executable
(DLL) … for MS Windows`; `MZ` header). So the FFI cdylib the Windows C# binding
depends on is not merely link-clean on native Windows CI — it is buildable from
this macOS workspace today.

Setup: `cargo install cargo-xwin` (v0.23.0); `rustup target add
x86_64-pc-windows-msvc aarch64-pc-windows-msvc`. cargo-xwin caches the CRT under
`~/.cache/cargo-xwin`.

**iroh (`ring`/C build deps) — precise blocker with a one-line remedy.**
`cargo xwin build --target x86_64-pc-windows-msvc` in `openburnbar-iroh` gets
much further than "source doesn't build": cargo-xwin's `clang-cl` shim
**compiles `ring`'s C sources** (`p256-nistz.c`, etc.) for the MSVC target — 30
`-W` warnings, zero errors — and then fails at a single missing host tool:

```
error occurred in cc-rs: failed to find tool "llvm-lib": No such file or directory
```

`ring`'s build script uses `llvm-lib` (the LLVM static-library archiver) to bundle
its compiled C objects; Apple's clang toolchain does not ship it. This is a
**host-tooling** gap, not a source-portability one — every Rust and C file in the
tree compiles for `*-pc-windows-msvc`. Remedy on macOS: `brew install llvm` (adds
`llvm-lib`/`llvm-dlltool`/`lld-link`) and re-run. On the native `windows-latest`
CI runner the archiver is present (the MSVC `lib.exe`/LLVM tools), so this does
not affect `VAL-P0-RUST-006`.

**Net:** the source of all three crates is Windows-target-clean (nothing fails to
*compile* for msvc). The FFI cdylib fully cross-compiles from macOS to both
triples today; iroh needs one extra host tool (`llvm-lib`) to cross-link locally,
and builds natively on Windows CI regardless.

## Consequences

- The shipping macOS/iOS/Android lanes build byte-for-byte as before (no forced
  targets; Apple/Android no longer compile `jni`).
- Green msvc **build + test in CI** is proven separately by `VAL-P0-RUST-006`
  once a Windows runner is enabled (billing is an open item); the lanes are
  authored so that is a one-toggle change.
- `project-code-static-parser` is intentionally excluded from this Phase-0 slice
  ([WPD-0003](0003-defer-project-code-static-parser-windows.md)).
