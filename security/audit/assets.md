# Asset and Data Inventory

## Critical Assets

### ASSET-001: CloudVault Encryption Key
- **Description:** Per-user AES-256 key used to seal session content before cloud upload
- **Location at rest:** macOS Keychain (`WhenUnlockedThisDeviceOnly`), per-device per-uid
- **Location in transit:** Never transmitted (client-side encryption only)
- **Confidentiality:** Critical - compromise exposes all user's session content
- **Integrity:** Critical - rotation requires survivor quorum
- **Retention:** Until user-initiated rotation or account deletion
- **Deletion:** Keychain entry deletion on account revocation
- **Backup:** Wrapped to trusted escrow devices via CloudVault rotation
- **Access paths:** `MacCloudVaultKeyAccess`, `CloudVaultCrypto.sealBlob/sealText`
- **Existing controls:** Keychain WhenUnlockedThisDeviceOnly, server never sees key, rotation enforced via server-monitored monotonic generation
- **Gaps:** First-vault creation not server-mediated (M-008); no survivor quorum for rotation
- **Evidence:** `OpenBurnBarCore/Sources/OpenBurnBarCore/CloudVaultKeyAccess.swift`, `CloudVaultCrypto.swift`

### ASSET-002: Session Content (Prompts, Outputs, Commands)
- **Description:** AI agent conversation text, tool calls, file references
- **Location at rest:** Local SQLCipher DB (daemon), Cloud Firestore (encrypted blobs), Cloud Storage (encrypted)
- **Location in transit:** TLS for cloud upload, app-level AEAD encryption
- **Confidentiality:** Critical - contains user's work, code, project details
- **Retention:** User-controlled; deleted on account erase
- **Deletion:** `accountDeletion.ts` recursive subtree + Storage purge
- **Access paths:** Local DB, CloudVault read/write, search via keyed HMAC
- **Existing controls:** AES-256-GCM with path-bound AAD, vault key device-held, legacy plaintext scrubbed
- **Gaps:** Cloud Storage purge best-effort on partial failure
- **Evidence:** `SessionLogSyncService.swift`, `firestore.rules`

### ASSET-003: Provider API Credentials
- **Description:** User's API keys for Anthropic, OpenAI, Google, etc.
- **Location at rest:** macOS Keychain (device-local), Google Secret Manager (server-side for hosted quota)
- **Confidentiality:** Critical - direct financial exposure
- **Retention:** Until user disconnects account
- **Deletion:** KMS `destroyCredential` on account deletion
- **Access paths:** Keychain (local), Cloud Functions (hosted quota refresh)
- **Existing controls:** Keychain WhenUnlockedThisDeviceOnly, KMS encryption, callable gated
- **Gaps:** None identified
- **Evidence:** `functions/src/callables/providerAccounts.ts`, `functions/src/accountDeletion.ts`

### ASSET-004: Firebase Auth Token / Session
- **Description:** Firebase ID token for authenticated API access
- **Location at rest:** In-memory (client), not persisted to disk
- **Location in transit:** HTTPS Authorization header
- **Confidentiality:** High - allows authenticated API access
- **Retention:** Firebase-managed TTL (1 hour), refresh token managed by SDK
- **Existing controls:** Firebase Auth SDK, App Check attestation binding
- **Evidence:** `functions/src/auth.ts`

### ASSET-005: Computer Use Audit Chain
- **Description:** SHA-256 linked log of all agent actions during Computer Use sessions
- **Location at rest:** Local filesystem, signed terminal head (Ed25519)
- **Integrity:** Critical - tamper evidence for agent accountability
- **Existing controls:** Content-addressed chain, signed head finalizer, validation requiring signed head
- **Gaps:** `head.json` vs `signed_head.json` dual naming could cause confusion
- **Evidence:** `ComputerUseAuditChain.swift`, `ComputerUseAuditHeadFinalizer.swift`

### ASSET-006: Escrow Device Trust Chain
- **Description:** Signatures binding devices to the trusted root identity
- **Location at rest:** Firestore (public keys + signatures), macOS Keychain (private keys)
- **Integrity:** Critical - trust chain compromise enables rogue device admission
- **Existing controls:** Trust chain signature verification, fingerprint immutability, controller key pinning
- **Gaps:** First-vault creation not server-mediated
- **Evidence:** `callables/computerUseSecurity.ts`, `escrowDeviceTrustChainSignature.test.ts`

### ASSET-007: Daemon Database (SQLCipher)
- **Description:** Local search index, cached session data, conversation snippets
- **Location at rest:** App support directory, SQLCipher encrypted
- **Confidentiality:** High - contains conversation content
- **Existing controls:** SQLCipher with fail-closed `cipher_version` self-check, Keychain-stored key
- **Gaps:** None identified
- **Evidence:** `BurnBarDaemonDatabaseCipher.swift`, `DatabaseEncryptionService.swift`

### ASSET-008: Capability Tokens
- **Description:** Ed25519-signed tokens authorizing privileged input actions
- **Location at rest:** In-memory (transient), nonce ledger on disk
- **Integrity:** Critical - forged tokens enable unauthorized HID input
- **Existing controls:** Token binding (escrow, attestation, scope), single-use nonce, offline verification, TTL
- **Gaps:** None critical after M-028 fix
- **Evidence:** `CapabilityToken.swift`, `CapabilityTokenVerifier.swift`, `VirtualHIDBridgeCapabilityGate.swift`

### ASSET-009: Payment Data
- **Description:** Stripe customer ID, subscription state, App Store transaction IDs
- **Location at rest:** Firestore (entitlement docs), Stripe (customer records)
- **Confidentiality:** Medium - transaction IDs and product IDs
- **Existing controls:** Webhook signature verification, entitlement binding, callable-gated
- **Gaps:** None identified
- **Evidence:** `callables/stripe.ts`, `appstore/`

### ASSET-010: User PII (Email, Display Name)
- **Description:** Email from Firebase Auth, optional display name
- **Location at rest:** Firebase Auth, Firestore user profile
- **Confidentiality:** Medium
- **Existing controls:** Email scrubbed from all logs, UID hashed in Sentry, avatar owner-only read
- **Gaps:** None identified
- **Evidence:** `functions/src/logging.ts`, `storage.rules`

### ASSET-011: Push Notification Tokens
- **Description:** APNs device token, FCM registration token
- **Location at rest:** Firestore device docs (TTL-bounded)
- **Confidentiality:** Low - routing identifiers, not content
- **Retention:** 15-min TTL on outbound queue docs
- **Deletion:** Swept on account deletion + TTL
- **Existing controls:** Callable-gated writes (not direct), invalidated on delivery failure
- **Evidence:** `callables/voipPush.ts`, `devicePushRegistration.test.ts`
