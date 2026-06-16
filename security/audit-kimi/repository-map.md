# Repository Map and Security-Sensitive File Inventory

## A.1 Top-Level Structure

| Directory | Purpose | Security Relevance |
|---|---|---|
| `AgentLens/` | SwiftUI macOS app (menu bar, dashboard, settings, parsers, stores) | High — parses agent logs, holds local DB, drives daemon, manages cloud sync |
| `OpenBurnBarCore/` | Shared Swift types, RPC contracts, crypto helpers, cross-platform models | High — defines trust boundaries between app/daemon/mobile |
| `OpenBurnBarDaemon/` | Local JSON-RPC daemon + CLI + privileged Computer Use helpers | Critical — runs unsandboxed, owns local state, executes tools |
| `OpenBurnBarMobile/` | SwiftUI iOS companion app | High — receives synced data, device escrow, credential transfer |
| `android/` | Android companion app (Kotlin + Rust iroh crate) | High — parity with iOS, Firestore, iroh transport |
| `functions/` | Firebase Cloud Functions v2 backend | Critical — auth, billing, quota, encrypted search, Computer Use security |
| `services/hosted-mcp/` | BurnBar Pro hosted Remote MCP server | High — exposes search/resume to authenticated MCP clients |
| `services/hermes-realtime-relay/` | iroh/WebSocket relay service (legacy WSS retired) | Medium — transport-only, untrusted |
| `tools/openburnbar-mcp/` | Local stdio MCP server (Python) | Medium — exposes local DB search to external agents |
| `tools/openburnbar-mcp-remote/` | Local shim for hosted Remote MCP | Medium — handles tokens and decryption |
| `tools/opentimestamps-verifier-service/` | Dockerized OTS verifier | Low — audit-chain verification |
| `extensions/openburnbar/` | VS Code/Cursor extension (TypeScript) | High — talks to daemon, can request file/terminal tools |
| `apps/console/` | Next.js web console (`app.burnbar.ai`) | Medium — escrow/device management |
| `website/` | Astro marketing site (`burnbar.ai`) | Low — trust copy, public data |
| `packages/` | Shared TypeScript/Rust contracts (Signal envelopes, entitlements, data domains, wire protocol, design tokens) | High — correctness gates security claims |
| `crates/` | Rust crates (`openburnbar-iroh`, `project-code-static-parser`) | Medium — transport and parsing |
| `Vendor/libsignal` | libsignal submodule (AGPL lane) | High — crypto core for sealing |
| `docs/` | Architecture, threat model, runbooks, ADRs | High — source of claims |
| `scripts/` | Build, test, CI, security, supply-chain scripts | Medium — release integrity, secret injection |
| `.github/workflows/` | CI/CD workflows | Critical — release gates, secret access |
| `firestore.rules` | Firestore security rules | Critical — owner-scoped access |
| `firebase.json` | Firebase project config | Medium — hosting headers, function routing |
| `storage.rules` | Firebase Storage rules | Medium — encrypted blob access |
| `project.yml` | XcodeGen project spec | Medium — entitlements, signing, capabilities |

## A.2 Technology Stack

| Layer | Technology |
|---|---|
| Languages | Swift 6, TypeScript, Kotlin, Rust, Python, Shell |
| macOS/iOS frameworks | SwiftUI, GRDB, GRDB-SQLCipher, Firebase iOS SDK, Sentry Cocoa, AppAuth, Google Sign-In |
| Android frameworks | Jetpack Compose, Kotlin Coroutines, Firebase Android SDK, Room/GRDB, iroh Rust crate |
| Backend | Firebase Cloud Functions v2 (Node 22), Express, Firebase Admin |
| Database | SQLite (GRDB) local; Firestore cloud; Firebase Storage for encrypted blobs |
| Auth | Firebase Auth (Google, Apple), App Check, passkeys (WebAuthn) |
| Crypto | Signal/libsignal, CryptoKit, SQLCipher, HPKE P-256 + AES-GCM, Ed25519, SHA-256 |
| Transport | iroh QUIC, Firebase SDK, WebSocket (legacy), HTTPS/TLS |
| Payments | Stripe, Apple App Store (JWS), Google Play |
| Observability | Sentry, structured Cloud Logging, Cloud Monitoring |
| CI/CD | GitHub Actions, XcodeGen, SwiftPM, Gradle, cargo, cosign |

## A.3 Security-Sensitive Files

### Authentication / Authorization / Identity

| File | Purpose | Why Sensitive |
|---|---|---|
| `functions/src/auth.ts` | `assertAuth`, `assertOwnership`, `assertAppCheck`, `enforceAuthAndAppCheck` | Central authz enforcement |
| `functions/src/index.ts` | Exports all callable/scheduled functions | Attack surface enumeration |
| `firestore.rules` | Owner-scoped rules + secret-field prohibition | Primary tenant-isolation control |
| `functions/src/callables/computerUseSecurity.ts` | Device/pairing/authority callables | Trust root publication |
| `functions/src/callables/passkey.ts` | WebAuthn registration/assertion | Strong auth |
| `functions/src/callables/webAppCheck.ts` | Browser escrow device registration | Device trust |
| `functions/src/appCheckAttestation.ts` | App Check attestation binding | Device identity |
| `AgentLens/Services/Auth/` | Firebase Auth, Sign in with Apple/Google integration | User identity |
| `OpenBurnBarMobile/Views/Auth/SignInScene.swift` | iOS sign-in UI | Auth surface |
| `OpenBurnBarMobile/App/MobileDataProtectionBootstrap.swift` | iOS file protection bootstrap | Data-at-rest |
| `android/app/src/.../auth/` | Android auth screens | Auth surface |

### Cryptography / Keys / Secrets

| File | Purpose | Why Sensitive |
|---|---|---|
| `OpenBurnBarCore/Sources/OpenBurnBarCore/Crypto/` | Cloud Vault, Signal envelope, HPKE, escrow crypto | Core sealing |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Crypto/` | Daemon key storage, SQLCipher key handling | Local encryption keys |
| `AgentLens/Services/DatabaseEncryptionService.swift` | SQLCipher key lifecycle | At-rest encryption (pending codec) |
| `packages/libsignal-protocol/` | libsignal bindings | Sealed envelopes |
| `packages/signal-envelope-contracts/` | Cross-language envelope format | Interop correctness |
| `functions/src/callables/cloudVaultRotation.ts` | Cloud vault key rotation | Key lifecycle |
| `functions/src/callables/signalPrekeyDirectory.ts` | Signal prekey publishing | E2EE bootstrap |
| `.gitleaks.toml` | Secret-scan allowlist/policy | Supply-chain hygiene |
| `.secrets.baseline` | Detect-secrets baseline | Supply-chain hygiene |

### Local Agent / Daemon / Computer Use

| File | Purpose | Why Sensitive |
|---|---|---|
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift` | JSON-RPC daemon server | Local RPC surface |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/` | RPC method handlers | Tool dispatch |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarPrivilegedInputExecution.swift` | Privileged input XPC helper | HID/input injection |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarVirtualHIDBridge.swift` | Virtual HID bridge | Mac input control |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarPrivilegedInputKillSwitchWatchdog.swift` | Kill-switch watchdog | Safety halt |
| `AgentLens/Services/ComputerUse/` | Computer Use coordinator, approval, panic | High-impact tool gating |
| `AgentLens/Services/ComputerUse/PhoneControl*` | Phone → Mac control validation | Remote control authority |
| `docs/HERMES_COMPUTER_USE.md` | Wire/protocol reference | Trust model |

### AI / LLM / Agentic / Memory

| File | Purpose | Why Sensitive |
|---|---|---|
| `AgentLens/Services/LogParser/` | 17 log parsers | Untrusted content ingestion |
| `AgentLens/Services/ContextBuilder.swift` | Prompt/RAG assembly | Injection surface |
| `AgentLens/Views/Chat/ChatSessionController.swift` | Chat agent invocation | Prompt construction |
| `AgentLens/Services/CLIBridge/CLIArgumentBuilder.swift` | CLI prompt/builder | YOLO/dangerous flags |
| `functions/src/insightsHostedAnswer.ts` | Hosted insight generation | Server-side LLM call |
| `functions/src/callables/knowledgeMemory.ts` | Knowledge/memory commit | RAG write path |
| `functions/src/callables/encryptedSearch.ts` | Encrypted hosted search | Pro/privacy feature |
| `functions/src/callables/remoteMcp.ts` | Remote MCP grant/search | External agent access |
| `services/hosted-mcp/src/toolRegistry.ts` | Hosted MCP tool registry | Tool surface |
| `services/hosted-mcp/src/knowledge.ts` | Hosted knowledge search | Data exposure |
| `tools/openburnbar-mcp/server.py` | Local MCP server | Local DB exposure |
| `docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md` | Existing LLM threat model | Claims reference |

### Payments / Billing

| File | Purpose | Why Sensitive |
|---|---|---|
| `functions/src/callables/stripe.ts` | Stripe checkout/portal/webhook | Revenue/fraud |
| `functions/src/appstore/` | Apple JWS verification, entitlement reconciliation | Paid-tier authorization |
| `functions/src/callables/mediaSku.ts` | Media SKU grants | Entitlement |

### Privacy / Logging

| File | Purpose | Why Sensitive |
|---|---|---|
| `functions/src/logging.ts` | Structured PII-redacted logging | Leakage control |
| `functions/src/agentNotifications.ts` | Push notification orchestration | UID leak risk |
| `AgentLens/Services/CloudSync/` | Firestore sync, sealing | Cloud privacy |
| `AgentLens/Services/SessionLogSyncService.swift` | Session log upload | Sensitive content |
| `functions/src/callables/dataExport.ts` | User data export | GDPR/data portability |
| `functions/src/callables/dataDeletion.ts` | Account/data deletion | Privacy compliance |
| `functions/src/callables/privacyBackfill.ts` | Plaintext field cleanup | Historical privacy |
| `OpenBurnBarMobile/App/MobileSentryScrubber.swift` | iOS Sentry scrubber | Crash-report privacy |
| `android/app/src/main/java/com/openburnbar/security/ScreenPrivacy.kt` | Android screenshot blocking | Screen privacy |
| `docs/security/PRIVACY_INVARIANTS.md` | Privacy invariants | Policy |
| `docs/security/CONFIDENTIALITY_POLICY.md` | Confidentiality policy | Policy |

### CI/CD / Release / Supply Chain

| File | Purpose | Why Sensitive |
|---|---|---|
| `.github/workflows/release.yml` | macOS/iOS/Android release, signing, notarization | Release integrity |
| `.github/workflows/deploy-production.yml` | Production deploy | Infra access |
| `.github/workflows/fast-feedback.yml` | PR gates | Quality gates |
| `scripts/supply-chain-audit.sh` | Dependency/license/SBOM audit | Supply chain |
| `scripts/ci/inject-firebase-config.sh` | CI secret injection | Secret handling |
| `scripts/ci/inject-android-keystore.sh` | Android signing key injection | Signing key |
| `scripts/security/scan-publishable-tree.sh` | Pre-release secret scan | Leak prevention |
| `scripts/generate-sbom.py` | SBOM generation | Provenance |
| `.pre-commit-config.yaml` | Pre-commit hooks | Secret scanning, lint |

## A.4 Unknowns

| ID | Question | Why It Matters | Risk if Unresolved | How to Resolve |
|---|---|---|---|---|
| UNKNOWN-001 | Is SQLCipher actually linked and enabled in the current shipped Mac build? | Local DB encryption claim | High — plaintext local DB undermines privacy | Build the Release .app and inspect linked libraries; run `PRAGMA cipher_version` |
| UNKNOWN-002 | Is App Check for Firestore enforced in the production Firebase console? | Cloud sync tenant isolation | High — rules alone do not block non-app clients | Console audit + runtime probe via a non-attested client |
| UNKNOWN-003 | Are the 13 Computer Use tool kinds uniformly covered by approval/scope tests? | Unauthorized high-impact action | High | Add per-tool adversarial tests to `AgentLensTests/Active/` |
| UNKNOWN-004 | What is the complete set of third-party MCP servers/tools the extension can load? | Tool misuse / data exfil | Medium | Audit extension manifest and tool registry |
| UNKNOWN-005 | How is the daemon auth token rotated on update/reinstall? | Long-lived local secret | Medium | Inspect daemon install/repair flow |
| UNKNOWN-006 | Are Crashlytics/Sentry crash reports scrubbed of free-form user content? | Privacy leakage | Medium | Review Sentry before-send hooks |
| UNKNOWN-007 | Is the Cloudflare quick tunnel bound to a fixed origin-check or token? | Public URL abuse | Medium | Inspect Cursor connector tunnel code |
| UNKNOWN-008 | What is the retention/deletion SLA for Firestore `ops/` telemetry? | Compliance / privacy | Low | Review `docs/runbooks/slos.md` and data-deletion code |
