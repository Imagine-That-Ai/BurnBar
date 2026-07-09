# H2 host validation evidence (pre-VM scaffolding)

**Status:** Output directories prepared before Win11 VM access (master plan §18.4 / H2).  
**Runner:** `pwsh scripts/windows-port/vm-validate.ps1 -RepoRoot <checkout>`  
**Rule:** Do not promote host-gated ledger rows to `Real` without files committed here (or linked from the certification bundle) that name the proof that passed.

## Expected layout

| Subdir | H2 proof | Typical artifacts |
|--------|----------|-------------------|
| `build/` | Full `dotnet build` / `dotnet test` on Win11 | `build-summary.txt`, test TRX/logs |
| `xaml/` | XamlCompiler / MakePri for WinUI pages | `xamlcompiler.log`, page inventory |
| `appcheck/` | R14-A vTPM `NCryptCreateClaim` + token exchange | mint transcript, Admin clear proof |
| `oauth/` | Desktop OAuth loopback with production client | redacted token-exchange log |
| `conpty/` | Interactive ConPTY CLI stream | session recording notes, exit codes |
| `cloudvault/` | Live Windows-seal → Mac-open E2EE | C5 round-trip receipt |
| `ffi/` | Rust/MSVC native FFI loopback | cargo/msvc build logs |
| `particles/` | Win2D/ARM64 frame timing | fps measurement notes |
| `computer-use/` | SendInput / UIA / WGC / kill-switch smoke | adapter smoke checklist |

## Capture conventions

1. Prefer text/JSON logs over binary blobs.
2. Redact secrets; never commit OAuth client secrets or live tokens.
3. Each proof file should include: date, host arch, git SHA, command invoked, pass/fail.
4. When a proof fails, leave the row `Blocked` with the failing artifact path in ledger notes.

## Related

- Master plan: `docs/windows-port/WINDOWS_FULL_PARITY_MASTER_PLAN_2026-07-09.md` §6
- VM script: `scripts/windows-port/vm-validate.ps1`
- Human gates: `docs/windows-port/TONIGHT_PUNCHLIST.md`, `ALBERTO_PARITY_CHECKLIST.md`
