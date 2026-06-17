# Security Test Plan

## O.1 Existing Tests and Gates

| Test/gate | Coverage | Evidence |
|---|---|---|
| Endpoint authorization matrix tests | callable auth expectations, BOLA/high-risk guard coverage | `functions/src/security/endpointAuthorizationCatalog.generated.ts`, `functions/src/__tests__` |
| High-risk owner action guard test | static guard coverage for high-risk callables | `functions/src/__tests__/highRiskOwnerActionCallableGuards.test.ts` |
| Logging scrubber tests | token/email/IP/sensitive field redaction | `functions/src/__tests__/logging.test.ts`, `loggingScrubber.test.ts` |
| App Check attestation tests | nonce and high-risk proof logic | `functions/src/appCheckAttestation.ts` tests |
| Data export tests | sealed field sanitizer and fail-closed audit | `functions/src/callables/dataExport.ts` tests |
| Hosted MCP auth tests | bearer tokens, posture, revocation, scopes, rate limits | `services/hosted-mcp` tests |
| Daemon local-auth proof tests | missing/forged/wrong-intent/no-pinned-key/valid proof when wired | `BurnBarDaemonComputerUseLocalAuthProofWiringTests.swift` |
| Daemon peer code-signature tests | release/debug opt-out behavior | `BurnBarDaemonPeerCodesigPolicyTests.swift` |
| Firestore emulator tests | rules and object access | `.github/workflows/security-pr.yml` |
| CodeQL | static analysis | `.github/workflows/codeql.yml` |
| gitleaks | secret scanning | `.github/workflows/security-pr.yml:51-79` |
| dependency review/npm audit/OSV | dependency risk | `.github/workflows/security-pr.yml:81-147,221-240` |
| raw fetch guard | SSRF/resilience wrapper enforcement | `scripts/ci/verify-resilience-wiring.sh` |
| no suppression gate | prevents new unreasoned suppressions | `scripts/ci/check-no-suppressions.sh` |
| privacy invariants | plaintext/sealed domain regressions | `scripts/privacy/scan-chat-cloud-plaintext.mjs` |

## O.2 Missing Tests

| TEST ID | Threat | Recommended test type | Acceptance criteria | Priority | Suggested location |
|---|---|---|---|---|---|
| TEST-001 | THREAT-001 | unit/integration | production daemon config path has non-nil local-auth verifier and rejects missing proof | P0 | `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/` |
| TEST-002 | THREAT-002 | unit | daemon ComputerUseService denies when kill switch true or entitlement inactive | P1 | `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/` |
| TEST-003 | THREAT-003 | unit | `boundedHttpsURL` rejects `http://localhost.attacker.example` and all non-HTTPS non-loopback URLs | P1 | `functions/src/__tests__/validators.test.ts` |
| TEST-004 | THREAT-003 | callable unit | checkout and portal callables reject unsafe return URLs | P1 | `functions/src/__tests__/stripe*.test.ts` |
| TEST-005 | THREAT-004 | integration/policy | release verifier fails when Firestore App Check enforcement state is off or unknown | P1 | `scripts/ops/verify-firestore-app-check.*` |
| TEST-006 | THREAT-005 | unit/static | every public endpoint has signature, public rate limiter, or documented low-cost exemption | P1 | `functions/src/__tests__/publicEndpointRateLimit.test.ts` |
| TEST-007 | THREAT-006 | unit | deletion with audit write failure does not complete without durable intent | P1 | `functions/src/__tests__/dataDeletion*.test.ts` |
| TEST-008 | THREAT-007 | static workflow test | production deploy workflow cannot reference `FIREBASE_TOKEN` or service-account JSON fallback | P2 | `scripts/ci/verify-production-deploy-auth.sh` |
| TEST-009 | THREAT-009 | unit | injected Keychain persistence failure aborts SQLCipher setup | P2 | `AgentLensTests/` |
| TEST-010 | THREAT-008 | docs/claim lint | prohibited broad Signal/E2EE wording fails docs/product claim scan | P2 | `scripts/ci/verify-security-claims.sh` |
| TEST-011 | THREAT-012 | dynamic/log sampling | representative logs contain no tokens, raw prompts, cookies, signed URLs, or secret fields | P2 | ops runbook/manual plus automated pattern scan |
| TEST-012 | Agentic prompt injection | adversarial integration | malicious webpage/tool output cannot trigger high-impact action without approval | P1 | Computer Use adversarial suite |

## O.3 Safe Local Checks for This Run

Planned verification after writing the package:

- Parse `audit-state.json`, `findings.json`, and `security-score.json`.
- Parse `threat-register.csv`.
- Run `bash scripts/ci/verify-resilience-wiring.sh`.
- Run `bash scripts/ci/check-no-suppressions.sh`.
- Check git status in the clean worktree.

If a tool is unavailable, the final response will record that fact.

