# Security Score

Run mode: FULL_BASELINE

Commit: `0e0b063b27e39ad8cd1210ee829c2c7de28db620`

## Score Table

| Category | Weight | Score | Weighted Contribution | Confidence | Main Reason |
|---|---:|---:|---:|---|---|
| Architecture and Threat Model | 10% | 82 | 8.2 | high | Strong component inventory and existing threat-model docs; this package adds stateful registers. |
| Security Claims and Evidence | 10% | 63 | 6.3 | medium | Several claims are evidence-backed, but Computer Use and Signal/E2EE wording must be narrowed. |
| Authentication, Authorization, and Identity | 12% | 80 | 9.6 | high | Generated endpoint matrix, owner checks, App Check, high-risk nonces, passkeys, and Firestore rules are strong. |
| Cryptography, Secrets, and Protocols | 10% | 74 | 7.4 | medium | AES-GCM AAD, Keychain, Ed25519 MCP tokens, and webhook HMAC exist; daemon proof and Signal claim gaps remain. |
| Application/API/Data Validation | 10% | 76 | 7.6 | medium | Shared validators and storage bounds exist; Stripe URL helper and public endpoint rate limits need fixes. |
| Cloud, Infrastructure, and Operations | 8% | 68 | 5.4 | medium | Functions config fails closed for App Check, but Firestore App Check and edge controls require deployment verification. |
| Privacy, Logging, and Data Governance | 8% | 78 | 6.2 | medium | Logging scrubbers, privacy invariants, export sanitizer, and deletion exist; deletion audit is not fail closed. |
| Supply Chain and Secure SDLC | 8% | 78 | 6.2 | medium | Pinned actions, CodeQL, gitleaks, dependency review, OSV, provenance, and policy gates exist; deploy fallback secrets remain. |
| Security Testing and Verification | 10% | 72 | 7.2 | medium | Many security tests exist, but production daemon proof wiring and deployment-state checks are missing. |
| AI/Agentic Security | 10% | 70 | 7.0 | medium | Computer Use has gates, approvals, audit, and panic paths; daemon production wiring weakens high-impact claims. |
| Audit Readiness and Documentation | 4% | 74 | 3.0 | medium | This package provides missing audit artifacts; remaining evidence gaps block full external audit. |
| Overall Raw Score | 100% | 74 | 74.1 | medium | Strong implemented baseline with material claim and deployment proof gaps. |
| Final Score After Caps | 100% | 59 | 59.0 | medium | Major Claim Cap applied. |

## Applied Caps

| Cap | Max | Applied | Reason |
|---|---:|---|---|
| Catastrophic Cap | 39 | no | No unauthenticated sensitive data access, production secret in HEAD, or unauthenticated RCE path was found. |
| Critical Cap | 49 | no | No high-confidence broad plaintext compromise, ATO path, or production signing-key compromise was found. |
| Major Claim Cap | 59 | yes | High-impact daemon Computer Use proof and kill-switch/entitlement claims are not fully backed by the production daemon path. Firestore App Check deployment state is not repo-verifiable. |
| Audit Readiness Cap | 69 | no | This package creates the required architecture, data flow, asset, threat, findings, evidence, test, and roadmap artifacts. |
| Engineering Maturity Cap | 79 | yes | Some controls exist but lack production-mode regression tests, deployment-state verification, or operational proof. |

Final score: **59/100**

Confidence: medium

Auditor readiness: focused security review ready; not full external audit ready.

## Score Movement

No previous `security/audit/` state existed on this `origin/main` worktree.

| Field | Value |
|---|---|
| Previous raw score | N/A |
| Previous final score | N/A |
| Current raw score | 74 |
| Current final score | 59 |
| Delta | N/A |
| Caps added | Major Claim Cap, Engineering Maturity Cap |
| Findings opened | FINDING-001 through FINDING-009 |
| Findings fixed | none |
| Findings reopened | none |

## Path to 70

- Fix FINDING-001 by wiring daemon local-auth proof in production.
- Fix FINDING-003 by correcting URL validation and adding regression tests.
- Add Firestore App Check deployment verifier for FINDING-004.

Expected result: Major Claim Cap can likely be removed; final score can move into the high 60s or low 70s if checks pass.

## Path to 80

- Complete Path to 70.
- Replace daemon synthetic entitlement and kill-switch context.
- Add public endpoint rate-limit inventory and tests.
- Make deletion audit durable.
- Remove production deploy long-lived secret fallbacks.

## Path to 90

- Complete Path to 80.
- Add adversarial Computer Use and MCP tests for prompt/tool-output injection and confused deputy flows.
- Add production access review evidence, incident-response runbook proof, and monitoring playbooks.
- Produce a near-final external auditor package with test accounts and verified environment state.

## Path to 95+

- Complete Path to 90.
- Obtain independent external review or equivalent rigorous third-party evidence.
- Maintain stable scores across at least two reruns.
- Ensure all Critical/High/Medium findings are fixed or formally accepted with regression guards.

