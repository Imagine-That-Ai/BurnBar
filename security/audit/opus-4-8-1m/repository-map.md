# Repository Map (security-sensitive) — Opus 4.8 1M lane

## Top-level surfaces
| Path | Type | Lang | Security relevance |
|---|---|---|---|
| `AgentLens/` | macOS app | Swift (674 files) | unsandboxed local app, Keychain, daemon mgmt, CloudSync, Computer Use, updater |
| `OpenBurnBarCore/`, `OpenBurnBarDaemon/` | SPM packages | Swift | CloudVault crypto, daemon server, privileged input, iroh bridge |
| `OpenBurnBarMobile/` | iOS app | Swift | escrow, sealed sync, Sentry scrub |
| `android/` | Android app | Kotlin (906 files) | iroh pairing/pin, read-only Firestore + new write paths |
| `functions/` | Cloud Functions | TypeScript | auth, billing, gateway, rollups, quota, secrets, rules-adjacent |
| `crates/` | Rust | Rust (319) | remote engine, iroh, blob ceilings |
| `tools/`, `scripts/` | tooling/CI | JS/mjs/sh | IAP provisioning, CI gates, privacy/crypto/coverage gates |
| `firestore.rules`, `firestore.indexes.json` | rules/indexes | — | owner-scoping, secret denylist, TTL, AAD binding |
| `.github/workflows/` | CI/CD | YAML (35) | signing, scanning, provenance, deploy, gates |
| `Vendor/libsignal` | submodule | — | crypto provenance gate |

## Security-sensitive modules (high-signal)
- **AuthZ:** `functions/src/auth.ts`, `guards.ts`, `security/endpointAuthorizationMatrix.ts`, `endpointAuthorizationCatalog.generated.ts`, `bolaCoverage*.ts`, `appCheckAttestation.ts`
- **Crypto/Vault:** `OpenBurnBarCore/.../CloudVaultCrypto.swift`, `CloudVaultKeyAccess.swift`, `CloudVaultTrustedDeviceChainVerifier.swift`, `OpenBurnBarSignalCore/SignalAtRestSealer.swift`, `functions/src/secrets.ts`, `signalAtRestWrite.ts`, `signalEnvelope*.ts`
- **Billing:** `functions/src/appstore/{verifier,reconciler,entitlements,audit}.ts`, `stripe.ts`, `cloudProAllowance*.ts`
- **Privacy/logging:** `functions/src/logging.ts`, `accountDeletion.ts`, `agentNotifications.ts`, `callables/voipPush.ts`, `scripts/ci/check-privacy-invariants.mjs`, `AppLogger.swift`, `AgentLensApp.swift` (Sentry)
- **Desktop/IPC/update:** `OpenBurnBarDaemon/.../OpenBurnBarDaemonServer.swift`, `BurnBarDaemonPeerAuthenticator.swift`, `PrivilegedSocketTrust.swift`, `PrivilegedInputXPC*.swift`, `DirectDownload*.swift`, `CLIProcessStreamRunner.swift`, `RestrictedLogPathValidator.swift`
- **AI/agentic:** `functions/src/hermesGateway*.ts`, `routerRundown*.ts`, `providers/*.ts`, `ssrfGuard.ts`, `remoteMcp*.ts`, `AgentLens/Services/ComputerUse/*`, `ManagedAgentRuntime/*`, `ContextBuilder.swift`, `AgentSecurityPolicy.swift`

## Existing security documentation (verified, not trusted)
`docs/THREAT_MODEL.md`, `docs/security/BurnBar-threat-model.md` (73KB), `LLM_GENAI_AGENT_THREAT_MODEL.md`, `REMOTE_MCP_THREAT_MODEL.md`, `SECURITY_CLAIMS_REGISTER.md`, `PRIVACY_INVARIANTS.md`, `ENDPOINT_AUTHORIZATION_MATRIX.md`, `SUPPLY_CHAIN_PROVENANCE.md`, `ADR-001-crypto-architecture.md`, `crypto-architecture-policy.json`.

## Prior audit lineages (do not modify from this lane)
- `security-audit/` (06-14 multi-model, M-001…M-040) — authoritative finding IDs.
- `DILIGENCE_REPORT_2026-06-10/11.md` (internal, LB/P0/NB/CG IDs).
- `security/audit/*` (concurrent lane, FINDING-NNN) — separate, internally-inconsistent at audit time.
