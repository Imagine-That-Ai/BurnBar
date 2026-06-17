# Evidence Map

## Findings to Evidence

| Finding | Evidence | Confidence |
|---|---|---|
| FINDING-001 | `OpenBurnBarDaemonMain.swift:54-86`; `RPCComputerUse.swift:111-132`; `BurnBarDaemonComputerUseLocalAuthProofWiringTests.swift:90-242` | high |
| FINDING-002 | `ComputerUseService.swift:108-149,285-310`; `ComputerUseCapabilityGate.swift:232-246` | high |
| FINDING-003 | `validators.ts:344-356`; `stripe.ts:229-254,314-341` | high |
| FINDING-004 | `firestore.rules:20-23`; `appCheckAttestation.ts:1-8`; `config.ts:384-399` | high |
| FINDING-005 | endpoint catalog; `routerRundown.ts:205-220`; `rateLimits.ts:5-36` | medium |
| FINDING-006 | `dataDeletion.ts:105-113`; `auditLog.ts:171-184`; `dataExport.ts:606-660` | high |
| FINDING-007 | `deploy-production.yml:3-6,109-119,193-201` | high |
| FINDING-008 | `DatabaseEncryptionService.swift:95-117` | high |
| FINDING-009 | `CloudVaultCrypto.swift:202-223,31-82,470-486` | high |

## Existing Control Evidence

| Control | Evidence |
|---|---|
| Auth/App Check helpers | `functions/src/auth.ts:39-72` |
| Functions production App Check fail closed | `functions/src/config.ts:384-399` |
| High-risk nonces | `functions/src/appCheckAttestation.ts:155-207,236-255` |
| High-risk owner action wrapper | `functions/src/callables/highRiskOwnerAction.ts:26-58` |
| Firestore server-only secret refs | `firestore.rules:1373-1374` |
| Logging scrubber | `functions/src/logging.ts:16-153` |
| SSRF guard | `functions/src/ssrfGuard.ts:1-79` |
| raw fetch CI guard | `scripts/ci/verify-resilience-wiring.sh:1-48` |
| Stripe webhook verification | `functions/src/callables/stripe.ts:536-575` |
| Cloud Vault AES-GCM/AAD | `CloudVaultCrypto.swift:31-82,470-486` |
| Data export sanitizer | `functions/src/callables/dataExport.ts:510-660` |
| Hosted MCP token verifier | `services/hosted-mcp/src/auth.ts:152-187` |
| Hosted MCP rate limits | `services/hosted-mcp/src/rateLimits.ts:5-36` |
| Daemon token/auth config | `OpenBurnBarDaemonConfiguration.swift:95-121,193-291` |
| Daemon peer auth | `BurnBarDaemonPeerAuthenticator.swift:69-121` |
| Computer Use gate | `ComputerUseCapabilityGate.swift:232-373` |
| Computer Use audit chain | `ComputerUseAuditChain.swift:81-180` |
| CI gates | `.github/workflows/security-pr.yml`, `.github/workflows/codeql.yml`, `.github/workflows/supply-chain-provenance.yml` |

