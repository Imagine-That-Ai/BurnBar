# VAL-SHELL-002

- id: VAL-SHELL-002
- evidenceHead: 9c5afb0e017d29b2e3512fd73ae23a911b92273f
- validatedAt: 2026-07-09T18:07:54Z
- branch: windows/liquid-glass-kernel-reskin

- tier: A
- scope: historical-infrastructure
- status: ready

## Proof

Historical infrastructure contract re-validated at reanchor head 4a6274616b7b86f36d0af22f5464ba412cd7b834. Sealed mission-001 pointer: `docs/linux-port/evidence/mission-001-shell-ux/shell-evidence-verify.json`.

## Sealed pointer

- previousEvidencePath: `docs/linux-port/evidence/mission-001-shell-ux/shell-evidence-verify.json`
- ledgerCommitAtReanchor: 4a6274616b7b86f36d0af22f5464ba412cd7b834

## Command

```
OB_SHELL_FORCE_DESKTOP_SESSION=1 node scripts/linux-port/run-shell-smoke.mjs
```
