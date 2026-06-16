# Cryptography, Secrets, and Protocols Review

## G.1 Crypto Inventory

| Algorithm | Mode | Use | Library | Key Size | Nonce | Evidence |
|-----------|------|-----|---------|----------|-------|----------|
| AES-256-GCM | AEAD | CloudVault sealed payloads | CryptoKit | 256-bit | Random per seal | `CloudVaultCrypto.swift` |
| ChaChaPoly | AEAD (via HPKE) | Signal at-rest envelope | CryptoKit/libsignal | 256-bit | HPKE managed | `SignalAtRestSealer.swift` |
| P-256 (ECDH) | Key agreement | CloudVault key wrapping | CryptoKit | 256-bit | N/A (cofactor 1) | `CloudVaultKeyAccess.swift` |
| Ed25519 | Signatures | Capability tokens, audit head, device identity | CryptoKit | 256-bit | N/A | `CapabilityToken.swift` |
| SHA-256 | Hashing | Audit chain, attestation digest | CryptoKit | N/A | N/A | `ComputerUseAuditChain.swift` |
| HKDF | KDF | Deriving search hash keys | CryptoKit | N/A | N/A | `CloudVaultCrypto.swift` |
| PBKDF2-HMAC-SHA256 | Password KDF | Recovery bundle | CryptoKit | N/A | N/A | `DatabaseEncryptionService.swift` |
| SQLCipher | AEAD | Daemon DB at rest | SQLCipher | 256-bit | Managed | `BurnBarDaemonDatabaseCipher.swift` |

**Verdict:** All encryption is AEAD. No ECB, no unauthenticated CBC. P-256 (cofactor 1) eliminates small-order point attacks.

## G.2 Key and Secret Lifecycle

### CloudVault Vault Key
- **Generated:** Client-side via `SecRandomCopyBytes`
- **Stored:** Keychain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- **Rotated:** Client-driven, server-enforced monotonic generation. Server coordinates rotation job but never receives keys.
- **Revoked:** Survivor-side rotation + rewrap + envelope reseal + blob reseal + search index rekey
- **Backup:** Wrapped to trusted escrow devices via P-256 key agreement
- **Logged:** Never
- **Exposed to client:** Intentionally (it's the client's key)
- **Hardcoded:** No
- **Blast radius if compromised:** All user's session content
- **Gaps:** First-vault creation not server-mediated; no survivor quorum (FINDING-004)

### Daemon SQLCipher Key
- **Generated:** `SecRandomCopyBytes`, stored in Keychain
- **Backup:** Optional recovery bundle (`exportRecoveryBundle` — PBKDF2 + AES-GCM)
- **Gaps:** None

### Provider API Credentials (Hosted)
- **Stored:** Google Secret Manager (versioned)
- **Encrypted:** Cloud KMS (`credential-encryption-key`)
- **Destroyed:** KMS `destroyCredential` on account deletion
- **Gaps:** None

### Ed25519 Device Identity Keys
- **Generated:** Per-device, client-side
- **Stored:** Keychain (private), Firestore (public)
- **Pinned:** Controller key pin in Keychain (scoped to account); refuses relay/Firestore key swaps
- **Gaps:** First-contact safety-number not default-on (FINDING-005)

### Daemon Socket Auth Token
- **Generated:** Random, passed via launchd `EnvironmentVariables`
- **Stored:** Plist with `0600` permissions
- **Stripped from children:** Yes, via `OpenBurnBarSwitcherShell.sanitizedChildEnvironment`
- **Gaps:** None

### Stripe Webhook Secret
- **Stored:** GitHub Actions secret / Secret Manager
- **Used:** `stripe.webhooks.constructEvent(rawBody, signature, webhookSecret)`
- **Gaps:** None

## G.3 Crypto Red Flags Check

| Check | Result | Evidence |
|-------|--------|----------|
| Hardcoded secrets | **None found** | Gitleaks + detect-secrets + trufflehog; all allowlists are test fixtures |
| Committed private keys | **None found** | `detect-private-key` pre-commit hook |
| Static IVs | **None** | CryptoKit generates random nonces per seal operation |
| Nonce reuse | **Not possible** | AEAD random nonce per operation |
| Encryption without auth | **None** | All encryption is AEAD (GCM or ChaChaPoly) |
| AES-CBC without MAC | **None** | No CBC mode used anywhere |
| Homegrown crypto | **None** | All crypto via CryptoKit or libsignal |
| Weak randomness | **None** | `SecRandomCopyBytes` throughout |
| Insecure password hashing | **None** | PBKDF2-HMAC-SHA256 for recovery bundles |
| Plaintext token storage | **None** | Keychain ThisDeviceOnly |
| Secrets in logs | **None** | Scrubbers remove tokens/keys/UIDs/paths |
| Disabled TLS verification | **None** | No `rejectUnauthorized: false` or similar |
| Certificate validation bypass | **None** | Not found |
| Replayable payloads | **Mitigated** | Nonce ledgers, monotonic counters, freshness windows |
| Downgrade-prone versioning | **None** | Schema versions enforced; legacy plaintext actively deleted |
| Catch-and-ignore crypto failures | **None** | SQLCipher fail-closed; CloudVault seal failures throw |

## G.4 Protocol Claims

### CloudVault E2E Encryption
- **Claim defensible:** YES for current writers (`conversations`, `mobile_assistant_chats`, `session_logs`)
- **Path-bound AAD:** `OpenBurnBar-CloudVault-aad-v2|uid|collection|docID|field|schemaVersion|field`
- **Server sees:** Ciphertext only, keyed HMAC hashes, metadata facets
- **Forward secrecy:** Not claimed (not applicable to symmetric AEAD)
- **Gap:** `chat_threads` and `cli_sessions` use global AAD (FINDING-008)

### iroh Device Pairing
- **Key agreement:** Ed25519 identity keys
- **Key continuity:** Pinning on all platforms (reject key change after first contact)
- **First contact:** Safety-number confirmation exists but not default-on (FINDING-005)
- **Replay resistance:** Monotonic counters + freshness windows for phone control

### Computer Use Audit Chain
- **Hash:** SHA-256 (BLAKE3 is long-term intent per comments)
- **Linking:** Each entry hash derived from canonical-JSON + parent hash
- **Terminal protection:** Ed25519-signed head; validation fails closed if missing
- **Tamper detection:** Covers every entry including terminal when head.json supplied
