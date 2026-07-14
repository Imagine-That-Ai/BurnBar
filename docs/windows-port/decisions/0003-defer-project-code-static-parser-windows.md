# WPD-0003: Defer `project-code-static-parser`'s Windows target past Phase 0

- **Status:** Accepted (Phase 0)
- **Date:** 2026-07-03
- **Contract:** `VAL-P0-RUST-005`
- **Decision owner:** Rust→Windows lane (0-c)

## Context

`crates/` holds three Rust crates:

| Crate | Role | On the G0 critical path? |
|---|---|---|
| `openburnbar-iroh` | QUIC/iroh transport (Hermes + Mercury) | **Yes** — transport is foundational. |
| `burnbar-remote` | Gen-2 remote-control engine + the `burnbar-remote-ffi` cdylib the Windows C# shim consumes | **Yes** — the FFI cdylib is the Windows engine-consumption path (`VAL-P0-FFI-007/008`). |
| `project-code-static-parser` | Stateless local Tree-sitter helper for Project Code Memory | **No.** |

`VAL-P0-RUST-005` adds the `x86_64-pc-windows-msvc` and `aarch64-pc-windows-msvc`
targets to the first two crates and authors their Windows crate-build workflows.
The question is whether `project-code-static-parser` must join them in Phase 0.

## Decision

**Defer `project-code-static-parser`'s Windows target past Phase 0.** It is
explicitly **not** dropped from the Windows port — it is scheduled for a later
phase (engine parity / W4), not the Phase-0 de-risk slice.

No `-pc-windows-msvc` build config or Windows workflow is authored for it in this
lane. When it is picked up, the same pattern applies (a `.cargo/config.toml`
target record plus a `build-project-code-static-parser-windows.yml` mirroring the
two authored here).

## Rationale

- **Not a G0 kill-risk.** Phase 0 exists to retire the two kill-risks — **R2**
  (SQLCipher/DB byte-compat) and **R14** (App Check TPM backend) — and to bind the
  Option A/B engine decision. The parser touches neither. Spending Phase-0 CI and
  review budget on it would not move the G0 go/no-go.
- **Architecturally isolated + low risk.** Per
  [`docs/ARCHITECTURE/010-project-code-static-parser.md`](../../ARCHITECTURE/010-project-code-static-parser.md)
  it is a stateless stdin/stdout executable with **no** database, network, auth,
  or write path — a pure `bin`, not a `cdylib`/`staticlib` consumed over FFI. It
  has no foreign-binding surface to port and no shared-artifact byte-compat
  obligation, so porting it is a self-contained, deferrable unit of work.
- **Not on the walking-skeleton path.** Phase 1's end-to-end skeleton
  (one provider → parse → interactive auth → one live dashboard tile) does not
  require static Tree-sitter symbol extraction. Project Code Memory's Windows
  parity is later-phase work.
- **Scope honesty.** Deferral is named with a re-entry criterion (picked up with
  engine/W4 parity work), not relabeled out-of-scope. The full Windows inventory
  still includes it.

## Consequences

- Phase-0 Windows Rust CI covers `openburnbar-iroh` and the `burnbar-remote`
  workspace (incl. `burnbar-remote-ffi`) only.
- Project Code Memory static parsing on Windows falls back to `lexical_fallback`
  (the documented degrade path) until the parser's Windows target is delivered —
  no correctness regression, only a tier reduction, and only on Windows, only
  until picked up.
- A follow-up task carries the parser's Windows target + workflow, gated to the
  phase that delivers Project Code Memory parity.

## Revival Addendum - 2026-07-13

The deferred implementation has now been picked up as an F2 parser slice. The
Rust helper remains a stateless stdin/stdout executable, but it now has a
Windows-targeted CI lane at
`.github/workflows/build-project-code-static-parser-windows.yml` that formats,
tests, and smoke-tests the native x64 MSVC binary, then builds the ARM64 MSVC
binary. The release workflow already consumes the same RID-specific parser
binary and requires it before publish.

The parser covers every code extension currently enumerated by the Windows
project inventory: C#, Java, Kotlin, Go, JavaScript/JSX, Rust, Swift, Python,
TypeScript, and TSX. It preserves Git-blob integrity evidence, extracts
bounded Tree-sitter symbols, and exposes optional bounded LSP references through
the Windows `code.references` operation. Java/Kotlin/Go are now parsed by
dedicated grammars rather than silently falling back to lexical declarations.

Local Rust tests and the presentation suite are green. Windows workflow
[29299426836](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29299426836)
passed native x64 MSVC tests/smoke and the ARM64 MSVC build. The revival is
therefore complete for implementation and hosted architecture evidence;
physical performance remains a separate release-certification gate.
