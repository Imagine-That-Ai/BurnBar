# W06 shell evidence repair

Lane: `W06ShellEvidenceRepair`  
Mission worktree: `/private/tmp/openburnbar-linux-mission-001`  
Date: 2026-07-03

## Summary

Repaired the shell evidence harness so reruns are anchored to the mission worktree, required JSON/desktop artifacts are fail-closed, transcripts reject the user main checkout path, and packaged desktop sessions prefer a **real** `OpenBurnBarDaemon` AF_UNIX socket from the worktree build with an explicit oracle artifact. The packaged `.deb` session now drives all accepted routes in the installed Tauri app, captures per-route screenshots/window state, records runtime perf samples from the app, and leaves host Vitest artifacts labeled as DOM/policy support evidence.

## Commands (targeted rerun)

| Command | Exit | Notes |
|---------|------|-------|
| `node scripts/linux-port/run-shell-evidence.mjs` | 0 | Regenerates 10 JSON artifacts + `shell-evidence-harness-transcript.txt`; runs `verify-shell-evidence.mjs json` |
| `node scripts/linux-port/run-shell-desktop-session.mjs` | 0 | Fresh `.deb` build/install/run/tray/route/quit/uninstall in toolchain container |
| `node scripts/linux-port/run-perf-budget.mjs` | 0 | Gates all required rows from the packaged session report + `runtime-perf-samples.jsonl` |
| `OB_REUSE_EXISTING_DEB=1 node scripts/linux-port/run-shell-smoke.mjs` | 0 | Full targeted smoke with preserved `.deb` + `verify-shell-evidence.mjs full` |

## Daemon oracle (no silent fake daemon)

- **Primary path:** `scripts/linux-port/start-shell-session-daemon.sh` launches `/workspace/OpenBurnBarDaemon/.build-linux-ipc-cli-gateway/.../OpenBurnBarDaemon` inside the desktop session container.
- **Artifact:** `daemon-session-oracle.json` with `mode: openburnbar-daemon-af-unix`, `status: ready`, and `validatorGuidance` for V05.
- **Fallback (explicit only):** set `OB_ACCEPT_SHELL_DAEMON_FIXTURE=1` to allow `mode: accepted-fixture-af-unix` (does **not** satisfy live daemon contracts).
- **Log proof:** `daemon-shell-session.log` shows real `daemon.health` RPC handling (not Node fake socket).

## Verifier behavior

`scripts/linux-port/verify-shell-evidence.mjs`:

- Fails if transcripts contain `/Users/albertonunez/Documents/Developer/BurnBar`
- Fails if required JSON or desktop-session artifacts are missing/empty
- Fails if `daemon-session-oracle.json` is `blocked` or fixture mode is used without `OB_ACCEPT_SHELL_DAEMON_FIXTURE=1`
- Fails if packaged route transcript/screenshots are missing, if `daemon-route-transcript.json` remains fixture-mode after a desktop run, or if runtime perf samples are absent
- Fails if `perf-budget.json` omits required rows, uses the old synthetic sources, or is not tied to a desktop session report
- Writes `shell-evidence-verify.json` with errors or `status: ok`

## Evidence paths (mission worktree)

Directory: `docs/linux-port/evidence/mission-001-shell-ux/`

Key artifacts:

- `shell-evidence-run-manifest.json`, `shell-evidence-verify.json`
- `shell-evidence-harness-transcript.txt`, `smoke-transcript.txt` (fresh runs use mission paths)
- `linux-desktop-session-wrapper-transcript.txt`, `linux-deb-install-run-transcript.txt`
- `daemon-session-oracle.json`, `daemon-shell-session.log`
- `linux-desktop-session-report.json`, tray/screenshot/a11y files from packaged session
- `packaged-route-session-transcript.json`, `screenshot-route-*.png`, `window-route-*-xwininfo.txt`
- `runtime-perf-samples.jsonl`, `perf-budget.json`
- JSON transcripts: `route-snapshot-plan.json`, `route-a11y-user-flow-transcript.json`, `onboarding-flow-transcript.json`, `pet-tier-matrix.json`, `text-expansion-safety-proof.json`, etc.

## Real surface vs host/fixture labeling

| Area | Proof class | Artifact / note |
|------|-------------|-----------------|
| Packaged install/tray/quit/uninstall | **Real** (Xvfb/XFCE/AppIndicator CI profile) | `linux-desktop-session-report.json`, screenshots, tray DBus files |
| Daemon IPC in packaged session | **Real** OpenBurnBarDaemon AF_UNIX | `daemon-session-oracle.json`, `daemon-shell-session.log` |
| Route navigation/screenshots | **Real** installed app session | `packaged-route-session-transcript.json`, 17 `screenshot-route-*.png` files |
| Perf budget rows | **Real packaged session + app-emitted samples** | `perf-budget.json`, `runtime-perf-samples.jsonl`, `linux-desktop-session-report.json` |
| Onboarding/pet/text-expansion policy transcripts | **Host Vitest DOM/policy support** | `surface` / `method` fields plus packaged route screenshots |
| Dashboard daemon rows in Vitest | **Superseded by packaged route transcript** | `daemon-route-transcript.json` is overwritten by desktop route proof |
| GNOME/KDE/Wayland live DE | **Blocked** on this host | Requires matching interactive DE; not claimed here |
| Screen reader capture | **Partial** | CI profile records AT-SPI/window-property snapshot; full screen-reader session still needs matching DE |

## Remaining blockers

- Interactive GNOME/KDE/Wayland portal consent and screen-reader capture are out of scope for the Xvfb CI profile.
- `OB_REUSE_EXISTING_DEB=1` skips in-container Tauri rebuild when reusing `OpenBurnBar_0.1.0_arm64.deb` (faster evidence repair; full rebuild remains available without that flag).

## Changed files

- `apps/linux-desktop/src/shellEvidenceArtifacts.ts`
- `apps/linux-desktop/src/shellEvidence.harness.test.ts`
- `apps/linux-desktop/src/main.ts`
- `apps/linux-desktop/src/perfMarks.ts`
- `apps/linux-desktop/src-tauri/src/lib.rs`
- `apps/linux-desktop/src-tauri/icons/icon.png`
- `budgets/linux-desktop.perf.json`
- `scripts/linux-port/shell-evidence-manifest.mjs`
- `scripts/linux-port/verify-shell-evidence.mjs`
- `scripts/linux-port/start-shell-session-daemon.sh`
- `scripts/linux-port/linux-desktop-session.sh`
- `scripts/linux-port/run-shell-evidence.mjs`
- `scripts/linux-port/run-shell-smoke.mjs`
- `scripts/linux-port/run-shell-desktop-session.mjs`
- `scripts/linux-port/run-perf-budget.mjs`
- `docs/linux-port/evidence/mission-001-shell-ux/W06-shell-evidence-repair-report.md`
