# Threat Register

## Summary

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

## Detailed Threats

### THREAT-001: Unauthorized daemon Computer Use action after first-party process compromise

Category: STRIDE elevation of privilege, tampering; OWASP Agentic excessive agency/tool misuse; CWE-863 Incorrect Authorization.

Component: OpenBurnBarDaemon Computer Use RPC.

Data flow: FLOW-006, FLOW-007.

Asset: ASSET-008.

Threat actor: compromised endpoint, malicious local process with admitted first-party signature path, stolen daemon token.

Preconditions: attacker can talk to daemon and satisfy socket/code-signature controls or compromise an admitted process.

Attack path: call Computer Use start/invoke while production verifier is nil; missing proof is accepted.

Impact: high-impact local action under weaker authorization.

Likelihood: medium.

Severity: High.

Existing controls: socket token, code-signature peer auth, capability profile, approval/audit gate.

Missing controls: production local-auth proof wiring.

Detection opportunity: Computer Use action telemetry missing proof ID.

Test cases: production config denies missing, stale, replayed, wrong-intent proof.

Evidence: `OpenBurnBarDaemonMain.swift:54-86`, `RPCComputerUse.swift:111-132`.

Owner: Daemon / Computer Use.

Priority: P0.

Status: open.

Score impact: -12.

### THREAT-002: Daemon Computer Use ignores remote kill switch or entitlement suspension

Category: STRIDE elevation of privilege; NIST Protect; OWASP Agentic excessive agency.

Component: Daemon ComputerUseService.

Data flow: FLOW-007.

Asset: ASSET-008.

Threat actor: compromised account, suspended user, compromised endpoint.

Attack path: daemon browser action receives `killSwitch: false` and synthetic active entitlement.

Impact: action proceeds despite global shutdown or entitlement loss.

Likelihood: medium.

Severity: Medium.

Existing controls: capability gate, approvals, action caps.

Missing controls: live entitlement/Remote Config context.

Evidence: `ComputerUseService.swift:108-149,285-310`, `ComputerUseCapabilityGate.swift:232-246`.

Owner: Computer Use / Entitlements.

Priority: P1.

Status: open.

Score impact: -5.

### THREAT-003: Billing redirect phishing through weak return URL validation

Category: OWASP Web open redirect/phishing, CWE-601.

Component: Stripe checkout/portal callables.

Data flow: FLOW-008.

Asset: ASSET-012.

Threat actor: authenticated malicious user, compromised client.

Attack path: pass non-HTTPS attacker host containing `localhost` to checkout/portal return URL.

Impact: phishing or redirect confusion.

Likelihood: medium.

Severity: Medium.

Existing controls: Auth/App Check, Stripe hosted checkout, webhook signature.

Missing controls: exact loopback/HTTPS enforcement and allowlist.

Evidence: `validators.ts:344-356`, `stripe.ts:229-254,314-341`.

Owner: Functions / Billing.

Priority: P1.

Status: open.

Score impact: -4.

### THREAT-004: Direct Firestore access without deployed App Check enforcement

Category: Zero Trust verification gap, OWASP API improper inventory/deployment drift.

Component: Firestore.

Data flow: FLOW-003, FLOW-004.

Asset: ASSET-009.

Threat actor: compromised user account, scripted client.

Attack path: if Firebase App Check enforcement is off in production, direct Firestore SDK access uses Auth/rules without app attestation.

Impact: increased abuse surface for authenticated attackers.

Likelihood: medium until verified.

Severity: Medium.

Existing controls: owner-scoped rules, server-only secret paths, Functions App Check fail-closed.

Missing controls: repo-enforced deployment verifier.

Evidence: `firestore.rules:20-23`, `appCheckAttestation.ts:1-8`.

Owner: Cloud/Ops.

Priority: P1.

Status: open.

Score impact: -5.

### THREAT-005: Public endpoint denial-of-wallet or availability abuse

Category: STRIDE denial of service, OWASP API unrestricted resource consumption.

Component: public HTTP Functions.

Data flow: public HTTP routes.

Asset: ASSET-013 and service availability.

Threat actor: unauthenticated internet attacker.

Attack path: repeatedly call public endpoints that lack product-layer or verified edge rate limits.

Impact: cost spikes, noisy logs, degraded availability.

Likelihood: medium.

Severity: Medium.

Existing controls: maxInstances, validation, webhook signatures for some routes.

Missing controls: endpoint-by-endpoint rate-limit proof.

Evidence: `endpointAuthorizationCatalog.generated.ts`, `routerRundown.ts:205-220`.

Owner: Functions / Cloud Ops.

Priority: P1.

Status: open.

Score impact: -3.

### THREAT-006: Irreversible deletion without durable audit evidence

Category: LINDDUN non-repudiation, NIST Detect/Respond.

Component: data deletion callable.

Data flow: FLOW-009.

Asset: ASSET-009 and ASSET-013.

Threat actor: compromised user account, system fault during deletion.

Attack path: deletion succeeds while audit append fails.

Impact: weak incident response and compliance evidence.

Likelihood: low to medium.

Severity: Medium.

Existing controls: Auth/App Check, confirmation string, domain registry.

Missing controls: required pre-delete audit intent.

Evidence: `dataDeletion.ts:105-113`, `auditLog.ts:171-184`.

Owner: Privacy / Functions.

Priority: P1.

Status: open.

Score impact: -3.

### THREAT-007: CI/CD deploy credential compromise

Category: supply chain, SLSA, NIST Protect.

Component: production deploy workflow.

Data flow: FLOW-010.

Asset: ASSET-010.

Threat actor: malicious insider, compromised GitHub secret, compromised CI.

Attack path: use long-lived service-account JSON or Firebase token fallback to deploy.

Impact: malicious production code or config deployment.

Likelihood: low to medium.

Severity: Low.

Existing controls: GitHub environment, OIDC permission, health gate, rollback.

Missing controls: WIF-only production deployment.

Evidence: `deploy-production.yml:109-119,193-201`.

Owner: Platform / Release.

Priority: P2.

Status: open.

Score impact: -3.

### THREAT-008: Unsupported privacy or E2EE claim creates user and audit risk

Category: security claims, privacy unawareness, compliance.

Component: Cloud Vault claims and product copy.

Asset: ASSET-004.

Threat actor: not attacker-specific; product/audit risk.

Attack path: public claims imply universal Signal-quality E2EE while code supports AES-GCM Cloud Vault and flag-gated Signal envelopes.

Impact: user misunderstanding, enterprise/audit failure.

Likelihood: medium if wording is broad.

Severity: Low.

Existing controls: crypto architecture and sealed envelopes.

Missing controls: claim lint and external copy review.

Evidence: `CloudVaultCrypto.swift:202-223`.

Owner: Product / Security.

Priority: P2.

Status: open.

Score impact: -2.

### THREAT-009: Local encrypted database availability loss from non-persisted key

Category: availability, secure local storage.

Component: SQLCipher database encryption service.

Asset: ASSET-002, ASSET-004.

Threat actor: system fault or Keychain failure.

Attack path: create database with generated key after Keychain persistence failure.

Impact: future app cannot reopen encrypted database.

Likelihood: low.

Severity: Low.

Existing controls: Keychain ThisDeviceOnly, recovery bundle.

Missing controls: fail closed on persistence failure.

Evidence: `DatabaseEncryptionService.swift:95-117`.

Owner: macOS data store.

Priority: P2.

Status: open.

Score impact: -2.

### THREAT-010: Remote MCP token replay or over-scoped access

Category: API authorization, token replay.

Component: hosted MCP.

Asset: ASSET-006.

Threat actor: stolen token holder.

Existing controls: short-lived access tokens, refresh token hashing/rotation, client and audience checks, scopes, entitlement, rate limits, query-string token rejection.

Evidence: `auth.ts:152-187`, `oauthToken.ts:106-171`, `toolRegistry.ts:197-210`, `rateLimits.ts:5-36`.

Residual risk: token theft within 15 minute window.

Status: controlled.

### THREAT-011: Cross-user Firestore data access

Category: OWASP API BOLA/IDOR, CWE-639.

Component: Firestore/Functions.

Asset: ASSET-009.

Existing controls: owner-scoped rules, `assertOwnership`, generated endpoint catalog and BOLA/high-risk guard tests.

Evidence: `functions/src/auth.ts:22-31`, `firestore.rules`, endpoint auth catalog/tests.

Residual risk: new endpoints must stay in generated catalog and rules tests.

Status: controlled.

### THREAT-012: Sensitive data leakage through logs or crash reports

Category: privacy data disclosure, CWE-532.

Component: Functions, hosted MCP, macOS/iOS/Android Sentry.

Asset: ASSET-013.

Existing controls: recursive scrubbers, key and token pattern redaction, Sentry beforeSend, hosted MCP redaction.

Evidence: `logging.ts:16-153`, `AgentLensApp.swift:1842-1907`, `hosted-mcp/src/redaction.ts:1-30`.

Residual risk: processor retention/access and periodic sampling proof are unknown.

Status: controlled.

