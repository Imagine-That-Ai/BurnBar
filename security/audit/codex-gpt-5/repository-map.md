# Repository Map

Model/run namespace: `codex-gpt-5`

## Applications, Services, and Packages

| Area | Purpose | Security relevance |
|---|---|---|
| `AgentLens/` | macOS Swift app | Firebase Auth, Keychain, SQLCipher, Sentry, Computer Use coordination, local secrets |
| `AgentLensTests/` | macOS XCTest sources | app, privacy, data store, and service regression tests |
| `OpenBurnBarDaemon/` | SwiftPM local daemon and HTTP gateway | local RPC, socket token auth, code-signature peer auth, Computer Use execution |
| `OpenBurnBarCore/` | shared Swift models and crypto | Cloud Vault crypto, Computer Use policy, audit chain |
| `OpenBurnBarMobile/` | iOS app | mobile approval, media, Firebase client access |
| `android/` | Android Kotlin app | Firebase client, FCM/device identity, mobile parity, iroh relay |
| `functions/` | Firebase Functions TypeScript | callable APIs, App Check, authz, billing, webhooks, data export/delete, audit log |
| `services/hosted-mcp/` | hosted MCP TypeScript service | OAuth-like grants, tokens, scopes, rate limits, local-decrypt model |
| `tools/openburnbar-mcp-remote/` | remote MCP local shim | local vault key storage, token refresh, ciphertext decryption |
| `extensions/openburnbar/` | VS Code extension | IDE integration and alerting |
| `.github/workflows/` | CI/CD | release integrity, secret scanning, CodeQL, dependency review, deploy |
| `firestore.rules`, `storage.rules` | Firebase policy | object-level authorization and storage access |
| `docs/security/`, `droid-wiki/` | security and product docs | claims, runbooks, threat models |

## Technology Stack

Languages: Swift, TypeScript, Kotlin, Java, Rust, Python, Shell, SQL.

Core providers and frameworks: Firebase Auth, App Check, Functions, Firestore, Cloud Storage, Stripe, Sentry, GitHub Actions, SQLCipher, Keychain, CryptoKit, hosted MCP, local daemon IPC, iroh.

## Security-Sensitive Files

| File | Purpose | Why sensitive | Confidence |
|---|---|---|---|
| `functions/src/auth.ts` | Auth/App Check helpers | API admission and ownership checks | high |
| `functions/src/config.ts` | production security config | fail-closed App Check and nonce posture | high |
| `functions/src/appCheckAttestation.ts` | high-risk nonce/device attestation | trusted-device proof | high |
| `functions/src/callables/highRiskOwnerAction.ts` | high-risk wrapper | export, grants, revokes, owner proof | high |
| `functions/src/security/endpointAuthorizationCatalog.generated.ts` | endpoint catalog | generated auth expectation inventory | high |
| `firestore.rules` | Firestore rules | owner and server-only access control | high |
| `functions/src/callables/shared/validators.ts` | validators | path, URL, and envelope validation | high |
| `functions/src/callables/stripe.ts` | billing and webhooks | payment integrity and redirects | high |
| `functions/src/callables/dataExport.ts` | export | privacy and sealed data handling | high |
| `functions/src/callables/dataDeletion.ts` | deletion | irreversible privacy operation | high |
| `functions/src/callables/auditLog.ts` | audit log | tamper-evident action evidence | high |
| `functions/src/logging.ts` | log scrubber | sensitive logging control | high |
| `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift` | crypto | AES-GCM, AAD, Signal claim boundary | high |
| `AgentLens/Services/DataStore/DatabaseEncryptionService.swift` | SQLCipher | local database confidentiality and availability | high |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemonExecutable/OpenBurnBarDaemonMain.swift` | daemon executable | production auth wiring | high |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCComputerUse.swift` | daemon Computer Use RPC | high-impact local action boundary | high |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/DaemonLocalAuthProofVerifier.swift` | proof verifier | independent local-auth proof | high |
| `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseCapabilityGate.swift` | Computer Use gate | approvals, caps, entitlement, kill switch | high |
| `services/hosted-mcp/src/auth.ts` | hosted MCP token verification | bearer token admission | high |
| `services/hosted-mcp/src/oauthToken.ts` | token refresh | refresh rotation and revocation | high |
| `services/hosted-mcp/src/toolRegistry.ts` | tool authorization | scopes, entitlements, rate limits | high |
| `.github/workflows/security-pr.yml` | security PR gates | gitleaks, dependency review, OSV | high |
| `.github/workflows/deploy-production.yml` | production deployment | deploy credentials and release integrity | high |

## Unknowns

See `open-questions.md` for owner-tracked unknowns.

