# Threat Register

| ID | Title | Severity | Component | Status | Related finding |
|---|---|---|---|---|---|
| THREAT-001 | Unauthorized daemon Computer Use action after first-party process compromise | High | Daemon / Computer Use | open | FINDING-001 |
| THREAT-002 | Daemon Computer Use ignores remote kill switch or entitlement suspension | Medium | Daemon / Computer Use | open | FINDING-002 |
| THREAT-003 | Billing redirect phishing through weak return URL validation | Medium | Functions / Stripe | open | FINDING-003 |
| THREAT-004 | Direct Firestore access without deployed App Check enforcement | Medium | Firestore | open | FINDING-004 |
| THREAT-005 | Public endpoint denial-of-wallet or availability abuse | Medium | Public Functions | open | FINDING-005 |
| THREAT-006 | Irreversible deletion without durable audit evidence | Medium | Data deletion | open | FINDING-006 |
| THREAT-007 | CI/CD deploy credential compromise | Low | GitHub Actions | open | FINDING-007 |
| THREAT-008 | Unsupported privacy or E2EE claim creates user and audit risk | Low | Claims/Crypto | open | FINDING-009 |
| THREAT-009 | Local encrypted database availability loss from non-persisted key | Low | macOS data store | open | FINDING-008 |
| THREAT-010 | Remote MCP token replay or over-scoped access | Medium | Hosted MCP | controlled | none |
| THREAT-011 | Cross-user Firestore data access | High | Firestore/Functions | controlled | none |
| THREAT-012 | Sensitive data leakage through logs or crash reports | Medium | Logging/Sentry | controlled | none |

## Open Threat Details

THREAT-001 maps to STRIDE elevation of privilege and OWASP Agentic excessive agency. Evidence: `OpenBurnBarDaemonMain.swift:54-86`, `RPCComputerUse.swift:111-132`.

THREAT-002 maps to policy bypass and NIST Protect. Evidence: `ComputerUseService.swift:108-149,285-310`, `ComputerUseCapabilityGate.swift:232-246`.

THREAT-003 maps to CWE-601 open redirect/phishing. Evidence: `validators.ts:344-356`, `stripe.ts:229-254,314-341`.

THREAT-004 maps to Zero Trust verification drift. Evidence: `firestore.rules:20-23`, `appCheckAttestation.ts:1-8`.

THREAT-005 maps to OWASP API unrestricted resource consumption. Evidence: public endpoint catalog and `routerRundown.ts:205-220`.

THREAT-006 maps to LINDDUN non-repudiation and NIST Detect/Respond. Evidence: `dataDeletion.ts:105-113`, `auditLog.ts:171-184`.

THREAT-007 maps to NIST SSDF and release integrity. Evidence: `deploy-production.yml:109-119,193-201`.

THREAT-008 maps to privacy unawareness and claim risk. Evidence: `CloudVaultCrypto.swift:202-223`.

THREAT-009 maps to local storage availability. Evidence: `DatabaseEncryptionService.swift:95-117`.

## Controlled Threats

THREAT-010 is controlled by hosted MCP short-lived tokens, refresh hash rotation, scopes, entitlement, query-string token rejection, and rate limits. Residual risk is token theft within the access-token lifetime.

THREAT-011 is controlled by owner-scoped Firestore rules, `assertOwnership`, generated endpoint catalog, and BOLA/high-risk guard tests. Residual risk is new endpoint drift.

THREAT-012 is controlled by recursive scrubbers, Sentry `beforeSend`, hosted MCP redaction, and logging tests. Residual risk is processor retention/access and unreviewed log paths.

