# Remediation Roadmap

## Must Fix Before Launch / External Audit

| ID | Title | Risk addressed | Severity | Component | Implementation sketch | Acceptance criteria | Tests required | Owner | Effort | Score impact | Dependency |
|---|---|---|---|---|---|---|---|---|---|---:|---|
| ROADMAP-001 | Wire daemon local-auth proof verifier in production | FINDING-001 | High | OpenBurnBarDaemon | instantiate `DaemonLocalAuthProofVerifier` in executable with persistent pin/replay stores | missing/stale/replayed/wrong-intent proof rejected in production config | TEST-001 | Daemon / Computer Use | medium | +8 to +12 | none |
| ROADMAP-002 | Fix Stripe return URL validation | FINDING-003 | Medium | Functions | exact loopback predicate, HTTPS-only non-loopback, optional origin allowlist | unsafe localhost-substring hosts rejected | TEST-003, TEST-004 | Functions / Billing | small | +3 to +4 | none |
| ROADMAP-003 | Add Firestore App Check deployment verifier | FINDING-004 | Medium | Cloud/Ops | script Firebase/GCP API check and gate ops readiness | release fails if enforcement off/unknown | TEST-005 | Cloud/Ops | medium | +4 to +5 | production credentials |
| ROADMAP-004 | Replace daemon synthetic Computer Use context | FINDING-002 | Medium | Computer Use | use live entitlement and Remote Config kill switch in daemon context | daemon denies inactive entitlement and kill switch | TEST-002 | Computer Use | medium | +4 to +5 | entitlement provider |
| ROADMAP-005 | Make deletion audit durable | FINDING-006 | Medium | Functions | required pre-delete audit intent, post-delete completion, retry/failure state | every successful deletion has durable intent | TEST-007 | Privacy / Functions | medium | +2 to +3 | audit log |

## Should Fix Soon

| ID | Title | Risk addressed | Severity | Component | Implementation sketch | Acceptance criteria | Tests | Owner | Effort | Score impact |
|---|---|---|---|---|---|---|---|---|---|---:|
| ROADMAP-006 | Public endpoint rate-limit inventory and enforcement | FINDING-005 | Medium | Functions/Ops | shared middleware or edge verifier for each public endpoint | every public endpoint has a bound | TEST-006 | Cloud/Ops | medium | +2 to +4 |
| ROADMAP-007 | WIF-only production deploy | FINDING-007 | Low | CI/CD | remove service-account JSON and Firebase token fallback | production deploy requires OIDC/WIF | TEST-008 | Platform | small | +2 to +3 |
| ROADMAP-008 | SQLCipher key persistence fail-closed | FINDING-008 | Low | macOS | throw on Keychain persistence failure before DB creation | no DB created with non-persisted key | TEST-009 | macOS data store | small | +1 to +2 |
| ROADMAP-009 | Claim lint for E2EE/Signal wording | FINDING-009 | Low | Docs/Product | scan docs/site/app copy for forbidden broad claims | unsafe wording blocked | TEST-010 | Product/Security | small | +1 to +2 |

## Hardening

- Add periodic log sampling proof for Sentry/Firebase hosted logs.
- Add adversarial prompt-injection and tool-output tests for Computer Use and hosted MCP.
- Document production IAM/access reviews for Firebase, Stripe, Sentry, GitHub.
- Attach SBOM/provenance links to every release.
- Add signed release artifact verification to install/update flows where applicable.

## Documentation / Decision Needed

- Decide whether data deletion should fail closed on audit failure or use required pre-delete intent plus best-effort completion.
- Decide exact public security claim wording for Cloud Vault, Signal envelopes, hosted MCP, and Computer Use approvals.
- Decide support/admin data access policy and audit requirements.
- Decide retention and deletion SLAs for backups, logs, Sentry events, and audit logs.

## Future Architecture

- WIF-only deploy with least-privilege service accounts and environment-specific Firebase projects.
- Central policy inventory for every public endpoint, MCP tool, daemon RPC method, and Computer Use action.
- Formal external review of Computer Use, daemon, hosted MCP, and Cloud Vault protocols.
- Continuous deployment-state attestation for App Check, branch protection, and production IAM.

## Fastest Path to +10 Points

1. ROADMAP-001: wire daemon local-auth proof in production.
2. ROADMAP-002: fix URL validation.
3. ROADMAP-003: add Firestore App Check deployment verifier.

These three are likely enough to remove the Major Claim Cap if implemented with tests.

## Path to 70

- Complete ROADMAP-001 through ROADMAP-003.
- Rerun audit and verify no new major claim cap applies.

## Path to 80

- Complete ROADMAP-001 through ROADMAP-007.
- Add missing tests and release proof for public endpoint rate limits.
- Document production access and incident response evidence.

## Path to 90

- Complete Path to 80.
- Add adversarial Computer Use/MCP testing, production log sampling proof, branch-protection verification, and external-auditor setup package.

## Path to 95+

- Complete Path to 90.
- Obtain independent external security review.
- Maintain stable score across at least two reruns.
- Fix or formally accept all Critical/High/Medium findings with regression guards.

