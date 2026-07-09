# VAL-PATH-001

- id: VAL-PATH-001
- tier: A
- scope: product-parity
- status: ready
- validatedAt: 2026-07-09T18:07:00Z
- evidenceHead: 4a6274616b7b86f36d0af22f5464ba412cd7b834
- branch: windows/liquid-glass-kernel-reskin

## Proof

XDG path single ownership: linuxPaths.ts + OpenBurnBarLinuxPaths.swift + launch script + index DB path.

## Sealed pointer

- previousEvidencePath: `docs/linux-port/evidence/mission-002-reanchor/README.md`
- ledgerCommitAtReanchor: 4a6274616b7b86f36d0af22f5464ba412cd7b834

## Command

```
npm test --prefix apps/linux-desktop -- linuxPaths
```
