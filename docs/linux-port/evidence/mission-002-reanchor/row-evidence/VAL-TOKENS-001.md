# VAL-TOKENS-001

- id: VAL-TOKENS-001
- evidenceHead: 9c5afb0e017d29b2e3512fd73ae23a911b92273f
- validatedAt: 2026-07-09T18:07:54Z
- branch: windows/liquid-glass-kernel-reskin

- tier: A
- scope: product-parity
- status: ready

## Proof

packages/design-tokens dependency; pensieve.css/skins; tokenFileContract tests.

## Sealed pointer

- previousEvidencePath: `docs/linux-port/evidence/mission-002-reanchor/README.md`
- ledgerCommitAtReanchor: 4a6274616b7b86f36d0af22f5464ba412cd7b834

## Command

```
npm test --prefix apps/linux-desktop -- tokensContract
```
