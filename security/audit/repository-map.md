# Repository Map

## A.1 Repository Structure

| Area | Purpose | Security relevance |
|---|---|---|
| `AgentLens/` | macOS Swift app | Firebase Auth, Keychain, SQLCipher, Sentry, Computer Use coordination, local secrets |
| `AgentLensTests/` | macOS XCTest sources | App, privacy, data store, and service regression tests |
| `OpenBurnBarDaemon/` | SwiftPM local daemon and HTTP gateway | Local RPC, socket token auth, code-signature peer auth, Computer Use execution surface |
| `OpenBurnBarCore/` | Shared Swift models and crypto | Cloud Vault crypto, Computer Use policy, audit chain, shared models |
| `OpenBurnBarMobile/` | iOS app | mobile approval, media, Firebase client access |
| `OpenBurnBarMobileTests/` | iOS tests | mobile unit coverage |
| `OpenBurnBarKeyboard/`, `OpenBurnBarWidget/` | iOS extensions | app group and extension data surface |
| `android/` | Android Kotlin app | Firebase client, FCM/device identity, mobile parity, iroh relay |
| `functions/` | Firebase Functions TypeScript | callable APIs, App Check, authz, billing, webhooks, data export/delete, audit log |
| `services/hosted-mcp/` | Hosted MCP TypeScript service | OAuth-like grants, tokens, scopes, rate limits, local-decrypt resource model |
| `tools/openburnbar-mcp/` | Local Python MCP tooling | local integration and possible secret handling |
| `tools/openburnbar-mcp-remote/` | Remote MCP local shim | local vault key storage, token refresh, ciphertext decryption |
| `extensions/openburnbar/` | VS Code extension | extension alerting, daemon/hosted integration |
| `crates/`, `Vendor/`, `third_party/` | Rust and vendored dependencies | transport and supply-chain surface |
| `.github/workflows/` | CI/CD | release integrity, secret scanning, CodeQL, dependency review, production deploy |
| `scripts/` | build, CI, ops, privacy, rollout scripts | security gates and release checks |
| `firestore.rules`, `storage.rules`, `firestore.indexes.json` | Firebase policy | object-level authorization and storage access |
| `docs/`, `droid-wiki/` | Product and architecture docs | claims, runbooks, threat models |
| `security/audit/` | This audit package | reusable security state and evidence |

## A.2 Technology Stack

| Category | Technologies |
|---|---|
| Languages | Swift, TypeScript, Kotlin, Java, Rust, Python, Shell, SQL |
| Apple stack | SwiftUI/AppKit, XCTest, Keychain, CryptoKit, SQLCipher, Sentry |
| Android stack | Kotlin, Gradle, Firebase Android SDK, Android Keystore expectations |
| Backend | Firebase Functions, Firestore, Cloud Storage, Firebase Auth, Firebase App Check |
| Hosted service | Node.js TypeScript HTTP service for hosted MCP |
| Payments | Stripe Checkout, Stripe Billing Portal, Stripe webhooks |
| Auth providers | Firebase Auth, Sign in with Apple, Google Sign-In, WebAuthn/passkeys, hosted MCP bearer tokens |
| Databases/storage | Firestore, Cloud Storage, local SQLCipher SQLite, Keychain |
| Transport | HTTPS, local loopback HTTP, UNIX sockets, iroh/Rust transport |
| Observability | Sentry, structured Firebase logs, audit logs |
| CI/CD | GitHub Actions, CodeQL, gitleaks, dependency review, OSV, npm audit, SLSA-style attestations, cosign |
| Model/agentic | Computer Use, MCP, local/hosted tools, prompt/context surfaces |

## A.3 Security-Sensitive File Inventory

| File | Purpose | Why sensitive | Confidence |
|---|---|---|---|
| `functions/src/auth.ts` | Firebase Auth/App Check helpers | API admission and ownership checks | high |
| `functions/src/config.ts` | production security config | fail-closed App Check and high-risk nonce config | high |
| `functions/src/appCheckAttestation.ts` | high-risk nonce/device attestation | trusted-device proof for high-risk callable actions | high |
| `functions/src/callables/highRiskOwnerAction.ts` | high-risk owner proof wrapper | authorization boundary for export, remote MCP grants, and similar actions | high |
| `functions/src/security/endpointAuthorizationCatalog.generated.ts` | callable authorization catalog | generated source of endpoint auth expectations | high |
| `functions/src/security/endpointAuthorizationMatrix.ts` | endpoint matrix export | security inventory and tests | high |
| `firestore.rules` | Firestore object rules | owner and server-only access control | high |
| `storage.rules` | Cloud Storage rules | object access control | medium |
| `functions/src/callables/stripe.ts` | billing callables and webhook | payment and redirect flow | high |
| `functions/src/callables/shared/validators.ts` | shared request validation | path, URL, envelope, and size validation | high |
| `functions/src/callables/shared/storage.ts` | storage path and object validation | ciphertext object upload/export integrity | high |
| `functions/src/callables/dataExport.ts` | user data export | privacy, sealed data, signed URLs | high |
| `functions/src/callables/dataDeletion.ts` | user data deletion | irreversible privacy operation | high |
| `functions/src/callables/auditLog.ts` | tamper-evident audit chain | forensic and compliance evidence | high |
| `functions/src/logging.ts` | structured logging and scrubber | sensitive data leakage control | high |
| `functions/src/ssrfGuard.ts` | outbound fetch guard | SSRF and metadata service protection | high |
| `functions/src/resilienceHelpers.ts` | resilient provider calls | SSRF, retries, circuit-breaker policy | high |
| `functions/src/providers/httpClient.ts` | provider HTTP wrapper | raw fetch prevention | high |
| `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift` | Cloud Vault crypto | encryption, AAD, keys, Signal envelope claims | high |
| `AgentLens/Services/DataStore/DatabaseEncryptionService.swift` | SQLCipher key lifecycle | local data confidentiality and availability | high |
| `AgentLens/Services/CursorConnector/KeychainStore.swift` | Keychain secret storage | local API keys and tokens | high |
| `AgentLens/Services/Settings/SettingsSecretPersistence.swift` | secret migration to Keychain | legacy plaintext secret migration | high |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift` | daemon RPC server | local process boundary and RPC dispatch | high |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonConfiguration.swift` | daemon auth configuration | fail-closed socket/gateway config | high |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarDaemonPeerAuthenticator.swift` | code-signature peer auth | local first-party peer boundary | high |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/DaemonLocalAuthProofVerifier.swift` | local-auth proof verification | independent Computer Use approval proof | high |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCComputerUse.swift` | daemon Computer Use RPC | high-impact action execution | high |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemonExecutable/OpenBurnBarDaemonMain.swift` | daemon executable wiring | production auth and verifier setup | high |
| `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseCapabilityGate.swift` | Computer Use policy gate | approval, entitlement, kill switch, and caps | high |
| `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseAuditChain.swift` | audit chain | tamper-evident Computer Use records | high |
| `services/hosted-mcp/src/auth.ts` | hosted MCP token verification | bearer token admission, Ed25519/HMAC posture | high |
| `services/hosted-mcp/src/config.ts` | hosted MCP production posture | rejects unsafe token config in production | high |
| `services/hosted-mcp/src/server.ts` | hosted MCP HTTP server | request validation, auth, audit | high |
| `services/hosted-mcp/src/oauthToken.ts` | token refresh and rotation | access/refresh token lifecycle | high |
| `services/hosted-mcp/src/toolRegistry.ts` | tool scope/rate-limit gate | MCP authorization and abuse resistance | high |
| `services/hosted-mcp/src/rateLimits.ts` | Firestore-backed rate limits | hosted MCP denial-of-wallet control | high |
| `tools/openburnbar-mcp-remote/src/vaultStore.ts` | local vault key storage | Keychain and fallback secret handling | high |
| `.github/workflows/security-pr.yml` | security PR gates | gitleaks, dependency, OSV, Firestore tests | high |
| `.github/workflows/deploy-production.yml` | production deployment | release integrity and deploy secrets | high |
| `.github/workflows/supply-chain-provenance.yml` | SBOM and attestation | artifact provenance | medium |

## A.4 Unknowns

| ID | Question | Why it matters | Likely risk if unresolved | How to resolve | Owner |
|---|---|---|---|---|---|
| UNKNOWN-001 | Is Firebase App Check enforcement enabled in production for Firestore? | Rules cannot prove deployment console state. | Direct Firestore clients may bypass app attestation. | Add Firebase/GCP API verifier to ops readiness. | Cloud/Ops |
| UNKNOWN-002 | What edge rate limits exist for public HTTP endpoints? | Some public functions show only maxInstances. | DoS and denial-of-wallet. | Inventory Cloud Armor/Firebase edge config. | Cloud/Ops |
| UNKNOWN-003 | Which public security claims are published outside the repo? | Claims must match implementation. | Audit/procurement and user trust risk. | Collect website, app store, sales, and docs copy. | Product/Security |
| UNKNOWN-004 | Who can access production data and secrets? | Insider and support access controls are not fully repo-visible. | Silent broad data access. | Produce IAM/exported access review. | Engineering leadership |
| UNKNOWN-005 | Are legacy deploy secret fallbacks still configured? | Workflow fallback paths may or may not have active secrets. | CI/CD compromise blast radius. | Audit GitHub Actions secrets and environment protection. | Platform |
| UNKNOWN-006 | What retention SLA covers backups and processor logs? | Privacy claims need deletion/retention evidence. | GDPR/procurement risk. | Document processor and backup retention. | Privacy |
| UNKNOWN-007 | Has independent review occurred after Computer Use and Remote MCP changes? | High score requires independent evidence. | Overstated audit readiness. | Attach review report or schedule review. | Security |
| UNKNOWN-008 | Which build variants compile out Mac System Computer Use? | Distribution-specific attack surface matters. | Unsafe app-store or public claims. | Map build flags to release artifacts. | Release |

