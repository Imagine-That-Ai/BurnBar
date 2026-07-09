# VAL-000-BASELINE

- id: VAL-000-BASELINE
- evidenceHead: 9c5afb0e017d29b2e3512fd73ae23a911b92273f
- validatedAt: 2026-07-09T18:07:54Z
- branch: windows/liquid-glass-kernel-reskin

- tier: A
- scope: product-parity
- status: ready

## Proof

Guest+host baseline: branch daemon live, 375 frontend tests historically green, mission-002 reanchor artifacts.

## Sealed pointer

- previousEvidencePath: `docs/linux-port/evidence/mission-002-reanchor/README.md`
- ledgerCommitAtReanchor: 4a6274616b7b86f36d0af22f5464ba412cd7b834

## Command

```
git rev-parse HEAD && npm test --prefix apps/linux-desktop && npm run build --prefix apps/linux-desktop
```
