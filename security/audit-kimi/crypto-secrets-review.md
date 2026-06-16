# Cryptography and Secrets Review

## A.6.1 Cryptographic Design

### Cloud Vault / Signal-libsignal Sealing

- Uses Signal protocol double-ratchet / sealed-sender-style envelopes.
- Per-device identity keys stored in keychain/keystore.
- Prekeys published to `signalPrekeyDirectory` callable.
- Envelope format defined in `packages/signal-envelope-contracts/`.
- **E2EE claim**: server stores sealed bytes; cannot decrypt without recipient key.

### HPKE + AES-GCM

- Used for some escrow and audit-chain payloads.
- P-256 KEM + AES-GCM-256 + HKDF.
- Implementation in `OpenBurnBarCore/Sources/OpenBurnBarCore/Crypto/`.

### Local SQLCipher

- `AgentLens/Services/DatabaseEncryptionService.swift` manages a per-database key.
- Key derived from device keychain.
- However, the **GRDB-SQLCipher integration is not enabled** in the current build; plaintext SQLite is used.
- `docs/THREAT_MODEL.md` explicitly states SQLCipher is not yet vendored.

**Finding**: FINDING-001 — plaintext local DB.

### Key Storage

| Key | Storage | Notes |
|---|---|---|
| Cloud Vault private key | iOS Keychain / Android Keystore / macOS keychain | Protected by OS |
| SQLCipher key | macOS keychain (when enabled) | Key exists; codec missing |
| iroh node private key | iOS keychain; Android cached in shared prefs (encrypted?) | See FINDING-014 |
| Firebase Auth token | Firebase SDK | Memory mostly |
| Daemon auth token | User defaults / keychain | Single long-lived token |
| Apple App Store JWS verify key | Hard-coded pinned roots + Apple fetch | Good practice |

## A.6.2 Secrets Management

### Repository

- `gitleaks` scan found 973 findings, mostly skill/test references, hard-coded test keys, and placeholder values.
- No production API keys or certificates committed.
- `.gitleaks.toml` and `.secrets.baseline` are maintained.

### CI/CD

- Secrets injected via GitHub Actions environment variables.
- iOS: `FIREBASE_PLIST_BASE64`, `MATCH_PASSWORD`, `APPLE_API_KEY`, `CODESIGNING_CERTIFICATES_P12`.
- Android: `GOOGLE_SERVICES_JSON_BASE64`, `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`.
- Release workflow uses cosign key for attestations.

### Runtime

- Cloud Functions use default credentials; no external secret manager (e.g., Secret Manager) visible.
- Stripe keys likely from Firebase config/env.

## A.6.3 Protocols

| Protocol | Use | Assessment |
|---|---|---|
| TLS 1.3 | Firebase, Apple, Stripe | Standard |
| iroh QUIC | Phone sync / Computer Use | Authenticated by node IDs; encrypted |
| Signal Double Ratchet | Cloud Vault sealing | Mature; implementation must be correct |
| JSON-RPC over UNIX socket | App ↔ Daemon | Same-user; single token |
| WebSocket | Legacy relay (being retired) | Deprecated |

## A.6.4 Cryptographic Gaps

1. **Plaintext SQLite** — the most important local crypto control is missing.
2. **AAD coverage** — prior audit M-007 noted Cloud Vault AAD is partial; ensure all envelopes bind sender/recipient/scope.
3. **iroh key caching on Android** — M-006 noted the iroh secret key may be cached in shared preferences; verify encryption.
4. **Daemon auth token rotation** — UNKNOWN-005; no documented rotation.

## A.6.5 Prior Audit Items (Crypto)

| ID | Title | Status | Notes |
|---|---|---|---|
| M-006 | Android iroh cached key | Open | Verify Keystore usage |
| M-007 | CloudVault AAD partial | Partial | Audit all envelope call sites |
