# Release Gate

Question: Is this release safe enough to ship under the stated security claims?

Judgment: **Ship with conditions for internal/beta use; do not ship under broad public security claims or into external security audit until blockers are fixed.**

## Blocking Issues for Public Security Claims or External Audit

| Finding | Reason |
|---|---|
| FINDING-001 | High-impact daemon Computer Use proof exists but is not wired in production. |
| FINDING-002 | Daemon browser Computer Use does not consume live kill-switch or entitlement state. |
| FINDING-003 | Billing redirect validation contradicts HTTPS-only redirect wording. |
| FINDING-004 | Firestore App Check production enforcement is not repo-verifiable. |
| FINDING-006 | Irreversible deletion lacks durable audit guarantee. |

## Non-Blocking Issues

| Finding | Reason |
|---|---|
| FINDING-005 | Public endpoint rate limiting can be edge-controlled, but proof is required before strong availability claims. |
| FINDING-007 | Deploy fallback secrets are a release integrity hardening gap; not an immediate product exploit from code alone. |
| FINDING-008 | SQLCipher Keychain persistence issue is mainly availability/recovery risk. |
| FINDING-009 | Claim wording can be fixed quickly but must be controlled before public claims. |

## Tests Required Before External Audit

- TEST-001 through TEST-007 from `security-test-plan.md`.
- Workflow policy test for WIF-only production deploy.
- Deployment-state verifier for Firestore App Check.
- Public endpoint rate-limit inventory gate.

## Monitoring Required

- Alert on Computer Use action without local-auth proof once proof is wired.
- Alert on Firestore App Check enforcement drift.
- Alert on public endpoint cost/rate anomalies.
- Alert on deletion without matching audit intent/completion.
- Alert on production deploy outside expected GitHub environment path.

