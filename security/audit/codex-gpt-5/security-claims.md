# Security Claims Matrix

| ID | Claim | Status | Evidence | Safe wording | Unsafe wording | Recommendation |
|---|---|---|---|---|---|---|
| CLAIM-001 | Most protected callable APIs require Firebase Auth and App Check. | Defensible | `functions/src/auth.ts:39-72`, endpoint catalog | Protected callables use Firebase Auth and App Check unless explicitly public/webhook/platform. | Every endpoint requires Auth and App Check. | Keep generated matrix in CI. |
| CLAIM-002 | Firestore access is owner scoped and App Check enforced. | Partially defensible | `firestore.rules`, `firestore.rules:20-23`, `appCheckAttestation.ts:1-8` | Firestore rules are owner-scoped; production App Check state must be verified separately. | Firestore App Check is proven by repo rules. | Add deployment verifier. |
| CLAIM-003 | Hosted MCP uses scoped short-lived tokens and local decryption for sealed bodies. | Defensible | `hosted-mcp/src/auth.ts`, `oauthToken.ts`, `shim.ts` | Hosted MCP enforces bearer, client, scope, entitlement, and rate checks; sealed bodies decrypt locally. | Hosted MCP can never expose sensitive data. | Keep local-decrypt invariant tested. |
| CLAIM-004 | All sensitive user data has Signal-quality E2EE. | Not defensible | `CloudVaultCrypto.swift:202-223` | Cloud Vault sealed fields use AES-GCM with context-bound AAD; Signal envelopes apply only to enabled tested flows. | All data is Signal-quality E2EE. | Add claim lint and flow-specific proofs. |
| CLAIM-005 | Local encrypted data keys are stored in Keychain. | Partially defensible | `DatabaseEncryptionService.swift:95-117`, `KeychainStore.swift`, `vaultStore.ts` | Local secrets are intended to be stored in Keychain; fix SQLCipher fail-open path. | Keychain persistence always fails closed. | Fix FINDING-008. |
| CLAIM-006 | Daemon Computer Use requires independent local-auth proof. | Partially defensible | `DaemonLocalAuthProofVerifier.swift`, `OpenBurnBarDaemonMain.swift:54-86` | Verifier exists and is tested when wired; production wiring must be fixed. | Daemon Computer Use always requires local-auth proof. | Fix FINDING-001. |
| CLAIM-007 | Daemon Computer Use is always kill-switch and entitlement gated. | Partially defensible | `ComputerUseCapabilityGate.swift`, `ComputerUseService.swift:108-149,285-310` | App-mediated gate inputs exist; daemon browser path needs live context. | All Computer Use is centrally kill-switch gated. | Fix FINDING-002. |
| CLAIM-008 | Stripe webhooks are signature verified and idempotent. | Defensible | `stripe.ts:536-575` | Stripe webhooks are verified with configured webhook secret and idempotency reservation. | None. | Keep raw-body signature tests. |
| CLAIM-009 | High-risk data export is fail-closed audited. | Defensible | `dataExport.ts:606-660`, `auditLog.ts:171-184` | Data export requires owner proof and required audit append. | All privacy operations are fail-closed audited. | Fix deletion audit or word carefully. |
| CLAIM-010 | Billing redirect URLs are HTTPS-only. | Not defensible | `validators.ts:344-356` | Billing redirect validation needs a fix before claiming HTTPS-only. | Billing redirects are HTTPS-only today. | Fix URL validation. |
| CLAIM-011 | Public endpoints are rate limited. | Partially defensible | `hosted-mcp/src/rateLimits.ts`, public Functions evidence | Hosted MCP is rate limited; public Functions need endpoint-by-endpoint proof. | All public endpoints are rate limited. | Add public rate inventory. |
| CLAIM-012 | Release deployment is OIDC/WIF only. | Not defensible | `deploy-production.yml:109-119,193-201` | Production deploy supports OIDC but still has fallback paths. | Production deploy is WIF-only. | Remove fallback secrets. |

## Non-Claims

- Do not claim universal Signal-quality E2EE.
- Do not claim protection from a fully compromised endpoint after authorized decryption.
- Do not claim Firestore App Check production state from repository rules alone.
- Do not claim all daemon Computer Use paths require local-auth proof until FINDING-001 is fixed.
- Do not treat prompts or model refusal behavior as a hard security boundary.

