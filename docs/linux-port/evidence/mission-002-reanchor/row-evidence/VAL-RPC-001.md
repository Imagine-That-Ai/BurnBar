# VAL-RPC-001

- id: VAL-RPC-001
- evidenceHead: bf829967b657646c40285bc059eacd6863d04e26
- validatedAt: 2026-07-09T18:08:20Z
- branch: windows/liquid-glass-kernel-reskin

- tier: A
- scope: product-parity
- status: ready

## Proof

bridgeRpcContract tests; no invented daemon methods; gateway chat path; CU pending params-optional.

## Sealed pointer

- previousEvidencePath: `docs/linux-port/evidence/mission-002-reanchor/README.md`
- ledgerCommitAtReanchor: 4a6274616b7b86f36d0af22f5464ba412cd7b834

## Command

```
npm test --prefix apps/linux-desktop -- bridgeRpcContract
```

- staleWhenHeadDiffers: false (sealed to ledger git.commit bf829967b657646c40285bc059eacd6863d04e26)
