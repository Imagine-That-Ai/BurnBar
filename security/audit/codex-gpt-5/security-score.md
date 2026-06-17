# Security Score

Run mode: FULL_BASELINE

Model/run namespace: `codex-gpt-5`

Commit: `0e0b063b27e39ad8cd1210ee829c2c7de28db620`

| Category | Weight | Score | Weighted Contribution | Confidence | Main reason |
|---|---:|---:|---:|---|---|
| Architecture and Threat Model | 10% | 82 | 8.2 | high | strong component inventory and threat-model docs |
| Security Claims and Evidence | 10% | 63 | 6.3 | medium | Computer Use and Signal/E2EE wording need narrowing |
| Authentication, Authorization, and Identity | 12% | 80 | 9.6 | high | endpoint matrix, owner checks, App Check, high-risk nonces, passkeys |
| Cryptography, Secrets, and Protocols | 10% | 74 | 7.4 | medium | AES-GCM AAD, Keychain, MCP tokens; daemon proof and Signal gaps |
| Application/API/Data Validation | 10% | 76 | 7.6 | medium | validators exist; Stripe URL bug and public rate gaps remain |
| Cloud, Infrastructure, and Operations | 8% | 68 | 5.4 | medium | Firestore App Check and edge controls require deployment verification |
| Privacy, Logging, and Data Governance | 8% | 78 | 6.2 | medium | scrubbers/export/deletion exist; deletion audit is not fail closed |
| Supply Chain and Secure SDLC | 8% | 78 | 6.2 | medium | scans/provenance exist; deploy fallback secrets remain |
| Security Testing and Verification | 10% | 72 | 7.2 | medium | many tests; missing production daemon and deployment-state tests |
| AI/Agentic Security | 10% | 70 | 7.0 | medium | gates/approvals/audit exist; daemon production gaps remain |
| Audit Readiness and Documentation | 4% | 74 | 3.0 | medium | model-named package created; remaining evidence gaps block full audit |
| Overall Raw Score | 100% | 74 | 74.1 | medium | strong baseline with material claim and deployment proof gaps |
| Final Score After Caps | 100% | 59 | 59.0 | medium | Major Claim Cap applied |

## Applied Caps

| Cap | Max | Applied | Reason |
|---|---:|---|---|
| Catastrophic Cap | 39 | no | no unauthenticated sensitive data access, committed production secret, or unauthenticated RCE path found |
| Critical Cap | 49 | no | no high-confidence broad plaintext compromise, ATO path, or signing-key compromise found |
| Major Claim Cap | 59 | yes | daemon Computer Use proof and kill-switch/entitlement claims not fully backed; Firestore App Check deployment proof missing |
| Audit Readiness Cap | 69 | no | required audit artifacts exist in model namespace |
| Engineering Maturity Cap | 79 | yes | missing production-mode regression tests and deployment-state verification |

Final score: **59/100**

Auditor readiness: focused security review ready; not full external audit ready.

