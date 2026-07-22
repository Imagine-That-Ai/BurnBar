# VAL-CLOUD-001

- id: VAL-CLOUD-001
- evidenceHead: bf829967b657646c40285bc059eacd6863d04e26
- validatedAt: 2026-07-09T18:08:20Z
- branch: windows/liquid-glass-kernel-reskin

- tier: B
- scope: historical-infrastructure
- status: ready

## Proof

Historical infrastructure contract re-validated at reanchor head 4a6274616b7b86f36d0af22f5464ba412cd7b834. Sealed mission-001 pointer: `docs/linux-port/evidence/mission-001-linux-cloud-security/linux-security-evidence.json`.

## Sealed pointer

- previousEvidencePath: `docs/linux-port/evidence/mission-001-linux-cloud-security/linux-security-evidence.json`
- ledgerCommitAtReanchor: 4a6274616b7b86f36d0af22f5464ba412cd7b834

## Command

```
npm --prefix functions run build and focused cloud/security tests plus Linux security harness
```

- staleWhenHeadDiffers: false (sealed to ledger git.commit bf829967b657646c40285bc059eacd6863d04e26)
