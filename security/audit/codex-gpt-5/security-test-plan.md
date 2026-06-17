# Security Test Plan

## Existing Tests and Gates

| Test/gate | Coverage |
|---|---|
| Endpoint authorization matrix tests | callable auth expectations and BOLA/high-risk guard coverage |
| High-risk owner action guard tests | static guard coverage for high-risk callables |
| Logging scrubber tests | token/email/IP/sensitive field redaction |
| App Check attestation tests | nonce and high-risk proof logic |
| Data export tests | sealed field sanitizer and fail-closed audit |
| Hosted MCP tests | bearer tokens, posture, revocation, scopes, rate limits |
| Daemon local-auth proof tests | missing/forged/wrong-intent/no-pinned-key/valid proof when wired |
| Firestore emulator tests | rules and object access |
| CodeQL | static analysis |
| gitleaks | secret scanning |
| dependency review/npm audit/OSV | dependency risk |
| raw fetch guard | SSRF/resilience wrapper enforcement |
| no-suppression gate | prevents unreasoned suppressions |
| privacy invariants | plaintext/sealed domain regressions |

## Missing Tests

| TEST ID | Threat | Type | Acceptance criteria | Priority |
|---|---|---|---|---|
| TEST-001 | THREAT-001 | unit/integration | production daemon config has non-nil verifier and rejects missing proof | P0 |
| TEST-002 | THREAT-002 | unit | daemon ComputerUseService denies kill switch true or inactive entitlement | P1 |
| TEST-003 | THREAT-003 | unit | `boundedHttpsURL` rejects localhost-substring and non-HTTPS non-loopback URLs | P1 |
| TEST-004 | THREAT-003 | callable unit | checkout and portal reject unsafe return URLs | P1 |
| TEST-005 | THREAT-004 | integration/policy | release verifier fails when Firestore App Check state is off or unknown | P1 |
| TEST-006 | THREAT-005 | unit/static | every public endpoint has signature, rate limiter, or low-cost exemption | P1 |
| TEST-007 | THREAT-006 | unit | deletion with audit failure does not complete without durable intent | P1 |
| TEST-008 | THREAT-007 | static workflow | production deploy cannot reference fallback long-lived deploy secrets | P2 |
| TEST-009 | THREAT-009 | unit | injected Keychain persistence failure aborts SQLCipher setup | P2 |
| TEST-010 | THREAT-008 | docs/claim lint | broad Signal/E2EE wording fails scan | P2 |
| TEST-011 | THREAT-012 | dynamic/log sampling | representative logs contain no tokens, raw prompts, cookies, signed URLs, or secret fields | P2 |
| TEST-012 | agentic prompt injection | adversarial integration | malicious webpage/tool output cannot trigger high-impact action without approval | P1 |

## Safe Local Checks

For this run, verify:

- JSON parses: `audit-state.json`, `findings.json`, `security-score.json`.
- CSV parses: `threat-register.csv`.
- `bash scripts/ci/verify-resilience-wiring.sh`.
- `bash scripts/ci/check-no-suppressions.sh`.

