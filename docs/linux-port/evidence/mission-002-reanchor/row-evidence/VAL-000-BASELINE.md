# VAL-000-BASELINE

- id: VAL-000-BASELINE
- tier: A
- scope: product-parity
- status: ready
- validatedAt: 2026-07-09T18:07:00Z
- evidenceHead: 4a6274616b7b86f36d0af22f5464ba412cd7b834
- branch: windows/liquid-glass-kernel-reskin

## Proof

Guest+host baseline: branch daemon live, 375 frontend tests historically green, mission-002 reanchor artifacts.

## Sealed pointer

- previousEvidencePath: `docs/linux-port/evidence/mission-002-reanchor/README.md`
- ledgerCommitAtReanchor: 4a6274616b7b86f36d0af22f5464ba412cd7b834

## Command

```
git rev-parse HEAD && npm test --prefix apps/linux-desktop && npm run build --prefix apps/linux-desktop
```
