# VAL-RELEASE-001

- id: VAL-RELEASE-001
- tier: A
- scope: historical-infrastructure
- status: ready
- validatedAt: 2026-07-09T18:07:00Z
- evidenceHead: 4a6274616b7b86f36d0af22f5464ba412cd7b834
- branch: windows/liquid-glass-kernel-reskin

## Proof

Historical infrastructure contract re-validated at reanchor head 4a6274616b7b86f36d0af22f5464ba412cd7b834. Sealed mission-001 pointer: `docs/linux-port/evidence/mission-001-release/package-closure.json`.

## Sealed pointer

- previousEvidencePath: `docs/linux-port/evidence/mission-001-release/package-closure.json`
- ledgerCommitAtReanchor: 4a6274616b7b86f36d0af22f5464ba412cd7b834

## Command

```
node scripts/linux-port/build-linux-release.mjs && node scripts/linux-port/smoke-linux-packages.mjs
```
