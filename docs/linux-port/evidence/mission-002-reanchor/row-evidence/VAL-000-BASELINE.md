# VAL-000-BASELINE

- id: VAL-000-BASELINE
- evidenceHead: bf829967b657646c40285bc059eacd6863d04e26
- validatedAt: 2026-07-09T18:08:20Z
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

- staleWhenHeadDiffers: false (sealed to ledger git.commit bf829967b657646c40285bc059eacd6863d04e26)
