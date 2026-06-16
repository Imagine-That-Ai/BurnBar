# Remediation Roadmap — Opus 4.8 1M lane

## Must fix before public security claims / external audit
| ID | Item | Effort | Score impact |
|---|---|---|---|
| OPUS-U-003 | Confirm + repair alert notification channel (NXDOMAIN risk) | S (minutes) | +ops |
| OPUS-U-001 | Confirm live Firestore TTL policies | S | +privacy/ops |
| OPUS-U-004 | Confirm prod functions are current | S | +ops |
| OPUS-U-002 | Confirm App Check Firestore console enforcement | S | +authz/ops |
| OPUS-U-005 | Confirm branch protection (required checks + reviews + enforce_admins) | S | +sdlc |
| OPUS-U-007 | Reconcile public claims with internal register (CLAIM-09/10/11) | S | +claims |
| OPUS-F-001 | Seal collaboration artifacts (or document the non-claim in UX) + key the hash | M | +crypto/claims |

## Should fix soon
| ID | Item | Effort |
|---|---|---|
| OPUS-F-002 | Add `MacSentryScrubberTests` (macOS crash-scrub regression) | S |
| OPUS-F-005 | Route `accountDeletion.ts` logs through `logWarn`/hash UID + add to gate | S |
| OPUS-F-006 | Gate `buildFcmMessage` in I5 or rotate the `thread_id` correlator | S |
| OPUS-F-003 | Migrate remaining sealed writers to path-bound AAD, then tighten rules | M |
| OPUS-F-008 | Add `validateServerPeer` to the legacy `/var/run` bridge write | S |

## Hardening (defense-in-depth)
| ID | Item | Effort |
|---|---|---|
| OPUS-F-007 | Harden `ssrfGuard.ts` (alt-encodings + DNS rebinding) before any user-URL fetch | S |
| OPUS-F-009 | Use absolute-path allowlist exclusively for privileged CLI resolution | S |
| OPUS-F-010 | Canonicalize paths in `RestrictedLogPathValidator` | S |
| OPUS-F-011 | Make Android coverage presence-path fail-closed outside CI | S |
| OPUS-F-012 | Add explicit CODEOWNERS rules for security trees | S |
| OPUS-F-013 | Gate quota features on server-reconciled allowance ledger | M |
| OPUS-F-014 | CI test for account-deletion root-collection completeness | S |
| OPUS-F-016 | Fail-closed/loud GPG checksum signing | S |
| — | Wire privileged-input red-team suite into a macOS nightly | M |
| — | Make session-log-backup rules test blocking in CI | S |

## Documentation / decision needed
- OPUS-F-017 refresh LLM/agentic threat-model doc to match code.
- M-008 / M-018 / M-030 / M-031 product decisions (see `open-questions.md`).
- OPUS-F-004 vendoring SQLCipher for at-rest DB encryption (or keep the disclosed non-claim).

## Fastest path to +10 points
1. Resolve OPUS-U-001..005 with operator evidence (lifts Cloud/Ops 48→~70 and removes operational uncertainty across Privacy/Authz/SDLC).
2. Close OPUS-F-001 + OPUS-F-002 (clears the two open Mediums).
3. Complete one stable DELTA re-run (lifts the run-1 confidence hold).

**Path to 80:** the above + OPUS-F-003/005/006 closed. **Path to 90:** + privileged-input red-team in CI, adversarial prompt-injection tests, operator-attested IR/monitoring evidence. **Path to 95+:** + independent external review and continuous security regression with all Mediums fixed/accepted.
