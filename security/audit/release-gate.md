# Release Gate

Question: Is this release safe enough to ship under the stated security claims?

Judgment: **Ship with conditions for internal/beta use; do not ship under broad public security claims or into external security audit until blockers are fixed.**

## Blocking Issues for Public Security Claims or External Audit

| Finding | Reason |
|---|---|
| FINDING-001 | High-impact daemon Computer Use proof exists but is not wired in production. |
| FINDING-002 | Daemon browser Computer Use does not consume live kill-switch or entitlement state. |
| FINDING-003 | Billing redirect validation bug is small to fix and directly contradicts HTTPS-only redirect wording. |
| FINDING-004 | Firestore App Check production enforcement is not repo-verifiable. |
| FINDING-006 | Irreversible deletion lacks durable audit guarantee. |

## Non-Blocking Issues

| Finding | Reason |
|---|---|
| FINDING-005 | Public endpoint rate limiting can be handled through edge controls, but proof is required before strong availability claims. |
| FINDING-007 | Deploy fallback secrets are a release integrity hardening gap; not an immediate product exploit from code alone. |
| FINDING-008 | SQLCipher Keychain persistence issue is mainly availability/recovery risk. |
| FINDING-009 | Claim wording can be fixed quickly but must be controlled before public claims. |

## Claim Changes Required

Safe today:

- Protected callable APIs generally require Firebase Auth and App Check, with explicit public/webhook/platform exceptions.
- Firestore rules are owner-scoped and server-only for sensitive secret collections.
- Hosted MCP uses scoped short-lived tokens, client/entitlement/rate checks, and local decryption for sealed bodies.
- Cloud Vault sealed fields use AES-GCM with context-bound AAD.
- Stripe webhooks are signature verified and idempotency protected.
- Data export requires high-risk owner proof and fail-closed audit append.

Avoid today:

- All Computer Use daemon actions require independent local-auth proof.
- All Computer Use daemon actions are live kill-switch and entitlement gated.
- Firestore App Check production enforcement is proven by repository state.
- All sensitive user data has Signal-quality E2EE.
- Billing redirects are HTTPS-only.
- Production deploy is WIF-only.

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

## Rollback Considerations

- Keep Computer Use kill switch operational and verified before launch.
- Production deploy workflow already has health gate and rollback steps; remove secret fallback before relying on it for public claims.
- If URL validation fix breaks local development redirects, keep loopback exceptions exact and environment-scoped.

