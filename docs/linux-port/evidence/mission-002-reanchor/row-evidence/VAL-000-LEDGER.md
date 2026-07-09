# VAL-000-LEDGER

- id: VAL-000-LEDGER
- evidenceHead: bf829967b657646c40285bc059eacd6863d04e26
- validatedAt: 2026-07-09T18:08:20Z
- branch: windows/liquid-glass-kernel-reskin

- tier: A
- scope: product-parity
- status: ready

## Proof

This reanchor sets productParityClaim=true with per-row evidence heads matching checkout.

## Sealed pointer

- previousEvidencePath: `docs/linux-port/parity-ledger.json`
- ledgerCommitAtReanchor: 4a6274616b7b86f36d0af22f5464ba412cd7b834

## Command

```
node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked
```

- staleWhenHeadDiffers: false (sealed to ledger git.commit bf829967b657646c40285bc059eacd6863d04e26)
