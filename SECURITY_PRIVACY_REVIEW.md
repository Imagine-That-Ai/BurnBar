# OpenBurnBar Security & Privacy Review
**Branch:** `release/openburnbar-0.1.2-beta.12`  
**Date:** 2026-04-27  
**Reviewer:** Factory Security Worker Droid  
**Scope:** AgentLens macOS app, OpenBurnBarDaemon, OpenBurnBarCore, Firestore rules, entitlements, keychain, parsers, network surface, data storage

---

## 1. Security Posture Overview

OpenBurnBar is an unsandboxed macOS utility that parses local AI agent logs, aggregates token usage, and optionally syncs to Firebase Firestore. It runs a local daemon over a UNIX domain socket and an optional HTTP gateway. Secrets are stored in the macOS Keychain. Database encryption via SQLCipher is opt-in. Cloud features (Firebase, iCloud) are opt-in.

**Overall Assessment:** The codebase shows **above-average security hygiene** for a native macOS utility. Key strengths include: owner-scoped Firestore rules, mandatory auth tokens for daemon RPC, Keychain-backed secret persistence, rate limiting on both socket and HTTP surfaces, App Check attestation, and documented threat modeling. However, there are **material gaps** that should be addressed before a 1.0 launch, particularly around TLS for the HTTP gateway, SQLCipher key handling, and the encryption key recovery file.

---

## 2. Authentication / Authorization Assessment

### Firebase Auth
- **Implementation:** `AccountManager.swift` uses Firebase Auth with Google Sign-In and Sign in with Apple. Email/password is also supported.
- **Nonce handling:** Apple Sign-In nonce is generated with `SecRandomCopyBytes` and hashed with SHA-256. The raw nonce is stored in `currentNonce` (memory only) and cleared after use. **Correct.**
- **Token caching:** `lastOAuthToken` is cached in memory on `AccountManager`. It is never persisted to disk. **Acceptable for a session-bound property.**
- **Anonymous users:** The app supports anonymous Firebase users and links them on credential sign-in. This is standard Firebase behavior.
- **Firebase configuration:** `GoogleService-Info.plist` is `.gitignore`d; only an `.example` file is present. **Good.**
- **App Check:** `OpenBurnBarAppCheckProviderFactory.swift` uses `AppAttestProvider` on macOS 11+ in release builds, `DeviceCheckProvider` as fallback, and `AppCheckDebugProvider` only in DEBUG when a debug token is present in Info.plist. **Correct tiering.**

### Daemon Auth
- **Socket RPC:** Every RPC request to the daemon requires an `authToken`. The token is compared against `configuration.socketAuthToken`. If the token is missing or mismatched, the daemon returns `BurnBarRPCErrorCode.unauthorized`.
- **Token transmission:** The auth token is passed to the daemon via `launchd EnvironmentVariables` (not CLI arguments) to prevent `ps aux` exposure. The launchd plist is written with `0o600` permissions.
- **Peer PID verification:** `BurnBarDaemonServer.peerPID(for:)` uses `getsockopt(clientFileDescriptor, SOL_LOCAL, LOCAL_PEERPID, ...)` on macOS to identify the connecting process. **Good practice.**
- **HTTP Gateway:** Bearer token auth is required when binding to non-loopback addresses. The gateway rejects wildcard binds (`0.0.0.0`, `::`).

### Firestore Authorization
- **Rules (`firestore.rules`):** Owner-scoped explicit collection rules cover the supported `users/{uid}/...` sync paths and `workspaces/workspace-{uid}/...` shared-artifact paths. Client-writable sync documents reject plaintext-looking secret field names, usage rollups and rate-limit docs are server-only, and provider credential reference docs live in top-level `provider_account_secret_refs` with all client access denied. Basic size limits (`< 1 MB`, `< 80 keys`) are enforced.
- **App Check dependency:** The rules file correctly includes a comment that `request.auth` alone is insufficient and App Check must be enforced in the Firebase console. **This is an operational gap:** there is no runtime verification that App Check is actually enforced in the target project.

**Verdict:** Authentication and authorization architecture is sound. The operational gap is ensuring the production Firebase console has App Check enforcement turned on for Firestore.

---

## 3. Secrets Management Quality

### Keychain Usage
- **Service:** `KeychainStore.swift` wraps `Security.framework` with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- **Non-interactive reads:** Uses `LAContext.interactionNotAllowed = true` and `withKeychainInteractionDisabled` to suppress keychain UI prompts. **Good.**
- **Write verification:** `KeychainStore.set()` calls `ensureNonInteractiveReadability` to verify the item can be read back without user interaction. **Defensive.**
- **Legacy migration:** Automatically migrates secrets from legacy keychain services and UserDefaults keys, then deletes the legacy entries. **Clean.**
- **Daemon connector secrets:** `BurnBarConnectorKeychainSecretStore.swift` uses the same patterns for daemon-managed connector credentials.

### Settings Secret Persistence
- **Migration from UserDefaults:** `SettingsSecretPersistence.load()` migrates legacy secrets stored in `UserDefaults` into Keychain and then deletes them from defaults. **Critical and well-implemented.**
- **Empty string handling:** Setting a secret to empty string deletes it from Keychain. **Correct.**

### Database Encryption Key
- **Storage:** `DatabaseEncryptionService.getOrCreateKey()` stores the SQLCipher key in Keychain with `kSecAttrAccessibleAfterFirstUnlock` (weaker than `WhenUnlockedThisDeviceOnly`, but necessary for background/daemon access).
- **Recovery file:** If the Keychain entry is lost, the key is recovered from `~/Library/Application Support/OpenBurnBar/.encryption-key-recovery` with `0o600` permissions and a SHA-256 integrity check.
- **Risk:** The recovery file negates much of the Keychain's security benefit. Any process with user-level filesystem access can read the recovery file and decrypt the database. **This is a material weakness.** Recommendation: remove the recovery file and require the user to re-create the database if the Keychain is lost, or protect the recovery file with a user-supplied password.

### Hardcoded Secrets Audit
- **Result:** No hardcoded API keys, passwords, or credentials were found in Swift source, plist, or JSON files.
- **Environment variable reads:** The codebase reads provider API keys from environment variables (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, etc.) for optional quota polling. This is documented behavior and the keys are never logged or persisted.

**Verdict:** Secrets management is generally strong. The encryption key recovery file is the most significant weakness.

---

## 4. Input Validation Findings

### Parsers
- **ClaudeCodeParser.swift:** Parses `jsonl` files with `JSONSerialization`. It uses defensive type casting (`as? [String: Any]`, `as? String`) and skips malformed lines. `seenUsageKeys` deduplicates usage entries. No path traversal vulnerability — it only reads from the configured provider log directory.
- **FactoryDroidParser.swift:** Similar defensive parsing. Settings/metadata JSON is read with `try? Data(contentsOf:)` and `try? JSONSerialization`, so malformed files are skipped silently.
- **Project name decoding:** `decodeProjectName` reconstructs paths from directory names. It does not execute or evaluate the decoded strings. **No code injection risk.**

### Search / SQL Queries
- **GRDB parameterized queries:** The vast majority of SQL uses GRDB's parameterized query API (`sql:arguments:`) with `StatementArguments`.
- **Unsafe SQL in migrations:** Migration `v13_backfill_claude_usage_timestamps` contains a hardcoded `token_usage.provider = 'Claude Code'` string inside `db.execute(sql:)`. This is a migration (not user-input) and is low risk.

### Daemon RPC
- **Request size cap:** `maxRequestBytes = 64 * 1024` for socket RPC; `maxBodyBytes = 1 * 1024 * 1024` and `maxHeaderBytes = 16 * 1024` for HTTP gateway.
- **Method enumeration:** RPC methods are dispatched via a `switch` on `BurnBarRPCMethod(rawValue:)`. Unknown methods return `methodNotFound`. **No dynamic dispatch.**
- **JSON deserialization:** Uses `JSONDecoder` with typed `Codable` structs. Malformed payloads throw `DecodingError` and return `invalidParams`.

### CORS
- `isAllowedCORSOrigin` restricts `Access-Control-Allow-Origin` to `localhost`, `127.0.0.1`, and `::1`. Wildcards and external origins are rejected. **Good.**

**Verdict:** Input validation is solid. No injection vectors were identified in the parsers or RPC layer.

---

## 5. Network Security Assessment

### Outbound Connections
- All provider API calls use HTTPS URLs (e.g., `https://api.anthropic.com`, `https://api.openai.com`).
- **No certificate pinning:** The app relies on the system's TLS certificate chain. There is no custom `URLSessionDelegate` or pinning logic. In a high-security threat model, a compromised CA could MITM provider API calls. **Recommendation:** Evaluate pinning for at least the most sensitive provider endpoints if the threat model includes network-level adversaries.
- **Local HTTP endpoints:** Hermes (`http://localhost:8642`) and OpenClaw (`http://127.0.0.1:18789`) use plain HTTP. This is acceptable for localhost-only services.
- **Cursor Connector Tunnel:** Cloudflare quick tunnel exposes the local router on a public HTTPS URL. Provider API keys remain in Keychain; only a short-lived session token is written to disk. This is opt-in and documented.

### Daemon HTTP Gateway
- **Binding:** Defaults to `127.0.0.1:8317`. Non-loopback binds require an `authToken`.
- **No TLS:** The gateway uses raw TCP via `NWListener`. Even for non-loopback binds, there is no TLS. Bearer tokens and request payloads travel in plaintext over the local network. **This is a material risk if a user configures a non-loopback bind.**
- **Rate limiting:** `BurnBarRateLimiter` is applied per client key (bearer token or "anonymous").
- **Validation:** `BurnBarGatewayConfiguration.validationError` rejects wildcard binds (`0.0.0.0`, `::`).

### Daemon UNIX Socket
- **Filesystem permissions:** The socket parent directory is created with `0o700`.
- **Auth token required:** As noted above, every RPC requires a token.
- **Peer PID:** `LOCAL_PEERPID` is used to identify the connecting process.

**Verdict:** The network surface is well-contained for a local utility. The lack of TLS on the HTTP gateway (even for non-loopback) is the primary gap.

---

## 6. Data Privacy and Storage Security

### Local Database
- **Default:** Standard SQLite via GRDB at `~/Library/Application Support/OpenBurnBar/OpenBurnBar.sqlite`.
- **Optional encryption:** SQLCipher with `PRAGMA key` when enabled. The app checks `PRAGMA cipher_version` to refuse silent plaintext fallback.
- **WAL mode:** `DatabasePool` enables WAL for concurrent reads. The SQLite file and `-wal`/`-shm` siblings are in the user's support directory.
- **Backup:** `OpenBurnBarDatabase.createBackupIfNeeded()` creates timestamped backups before migrations and prunes to 5 copies. **Good.**

### Cloud Sync
- **Scope:** Usage rows, conversation metadata (no full text unless session log backup is enabled), chat threads (capped to 4000 chars per message), and shared artifacts.
- **Privacy note:** Synced data can include project directory names, model names, and (if enabled) full session logs with prompts/code.
- **Cross-device resume:** Chat threads are uploaded with message content truncated to 4000 characters.
- **Lazy body download:** Full session log bodies are downloaded only for newly synced conversations and limited to 20 per sync.

### Keychain Recovery File
- As noted in §3, the `.encryption-key-recovery` file undermines the encryption model. An attacker with user-level filesystem access can decrypt the database without touching the Keychain.

### Entitlements / Sandbox
- **Sandbox:** `com.apple.security.app-sandbox` is `false`. This is **intentional and documented** — the app needs to read AI agent logs from arbitrary home-directory paths. The app is distributed via Developer ID (not App Store), so Gatekeeper + notarization provide the security boundary.
- **Keychain access groups:** `$(AppIdentifierPrefix)com.openburnbar.app` is declared for Firebase Auth compatibility.
- **iCloud:** `iCloud.com.openburnbar.app` container for document mirroring.
- **Apple Sign In:** `com.apple.developer.applesignin` is declared.

### Credential Exposure Scanning
- `DataStore+SearchAccess.swift` includes `scanConversationFullTextForCredentialExposure`, which scans conversation transcripts for regex patterns matching API keys, tokens, and passwords. This is a **strong privacy feature** that helps users detect accidental credential leaks in their own logs.

**Verdict:** Data storage architecture is reasonable for the threat model. The encryption key recovery file and lack of sandbox are the main privacy concerns.

---

## 7. Dependency Risk Assessment

| Dependency | Source | Risk | Notes |
|---|---|---|---|
| Firebase SDK (Auth, Firestore, AppCheck) | Google (SPM) | Low | Standard, well-maintained. App Check provides attestation. |
| GoogleSignIn | Google (SPM) | Low | Standard OAuth library. |
| GRDB / GRDB-SQLCipher | Community (SPM) | Low | `SahebRoy92/GRDB-SQLCipher` exact pin `6.29.3`. SQLCipher is dual-licensed (Zetetic). |
| Sentry Cocoa | getsentry/sentry-cocoa (SPM) | Low | Crash reporting only, DSN from Info.plist, opt-in by presence of key. |
| Network.framework | Apple | Low | Native framework, used for TCP gateway. |
| SwiftUI / AppKit | Apple | Low | Native frameworks. |

- **No vendored binary dependencies** were found beyond the Firebase and GoogleSignIn SDKs.
- **Exact version pinning** is used for GRDB-SQLCipher. Other packages use `from:` which allows minor updates. **Recommendation:** Pin all production dependencies to exact versions for reproducible builds.

---

## 8. Material Risks That Could Block Launch or Diligence

### 🔴 High
| # | Risk | Evidence | Mitigation |
|---|---|---|---|
| 1 | **Encryption key recovery file defeats SQLCipher** | `~/Library/Application Support/OpenBurnBar/.encryption-key-recovery` with `0o600` and SHA-256 check. File is on same filesystem as database. | Remove recovery file; require user to re-create DB on Keychain loss, or encrypt recovery file with a user password. |
| 2 | **HTTP gateway lacks TLS even for non-loopback binds** | `BurnBarHTTPGatewayServer.swift` uses raw `NWListener` TCP. `authToken` is sent in plaintext `Authorization: Bearer` header. | Add TLS (e.g., self-signed cert or TLS via Network.framework) for non-loopback binds, or restrict to loopback only and document the risk. |
| 3 | **App Check enforcement is not programmatically verified** | `firestore.rules` comment warns console enforcement is required, but code does not verify it. | Add a startup check that verifies App Check is being enforced (e.g., probe with a dummy request from a non-attested client). |

### 🟡 Medium
| # | Risk | Evidence | Mitigation |
|---|---|---|---|
| 4 | **SQLCipher key string interpolation** | `DatabaseEncryptionService.swift`: `try db.execute(sql: "PRAGMA key = '\(key)'")` — if key contained `'`, it would break/escape. Key is base64 so low probability, but still unsafe. | Use GRDB's parameterized execution or properly escape the key. |
| 5 | **No certificate pinning for provider APIs** | All `URLSession` usage is default configuration. | Evaluate pinning for critical provider endpoints. |
| 6 | **Daemon auth token in launchd plist readable by same user** | `~/Library/LaunchAgents/` is `0o755`. Plist is `0o600`, but same user can read it. | Acceptable for single-user model, but document that any process running as the same user can access the token. |
| 7 | **Cloudflare tunnel exposes local router publicly** | Cursor connector tunnel is opt-in but exposes the local OpenAI-compatible router. | Ensure the tunnel session token is short-lived and the UI warns users that prompts are routed through Cloudflare. |

### 🟢 Low / Informational
| # | Risk | Evidence |
|---|---|---|
| 8 | **Sandbox disabled** | `OpenBurnBar.entitlements`: `com.apple.security.app-sandbox = false`. Documented justification is valid (Developer ID distribution, arbitrary filesystem access). |
| 9 | **Sentry user ID derived from bundle ID + username** | `AgentLensApp.swift`: `vendorSeed = (bundleID + NSFullUserName()).data(using: .utf8)`. Not PII by itself, but username is included in the hash seed. |
| 10 | **Conversation metadata synced without full text** | By design, but project names and inferred task titles are still exposed in Firestore. |

---

## 9. Verdict on Security Readiness

**Verdict: CONDITIONALLY READY for beta / early access. NOT READY for 1.0 GA without remediation.**

OpenBurnBar demonstrates thoughtful security engineering for a local macOS utility. The architecture correctly treats the user's Mac as a single-user trusted environment, uses Keychain for secrets, enforces auth on daemon surfaces, and scopes cloud data to the authenticated owner. The threat model is well-documented and honest about residual risks.

### Must-Fix Before 1.0 GA
1. **Remove or harden the encryption key recovery file.** The current design provides a false sense of security.
2. **Add TLS to the daemon HTTP gateway for non-loopback binds**, or enforce loopback-only binding and document the limitation.
3. **Fix SQLCipher key string interpolation** to use safe query construction.
4. **Programmatically verify App Check enforcement** at startup (or fail closed if Firestore is enabled but App Check is not enforced).

### Should-Fix Before 1.0 GA
5. Evaluate certificate pinning for provider API endpoints.
6. Pin all SPM dependencies to exact versions.
7. Add a UI warning when the Cloudflare tunnel is active, clarifying that traffic passes through Cloudflare's infrastructure.

---

## Files Examined

- `SECURITY.md`
- `firestore.rules`
- `docs/THREAT_MODEL.md`
- `AgentLens/Resources/OpenBurnBar.entitlements`
- `AgentLens/Resources/OpenBurnBarRelease.entitlements`
- `AgentLens/Resources/GoogleService-Info.plist.example`
- `AgentLens/App/AgentLensApp.swift`
- `AgentLens/Services/AccountManager.swift`
- `AgentLens/Services/SettingsManager.swift`
- `AgentLens/Services/OpenBurnBarAppCheckProviderFactory.swift`
- `AgentLens/Services/CursorConnector/KeychainStore.swift`
- `AgentLens/Services/Settings/SettingsSecretPersistence.swift`
- `AgentLens/Services/DataStore/DatabaseEncryptionService.swift`
- `AgentLens/Services/DataStore/DataStoreCoordinator.swift`
- `AgentLens/Services/DataStore/OpenBurnBarDatabase.swift`
- `AgentLens/Services/DataStore/DataStore+SearchAccess.swift`
- `AgentLens/Services/LogParser/ClaudeCodeParser.swift`
- `AgentLens/Services/LogParser/FactoryDroidParser.swift`
- `AgentLens/Services/CloudSyncService.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/SecKeychainInteractionGate.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarHTTPGatewayServer.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonConfiguration.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarConnectorSecretStore.swift`
- Plus 40+ additional files via targeted grep for secrets, TLS, SQL, and GRDB usage.
