# Evidence Map

## Findings to Evidence

| Finding | Evidence | Confidence |
|---|---|---|
| FINDING-001 | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemonExecutable/OpenBurnBarDaemonMain.swift:54-86`; `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCComputerUse.swift:111-132`; `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarDaemonComputerUseLocalAuthProofWiringTests.swift:90-242` | high |
| FINDING-002 | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/ComputerUseService.swift:108-149,285-310`; `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseCapabilityGate.swift:232-246` | high |
| FINDING-003 | `functions/src/callables/shared/validators.ts:344-356`; `functions/src/callables/stripe.ts:229-254,314-341` | high |
| FINDING-004 | `firestore.rules:20-23`; `functions/src/appCheckAttestation.ts:1-8`; `functions/src/config.ts:384-399` | high |
| FINDING-005 | `functions/src/security/endpointAuthorizationCatalog.generated.ts`; `functions/src/routerRundown.ts:205-220`; `services/hosted-mcp/src/rateLimits.ts:5-36` | medium |
| FINDING-006 | `functions/src/callables/dataDeletion.ts:105-113`; `functions/src/callables/auditLog.ts:171-184`; `functions/src/callables/dataExport.ts:606-660` | high |
| FINDING-007 | `.github/workflows/deploy-production.yml:3-6,109-119,193-201` | high |
| FINDING-008 | `AgentLens/Services/DataStore/DatabaseEncryptionService.swift:95-117` | high |
| FINDING-009 | `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift:202-223,31-82,470-486` | high |

## Claims to Evidence

| Claim | Evidence | Tests | Confidence |
|---|---|---|---|
| CLAIM-001 | `functions/src/auth.ts:39-72`; endpoint catalog | endpoint auth/high-risk guard tests | high |
| CLAIM-002 | `firestore.rules`; `firestore.rules:20-23`; `appCheckAttestation.ts:1-8` | Firestore emulator tests | medium |
| CLAIM-003 | `hosted-mcp/src/auth.ts:152-187`; `oauthToken.ts:106-171`; `resources.ts:33-72`; `shim.ts:87-151` | hosted MCP tests | high |
| CLAIM-004 | `CloudVaultCrypto.swift:202-223` | crypto tests, not universal Signal proof | high |
| CLAIM-005 | `DatabaseEncryptionService.swift:95-117`; `KeychainStore.swift:87-188`; `vaultStore.ts:1-68` | partial | medium |
| CLAIM-006 | `DaemonLocalAuthProofVerifier.swift`; `OpenBurnBarDaemonMain.swift:54-86`; `RPCComputerUse.swift:111-132` | verifier tests | high |
| CLAIM-007 | `ComputerUseCapabilityGate.swift:232-246`; `ComputerUseService.swift:108-149,285-310` | partial | medium |
| CLAIM-008 | `stripe.ts:536-575` | expected webhook tests | high |
| CLAIM-009 | `dataExport.ts:606-660`; `auditLog.ts:171-184` | export fail-closed tests | high |
| CLAIM-010 | `validators.ts:344-356`; `stripe.ts:229-254,314-341` | missing | high |
| CLAIM-011 | `rateLimits.ts:5-36`; public Function evidence | partial | medium |
| CLAIM-012 | `deploy-production.yml:109-119,193-201` | missing | high |

## Existing Control Evidence

| Control | Evidence |
|---|---|
| Auth/App Check helpers | `functions/src/auth.ts:39-72` |
| Production App Check fail closed for Functions | `functions/src/config.ts:384-399` |
| High-risk nonces | `functions/src/appCheckAttestation.ts:155-207,236-255` |
| High-risk owner action wrapper | `functions/src/callables/highRiskOwnerAction.ts:26-58` |
| Firestore server-only secret refs | `firestore.rules:1373-1374` |
| Firestore high-risk nonce server-only | `firestore.rules:4449-4451` |
| Logging scrubber | `functions/src/logging.ts:16-153` |
| Sentry app scrubber | `AgentLens/App/AgentLensApp.swift:1842-1907` |
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
| CI gitleaks/dependency/OSV | `.github/workflows/security-pr.yml` |
| CodeQL | `.github/workflows/codeql.yml` |
| Supply-chain attestation | `.github/workflows/supply-chain-provenance.yml` |

