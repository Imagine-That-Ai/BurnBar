# Remediation Roadmap

## Must Fix Before Launch / External Audit

| ID | Title | Finding | Severity | Component | Implementation sketch | Tests | Effort | Expected score impact |
|---|---|---|---|---|---|---|---|---:|
| ROADMAP-001 | Wire daemon local-auth proof verifier in production | FINDING-001 | High | OpenBurnBarDaemon | instantiate verifier with persistent pin/replay stores | TEST-001 | medium | +8 to +12 |
| ROADMAP-002 | Fix Stripe return URL validation | FINDING-003 | Medium | Functions | exact loopback predicate, HTTPS-only non-loopback, optional allowlist | TEST-003, TEST-004 | small | +3 to +4 |
| ROADMAP-003 | Add Firestore App Check deployment verifier | FINDING-004 | Medium | Cloud/Ops | script Firebase/GCP API check and gate readiness | TEST-005 | medium | +4 to +5 |
| ROADMAP-004 | Replace daemon synthetic Computer Use context | FINDING-002 | Medium | Computer Use | use live entitlement and Remote Config kill switch | TEST-002 | medium | +4 to +5 |
| ROADMAP-005 | Make deletion audit durable | FINDING-006 | Medium | Functions | required pre-delete intent and post-delete completion | TEST-007 | medium | +2 to +3 |

## Should Fix Soon

| ID | Title | Finding | Effort | Score impact |
|---|---|---|---|---:|
| ROADMAP-006 | Public endpoint rate-limit inventory and enforcement | FINDING-005 | medium | +2 to +4 |
| ROADMAP-007 | WIF-only production deploy | FINDING-007 | small | +2 to +3 |
| ROADMAP-008 | SQLCipher key persistence fail-closed | FINDING-008 | small | +1 to +2 |
| ROADMAP-009 | Claim lint for E2EE/Signal wording | FINDING-009 | small | +1 to +2 |

## Fastest Path to +10 Points

1. ROADMAP-001: wire daemon local-auth proof in production.
2. ROADMAP-002: fix URL validation.
3. ROADMAP-003: add Firestore App Check deployment verifier.

## Path to 70

Complete ROADMAP-001 through ROADMAP-003 and rerun the audit. If evidence and tests pass, the Major Claim Cap can likely be removed.

## Path to 80

Complete ROADMAP-001 through ROADMAP-007, add public endpoint rate-limit proof, and document production access and incident response evidence.

## Path to 90

Complete Path to 80, add adversarial Computer Use/MCP testing, production log sampling proof, branch-protection verification, and an external-auditor setup package.

## Path to 95+

Complete Path to 90, obtain independent external security review, maintain stable score across at least two reruns, and fix or formally accept all Critical/High/Medium findings with regression guards.

