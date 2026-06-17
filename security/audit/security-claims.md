# Security Claims Matrix

## Claims

| ID | Claim | Status | Evidence | Tests | Confidence | Gaps | Safe wording | Unsafe wording | Recommendation |
|---|---|---|---|---|---|---|---|---|---|
| CLAIM-001 | Most protected callable APIs require Firebase Auth and App Check. | Defensible | `functions/src/auth.ts:39-72`, `functions/src/security/endpointAuthorizationCatalog.generated.ts` | endpoint authorization and high-risk guard tests | high | public endpoints must remain enumerated | Protected callable APIs use Firebase Auth and App Check unless explicitly classified as public/webhook/platform. | Every endpoint requires Auth and App Check. | Keep generated matrix in CI. |
| CLAIM-002 | Firestore access is owner scoped and App Check enforced. | Partially defensible | `firestore.rules`, `firestore.rules:20-23`, `appCheckAttestation.ts:1-8` | Firestore emulator tests exist | medium | App Check enforcement is console/deployment state | Firestore rules are owner-scoped; production App Check state must be verified separately. | Firestore App Check is proven by repo rules. | Add deployment verifier. |
| CLAIM-003 | Hosted MCP uses scoped short-lived tokens and local decryption for sealed bodies. | Defensible | `hosted-mcp/src/auth.ts:152-187`, `oauthToken.ts:106-171`, `resources.ts:33-72`, `toolRegistry.ts:197-210`, `shim.ts:87-151` | hosted MCP auth/rate tests | high | production key rotation runbook unknown | Hosted MCP enforces bearer token, client, scope, entitlement, and rate checks; sealed bodies are decrypted locally by the shim. | Hosted MCP can never expose sensitive data. | Keep local-decrypt invariant tested. |
| CLAIM-004 | All sensitive user data has Signal-quality E2EE. | Not defensible | `CloudVaultCrypto.swift:202-223`, `CloudVaultCrypto.swift:31-82,470-486` | crypto tests and vectors exist | medium | Signal envelope is additive/flag-off | Cloud Vault sealed fields use AES-GCM with context-bound AAD; Signal envelopes apply only to enabled tested flows. | All data is Signal-quality E2EE. | Add claim lint and flow-specific proofs. |
| CLAIM-005 | Local encrypted data keys are stored in Keychain. | Partially defensible | `DatabaseEncryptionService.swift:95-117`, `KeychainStore.swift:87-188`, `vaultStore.ts:1-68` | Keychain tests exist in areas | medium | SQLCipher key path can continue after failed store | Local app secrets are intended to be stored in Keychain; fix SQLCipher fail-open persistence path. | Keychain persistence always succeeds or fails closed. | Fix FINDING-008. |
| CLAIM-006 | Daemon Computer Use requires independent local-auth proof. | Partially defensible | `DaemonLocalAuthProofVerifier.swift`, `OpenBurnBarDaemonMain.swift:54-86`, `RPCComputerUse.swift:111-132` | verifier wiring tests | high | production executable passes nil | The verifier exists and is test-covered when wired; production daemon wiring must be fixed before claiming universal enforcement. | Daemon Computer Use always requires local-auth proof. | Fix FINDING-001. |
| CLAIM-007 | Daemon Computer Use is always kill-switch and entitlement gated. | Partially defensible | `ComputerUseCapabilityGate.swift:232-246`, `ComputerUseService.swift:108-149,285-310` | gate tests exist | medium | daemon context is synthetic | App-mediated Computer Use has gate inputs; daemon browser path must use live entitlement and kill-switch state. | All Computer Use is centrally kill-switch gated. | Fix FINDING-002. |
| CLAIM-008 | Stripe webhooks are signature verified and idempotent. | Defensible | `stripe.ts:536-575` | Stripe webhook tests expected | high | none found for core signature path | Stripe webhooks are verified with the configured webhook secret and processed with idempotency reservation. | None needed. | Keep raw-body signature tests. |
| CLAIM-009 | High-risk data export is fail-closed audited. | Defensible | `dataExport.ts:606-660`, `auditLog.ts:171-184` | export fail-closed tests exist | high | deletion uses different audit behavior | Data export requires owner proof and required audit append. | All privacy operations are fail-closed audited. | Fix deletion audit or word carefully. |
| CLAIM-010 | Billing redirect URLs are HTTPS-only. | Not defensible | `validators.ts:344-356`, `stripe.ts:229-254,314-341` | missing | high | substring localhost check | Billing redirects should be treated as validated after FINDING-003 is fixed. | Billing redirect URLs are HTTPS-only today. | Fix URL validation. |
| CLAIM-011 | Public endpoints are rate limited. | Partially defensible | `hosted-mcp/src/rateLimits.ts:5-36`, `routerRundown.ts:205-220` | hosted MCP rate tests | medium | public Functions inventory lacks complete rate proof | Hosted MCP has explicit rate limits; public HTTP Functions need endpoint-by-endpoint proof. | All public endpoints are rate limited. | Add shared rate-limit inventory. |
| CLAIM-012 | Release deployment is OIDC/WIF only. | Not defensible | `deploy-production.yml:3-6,109-119,193-201` | workflow policy tests missing | high | JSON/token fallback remains | Production deploy supports OIDC but still has fallback paths. | Production deploy is WIF-only. | Remove fallback secrets. |

## Non-Claims

- Do not claim protection from a fully compromised user endpoint after authorized decryption.
- Do not claim anonymity.
- Do not claim universal Signal-quality E2EE.
- Do not claim Firestore App Check production state from repository rules alone.
- Do not claim all daemon Computer Use paths require local-auth proof until FINDING-001 is fixed.
- Do not claim all public endpoints are rate limited until edge or product-layer controls are inventoried.
- Do not treat model prompts or AI refusal behavior as a hard security boundary.

