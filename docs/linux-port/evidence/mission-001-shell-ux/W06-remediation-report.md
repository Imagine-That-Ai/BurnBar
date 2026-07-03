# W06 Linux shell UX remediation (pass 2)

Lane: `W06LinuxShellUx`  
Workspace: `/private/tmp/openburnbar-linux-mission-001`  
Agent: `LinuxShellUxRemediate`

## Summary

Second-pass remediation adds daemon fixture mode, full in-app snippet CRUD with consent gate, pet glTF/behavior graph surface, evidence artifact generation (a11y/keyboard, token diff, failure states, daemon route transcript), and non-placeholder perf samples derived from Vite build + dist bundle read on the host. Linux Tauri package/tray/DE proof remains blocked without GTK/WebKit/AppIndicator toolchain.

## Changed files

| Path | Change |
|------|--------|
| `apps/linux-desktop/src/main.ts` | Fixture health, dashboard data tables, snippet CRUD/consent UI, pet graph, onboarding skip fix, aurora `data-skin` |
| `apps/linux-desktop/src/daemonFixture.ts` | Fixture health + per-route transcript rows |
| `apps/linux-desktop/src/textExpansionConsent.ts` | Consent persistence |
| `apps/linux-desktop/src/petBehaviorGraph.ts` | glTF path + behavior nodes |
| `apps/linux-desktop/src/shellEvidenceModel.ts` | A11y, token diff, failure cases |
| `apps/linux-desktop/src/shellEvidence.harness.test.ts` | Writes evidence JSON when `OB_EVIDENCE_OUT` set |
| `apps/linux-desktop/src/textExpansionConsent.test.ts` | Consent unit test |
| `apps/linux-desktop/src/styles/app.css` | Aurora skin, snippet/pet/fixture styles |
| `scripts/linux-port/run-shell-evidence.mjs` | Evidence harness driver |
| `scripts/linux-port/run-shell-smoke.mjs` | Adds evidence + perf steps |
| `scripts/linux-port/run-perf-budget.mjs` | Real build/bundle measurements + Linux dep row |

## Commands (run after edits)

```bash
node scripts/linux-port/run-shell-smoke.mjs
```

## Per-contract status (partial first pass → pass 2)

| Contract area | Pass 1 | Pass 2 | Evidence |
|---------------|--------|--------|----------|
| Host npm test/build smoke | partial | **improved** | `smoke-transcript.txt` |
| Daemon-backed dashboard data | missing | **partial (fixture transcript)** | `daemon-route-transcript.json`, Support → enable fixture |
| Text expansion CRUD + consent | demo only | **improved** | UI in `text-expansion` route + store tests |
| A11y / keyboard transcript | missing | **improved** | `a11y-keyboard-transcript.json` |
| Token / theme visual diff | missing | **improved** | `token-visual-diff.json` |
| Failure-state transcript | missing | **improved** | `failure-state-transcript.json` |
| Pet glTF / behavior graph | static emoji | **improved** | Pet route + graph JSON in UI |
| Perf budgets | placeholder ms | **improved (host build/bundle)** | `perf-budget.json` `measurements` |
| Linux Tauri build / package | not run | **blocked** | `perf-budget.json` → `linuxTauriBuild` |
| Tray / GNOME/KDE / wlroots | not run | **blocked** | requires packaged Linux DE session |
| Screen reader capture | not run | **blocked** | DOM transcript only on this host |

**Not marked passed:** any contract requiring Linux desktop surface (Tauri binary, tray, live daemon socket on session, SR capture).

## Evidence artifacts

- `docs/linux-port/evidence/mission-001-shell-ux/smoke-transcript.txt`
- `docs/linux-port/evidence/mission-001-shell-ux/perf-budget.json`
- `docs/linux-port/evidence/mission-001-shell-ux/a11y-keyboard-transcript.json`
- `docs/linux-port/evidence/mission-001-shell-ux/token-visual-diff.json`
- `docs/linux-port/evidence/mission-001-shell-ux/failure-state-transcript.json`
- `docs/linux-port/evidence/mission-001-shell-ux/daemon-route-transcript.json`

## Linux Tauri dependency row (unprovisioned on darwin host)

- `libgtk-3-dev`
- `libwebkit2gtk-4.1-dev`
- `libayatana-appindicator3-dev`
- `librsvg2-dev`
- `patchelf`
- Rust stable + `tauri-cli` inside Linux container (no mission-local Dockerfile present)