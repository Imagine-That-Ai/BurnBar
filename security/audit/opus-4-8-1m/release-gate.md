# Release Gate — Opus 4.8 1M lane

**Question:** Is this branch safe to ship under the stated security claims?

**Judgment: SHIP WITH CONDITIONS.** The code-level security posture is strong and the two most dangerous prior findings (P0-6, LB-2) are fixed. No Critical/High code findings. Shipping is gated on (a) confirming operational state and (b) narrowing two public claims.

## Blocking conditions (must clear before public launch / security claims)
1. **OPUS-U-003** — confirm the alert channel reaches a human (an undeliverable alert plane is a launch blocker for any paid/at-scale service).
2. **OPUS-U-004 + OPUS-U-001** — confirm production functions are current and TTL policies are live (otherwise merged billing/privacy fixes are not actually protecting users).
3. **OPUS-U-002 + OPUS-U-005** — confirm App Check Firestore console enforcement and branch-protection ruleset.
4. **CLAIM-09 / CLAIM-10 / CLAIM-11 (OPUS-U-007)** — remove/narrow any public "local DB encrypted," "all data sealed/E2EE," or "Signal Protocol" wording that the local-DB-plaintext, shared-artifact-plaintext, and inert-libsignal realities contradict.

## Non-blocking (fix in the next cycle)
- OPUS-F-001 (seal collaboration artifacts or document), OPUS-F-002 (macOS scrubber test), OPUS-F-003/005/006/008, and the hardening set.

## Claim changes required at ship time
- Say "AES-256-GCM sealed under a device-held key" — not "Signal Protocol" / not "end-to-end encrypted" universally.
- Say "local database protected by macOS file permissions; at-rest encryption in progress" — not "encrypted at rest."
- Scope the sealing claim to chat/session/mission/snippet content; exclude shared artifacts.

## Monitoring / rollback
- Auto-rollback is wired (`deploy-production.yml:228-247`); ensure the alert channel (OPUS-U-003) actually pages so a failed rollback is noticed.

## Verdict summary
| | |
|---|---|
| Code-level Critical/High | 0 |
| Open Mediums | 2 (non-blocking with conditions) |
| Blocking conditions | 5 operational/claim confirmations (mostly minutes-to-hours) |
| Recommendation | **Ship with conditions** once the 5 confirmations + claim-narrowing are done |
