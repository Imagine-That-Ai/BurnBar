# OpenBurnBar Linux port

This directory tracks the Linux desktop peer release work. The Linux lane is
implemented as reviewable infrastructure, not a public availability claim.

Current active-checkout status as of 2026-07-05:

- V24 foundation and V23 surface validation passed from
  `/Users/albertonunez/Documents/Developer/BurnBar` at
  `1b62ec42bd752cc8a6af578f034bf776c6ec3b97`.
- The checkout later moved to `1af805eb1878cc5af8821ee35cac838c5ac473ee`;
  release closure must rerun the active-checkout validators at that head or
  restore the sealed head before claiming current release readiness.
- The current evidence pointer is
  [`evidence/mission-001-release/active-checkout-v23-v24-evidence.json`](evidence/mission-001-release/active-checkout-v23-v24-evidence.json).
- Public Linux release promotion is still blocked by release-package, update,
  signing/provenance, nightly-matrix artifact, and clean-release-commit evidence.

Primary files:

- [`release-runbook.md`](release-runbook.md) - package, update, signature,
  provenance, source-offer, and promotion process.
- [`parity-ledger.json`](parity-ledger.json) - machine-readable Tier A/B/C
  status ledger.
- [`parity-ledger.md`](parity-ledger.md) - human-readable ledger notes.
- [`factory-pr-handoff.md`](factory-pr-handoff.md) - review map and known
  blockers for the factory PR loop.
- [`ui-parity/`](ui-parity/README.md) - W6/W7 UI parity execution plan:
  foundation reference plus parallel task packets P01–P15.
- [`evidence/`](evidence/) - generated and collected mission evidence.

The release verifier refuses to publish `latest-linux.json` while the package
closure has missing artifacts, missing signatures, missing Sigstore provenance,
dirty commit state, missing package smoke logs, or blocked parity rows.

Computer Use input and panic:

- Linux daemon-owned `system` Computer Use sessions are enabled only on Linux.
  macOS daemon sessions remain browser-only because app-owned CGEvent/AX
  dispatch stays in AgentLens.
- Linux input dispatch uses approved native adapters: AT-SPI2 for Wayland
  accessibility actions when a session bus is available, and X11/XTEST via
  `xdotool` as a degraded X11 fallback. Missing adapter prerequisites fail
  closed instead of silently substituting a fixture or keylogger path.
- Panic halt is exposed through daemon RPC, the packaged shell's global
  emergency shortcut registration (`Ctrl+Alt+Super+.` with
  `Ctrl+Alt+Shift+.` fallback), the focused-window webview fallback for the
  same chords, and the bindable CLI command
  `openburnbar-cli computer-use panic-halt --session-id '*' --source hotkey`.
  The wildcard form halts every daemon-owned Computer Use session and trips the
  privileged-input kill flag before teardown. On Linux, the default flag lives
  at `$XDG_RUNTIME_DIR/openburnbar/privileged-input-kill` so it works under the
  packaged user service's `RuntimeDirectory=openburnbar` confinement; the
  `OPENBURNBAR_PRIVILEGED_INPUT_KILL_FLAG_PATH` override remains available for
  tests and deployment-specific wiring. Desktop environments that reject global
  shortcut registration remain evidence-gated; unavailable global hooks must be
  recorded as blocked rows for that DE.

Fast local checks:

```bash
node scripts/linux-port/validate-linux-release-config.mjs
node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked
node scripts/linux-port/check-linux-docs.mjs
```
