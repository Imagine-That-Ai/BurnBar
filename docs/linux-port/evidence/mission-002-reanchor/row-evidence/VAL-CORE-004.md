# VAL-CORE-004

- id: VAL-CORE-004
- evidenceHead: 9c5afb0e017d29b2e3512fd73ae23a911b92273f
- validatedAt: 2026-07-09T18:07:54Z
- branch: windows/liquid-glass-kernel-reskin

- tier: A
- scope: historical-infrastructure
- status: ready

## Proof

Historical infrastructure contract re-validated at reanchor head 4a6274616b7b86f36d0af22f5464ba412cd7b834. Sealed mission-001 pointer: `docs/linux-port/evidence/mission-001-release/active-checkout-v23-v24-evidence.json`.

## Sealed pointer

- previousEvidencePath: `docs/linux-port/evidence/mission-001-release/active-checkout-v23-v24-evidence.json`
- ledgerCommitAtReanchor: 4a6274616b7b86f36d0af22f5464ba412cd7b834

## Command

```
swift test --filter OpenBurnBarLinuxCoreFoundationTests --jobs 1
```
