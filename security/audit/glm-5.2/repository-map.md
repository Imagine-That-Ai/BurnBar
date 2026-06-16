# Repository Map

## A.1 Repository Structure

### Applications
| Component | Path | Language | Trust Level | Purpose |
|-----------|------|----------|-------------|---------|
| macOS menu bar app | `AgentLens/` | Swift (SwiftUI) | Local user | Token tracking, Computer Use host, CloudVault, Hermes |
| iOS app | `OpenBurnBarMobile/` | Swift (SwiftUI) | Local user | Mobile companion, agent watch, media, Computer Use phone control |
| Android app | `android/` | Kotlin (Jetpack Compose) | Local user | Mobile companion (full iOS parity as of 2026-05-16) |
| VS Code extension | `extensions/openburnbar/` | TypeScript | Editor workspace | Usage display, alerting |
| Web console | `apps/console/` | TypeScript (Next.js) | Authenticated user | Admin/console |
| Website | `website/` | TypeScript (Astro) | Public | Marketing, docs |
| Widget | `OpenBurnBarWidget/` | Swift | Local user | macOS widget |
| Keyboard helper | `OpenBurnBarKeyboard/` | Swift | Privileged | HID input injection |

### Services / Backend
| Component | Path | Language | Trust Level | Purpose |
|-----------|------|----------|-------------|---------|
| Cloud Functions | `functions/src/` | TypeScript | Server (Firebase) | Callable endpoints (~75), triggers, scheduled jobs |
| Daemon | `OpenBurnBarDaemon/` | Swift | Local privileged | Privileged input, HID bridge, search DB, gateway |
| Core library | `OpenBurnBarCore/` | Swift | Shared | Crypto, Computer Use core, iroh relay |
| Hermes CLI | `hermes_cli/` | Python | Local user | Hermes agent bridge |
| Gateway | `gateway/` | Python | Local user | TUI gateway |
| TUI gateway | `tui_gateway/` | Python | Local user | Terminal UI |

### Infrastructure
| Component | Path | Purpose | Security Note |
|-----------|------|---------|---------------|
| Firestore rules | `firestore.rules` (4474 lines) | Data access control | uid-bound collections, session-log allowlist, CloudVault AAD |
| Storage rules | `storage.rules` | File access control | Owner-only reads; avatars previously public-read, now owner-only |
| Firebase config | `firebase.json` | Service configuration | |
| Firestore indexes | `firestore.indexes.json` | Index + TTL definitions | TTLs for push queues, nonces, notification events |
| CI/CD | `.github/workflows/` (39 files) | Build, test, deploy, security | SHA-pinned Actions, least-privilege perms, SBOM+SLSA |
| Pre-commit | `.pre-commit-config.yaml` | gitleaks, detect-secrets, SwiftLint, detect-private-key, no-commit-to-branch | |
| Docker | `docker-compose.yml` | Local Firestore emulator | Dev only |
| XcodeGen | `project.yml` | Xcode project generation | Defines privileged helper bundling |

### Security-Sensitive Modules (Evidence-Backed)
| Module | Path | Why Sensitive | Confidence |
|--------|------|---------------|------------|
| Auth guards | `functions/src/auth.ts` | `assertAuth`, `assertOwnership`, `assertAppCheck`, `enforceAuthAndAppCheck` | High |
| App Check attestation | `functions/src/appCheckAttestation.ts` | High-risk nonce, attestation binding, 30-day max-age | High |
| Firestore rules | `firestore.rules` | uid isolation, session-log allowlist (`validSessionLogManifestKeys`), CloudVault AAD, workspace path gate | High |
| CloudVault crypto | `OpenBurnBarCore/Sources/OpenBurnBarCore/CloudVaultCrypto.swift` | AES-256-GCM, path-bound AAD, vault key Keychain storage | High |
| Daemon DB cipher | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarDaemonDatabaseCipher.swift` | SQLCipher fail-closed, `cipher_version` self-check | High |
| Computer Use gate | `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseCapabilityGate.swift` | Agent action approval decision tree, budget caps, deny regions | High |
| Capability tokens | `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/CapabilityToken.swift` | Ed25519-signed, escrow+attestation+scope binding, single-use nonce | High |
| Capability verifier | `OpenBurnBarDaemon/Sources/OpenBurnBarRemoteAccessAgentCore/VirtualHIDBridgeCapabilityGate.swift` | Offline token verification at HID boundary | High |
| Audit chain | `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseAuditChain.swift` | SHA-256 linked, signed terminal head, fail-closed validation | High |
| Kill switch | `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/PrivilegedInputKillSwitch.swift` | File-existence flag, checked before every HID dispatch | High |
| Kill-switch watchdog | `OpenBurnBarDaemon/Sources/OpenBurnBarPrivilegedInputKillSwitchWatchdog/PrivilegedInputKillSwitchWatchdogMain.swift` | **No peer auth on socket - FINDING-001** | High |
| Daemon socket auth | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift` | 3-layer: perms + token (constant-time) + codesig | High |
| Daemon local-auth-proof | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/DaemonLocalAuthProofVerifier.swift` | **Dormant in production - FINDING-002** | High |
| Hermes gateway | `functions/src/hermesGateway*.ts` | Envelope signing/PoP, token rotation, attachment authz | High |
| Account deletion | `functions/src/accountDeletion.ts` | GDPR erasure, KMS secret destruction, root queue sweep | High |
| Session log sync | `AgentLens/Services/CloudSync/SessionLogSyncService.swift` | E2E encrypted backup, keyed HMAC search, legacy plaintext scrub | High |
| Sentry scrubbers | `functions/src/sentry.ts`, `AgentLens/.../MacSentryScrubber.swift` | PII redaction, sendDefaultPii=false, UID hashed | High |
| iroh pairing | `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayPairing.swift` | Ed25519 device identity, key-change pinning | Medium |
| SSRF guard | `functions/src/ssrfGuard.ts` | Metadata/private-IP blocking; **no DNS pinning - FINDING-009** | High |
| BOLA tests | `functions/src/__tests__/bola/` (21 files) | Cross-tenant authorization proofs for 60+ endpoints | High |
| Phone trust UI | `OpenBurnBarMobile/Views/ComputerUse/PhoneControlOptionSheet.swift` | **Presents all modes, not downgrade-only - FINDING-003** | High |
| Env stripping | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarSwitcherShell.swift` | Strips daemon/gateway tokens from child process env | High |
| Supply chain | `.github/workflows/release.yml` | Code signing, notarization, SBOM, cosign attestations, live feed verification | High |

## A.2 Technology Stack

- **Languages:** Swift (macOS/iOS/Core/Daemon), Kotlin (Android), TypeScript (Functions/Extension/Web), Python (Hermes/Gateway/TUI), Rust (iroh crate)
- **Frameworks:** SwiftUI, Jetpack Compose, Firebase v2, Vitest, XCUITest, JUnit, Express 5
- **Auth:** Firebase Auth (Google, Apple, Passkeys via `@simplewebauthn`)
- **Database:** Cloud Firestore, SQLite/SQLCipher (daemon), GRDB
- **Cloud:** Google Cloud Functions, Cloud KMS, Cloud Storage, Secret Manager
- **Payments:** Stripe, Apple App Store Server Library, Google Play Billing
- **Crypto:** CryptoKit (AES-256-GCM, ChaChaPoly via HPKE, P-256, Ed25519), libsignal (readiness-gated, not activated)
- **Transport:** iroh P2P (QUIC), APNs (VoIP), FCM
- **Observability:** Sentry (scrubbed), Cloud Logging (scrubbed), os_log (privacy-classified)
- **Package managers:** npm (lockfile v3, exact pins), SPM, Cargo (lock), Gradle
- **CI/CD:** GitHub Actions (all external Actions SHA-pinned, verified by CI gate)
- **Code generation:** XcodeGen (`project.yml`), TypeSpec schema sync

## A.3 Secrets Posture

- **In repo:** No secrets detected. `functions/.env.burnbar.production` is committed but contains only public identifiers (product IDs, price IDs, URLs, feature flags) - verified line-by-line.
- **Secret scanning:** Triple scanning layer: gitleaks (`.gitleaks.toml`), detect-secrets (`.secrets.baseline`), trufflehog (release-time). Pre-commit `detect-private-key` hook.
- **Allowlists:** Narrow, path-restricted to deterministic test fixtures only (crypto KAT vectors, wire-format test keys).
- **Real secrets:** GitHub Actions secrets, Secret Manager, Cloud KMS. Firebase config injected at build time with placeholder validation + `umask 077`.

## A.4 Unknowns

| ID | Question | Why It Matters | Risk If Unresolved | How to Resolve |
|----|----------|---------------|-------------------|----------------|
| UNKNOWN-001 | Do deployed Firestore rules match this checkout? | Rules drift would invalidate all data access controls | Critical | Run `check-firestore-deploy-drift.mjs` against production |
| UNKNOWN-002 | Are TTL policies materialized in production? | Expired push queue docs would persist indefinitely | Medium | Run `verify-firestore-ttl-state.mjs` on next deploy |
| UNKNOWN-003 | Is Sentry configured with `sendDefaultPii: false` in the live project? | PII could be collected despite client scrubbers | Medium | Read back Sentry org/project settings |
| UNKNOWN-004 | Do shipped macOS/iOS artifacts include the telemetry scrubber before the DSN? | Scrubber must execute before Sentry captures events | Medium | Inspect built artifacts for DSN + scrubber path |
| UNKNOWN-005 | Does Remote Unlock work on a clean standard-user Mac? | Safety claim requires production-like proof | High | Install on clean Mac, verify root helper provisioning + panic + replay rejection |
| UNKNOWN-006 | Was git history purged for committed security evidence (M-004)? | Prior exposure of GCP owner email/IAM inventory | Medium | Verify `git log --all` has no evidence files, decide on rotation |
| UNKNOWN-007 | What App Check attestation max-age is acceptable? | 30-day window may be too long for high-impact callables | Medium | Product decision: tighten to 7 days or accept |
| UNKNOWN-008 | Is branch protection enforced on main? | Direct pushes could bypass security CI gates | Medium | Verify GitHub branch protection settings |
