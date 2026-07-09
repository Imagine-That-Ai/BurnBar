# VAL-000-LEDGER

- id: VAL-000-LEDGER
- tier: A
- scope: product-parity
- status: ready
- validatedAt: 2026-07-09T18:07:00Z
- evidenceHead: 4a6274616b7b86f36d0af22f5464ba412cd7b834
- branch: windows/liquid-glass-kernel-reskin

## Proof

This reanchor sets productParityClaim=true with per-row evidence heads matching checkout.

## Sealed pointer

- previousEvidencePath: `docs/linux-port/parity-ledger.json`
- ledgerCommitAtReanchor: 4a6274616b7b86f36d0af22f5464ba412cd7b834

## Command

```
node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked
```
