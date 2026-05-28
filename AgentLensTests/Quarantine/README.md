# Quarantine (empty)

All previously quarantined Swift suites moved to **`AgentLensTests/Archive/`** on 2026-05-27 as part of the SOTA remediation program.

- **Archive:** migration reference only — not compiled by `OpenBurnBarTests`
- **Manifest:** [QUARANTINE_MANIFEST.md](QUARANTINE_MANIFEST.md) tracks revival status
- **Active:** `AgentLensTests/Active/` is the only compiled test surface

Do not add new `.swift` files here. Park broken suites under `Archive/` with a manifest entry instead.
