# mission-001 shell UX (W06LinuxShellUx)

Lane: `apps/linux-desktop` Tauri shell + Vite UI.

## Commands (mission worktree, 2026-07-03 repair)

- `node scripts/linux-port/run-shell-evidence.mjs` → JSON artifacts + verifier (`json`)
- `OB_REUSE_EXISTING_DEB=1 node scripts/linux-port/run-shell-desktop-session.mjs` → packaged desktop evidence + verifier (`desktop`)
- `OB_REUSE_EXISTING_DEB=1 node scripts/linux-port/run-shell-smoke.mjs` → full targeted smoke + verifier (`full`)
- Report: `W06-shell-evidence-repair-report.md`
- Oracle: `daemon-session-oracle.json` (real daemon preferred; fixture only with `OB_ACCEPT_SHELL_DAEMON_FIXTURE=1`)
## Current packaged-surface artifacts

- `packaged-route-session-transcript.json` proves all 17 accepted routes in the installed `.deb` under Xvfb/XFCE.
- `screenshot-route-*.png` and `window-route-*-xwininfo.txt` are captured from the same installed app session.
- `daemon-session-oracle.json` records `mode: openburnbar-daemon-af-unix`; fixture mode is explicit and scope-limited.
- `runtime-perf-samples.jsonl` is emitted by the installed Tauri app through `OPENBURNBAR_EVIDENCE_OUT`.
- `perf-budget.json` is derived from the same desktop session report plus runtime samples and gates all required rows.
- `shell-evidence-verify.json` is the fail-closed verifier result for `json`, `desktop`, or `full`.

## Host/model artifacts

- `a11y-keyboard-transcript.json`
- `token-visual-diff.json`
- `failure-state-transcript.json`
- `onboarding-flow-transcript.json`
- `pet-tier-matrix.json`
- `text-expansion-safety-proof.json`

## Not yet proven on this host

- Tray/menu interaction on GNOME/KDE/wlroots
- Interactive Wayland portal consent
- Screen reader capture beyond the CI profile's AT-SPI/window-property snapshot
