# Asset and Data Inventory

## Critical Assets

### ASSET-001: CloudVault Encryption Key
- **Description:** Per-user AES-256 key used to seal session content before cloud upload
- **Location at rest:** macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), per-device per-uid
- **Location in transit:** Never transmitted (client-side encryption only)
- **Confidentiality:** Critical
- **Integrity:** Critical (rotation requires survivor rewrap)
- **Retention:** Until user-initiated rotation or account deletion
- **Deletion:** Keychain entry deletion on account revocation
- **Backup:** Wrapped to trusted escrow devices via CloudVault rotation
- **Access paths:** `MacCloudVaultKeyAccess.keyForWriting/Reading`, `CloudVaultCrypto.sealBlob/sealText`
- **Existing controls:** Keychain ThisDeviceOnly, server zero-access, monotonic generation, path-bound AAD on current writers
- **Gaps:** First-vault creation not server-mediated (FINDING-004); no survivor quorum (FINDING-004)
- **Evidence:** `CloudVaultKeyAccess.swift`, `CloudVaultCrypto.swift`, `firestore.rules:validPathBoundSealedPayloadForUser`

### ASSET-002: Session Content (Prompts, Outputs, Commands)
- **Description:** AI agent conversation text, tool calls, file references
- **Location at rest:** Local SQLCipher DB (daemon), Cloud Firestore (encrypted manifests), Cloud Storage (encrypted blobs)
- **Confidentiality:** Critical
- **Retention:** User-controlled; deleted on account erase
- **Deletion:** `accountDeletion.ts` recursive subtree + Storage purge + legacy plaintext scrub
- **Existing controls:** AES-256-GCM path-bound AAD, vault key device-held, keyed HMAC search, legacy plaintext deleted via `FieldValue.delete()`
- **Gaps:** `chat_threads`/`cli_sessions` use global AAD (FINDING-008); Storage purge best-effort (FINDING-013)
- **Evidence:** `SessionLogSyncService.swift`, `firestore.rules:validSessionLogManifestCore`

### ASSET-003: Provider API Credentials
- **Description:** User's API keys for Anthropic, OpenAI, Google, etc.
- **Location at rest:** macOS Keychain (device-local), Google Secret Manager (server-side for hosted quota)
- **Confidentiality:** Critical (direct financial exposure)
- **Deletion:** KMS `destroyCredential` on account deletion; Auth user deleted only if all secrets destroyed
- **Existing controls:** Keychain ThisDeviceOnly, Cloud KMS encryption, callable-gated
- **Gaps:** None identified
- **Evidence:** `callables/providerAccounts.ts`, `accountDeletion.ts`

### ASSET-004: Firebase Auth Token
- **Description:** Firebase ID token for authenticated API access
- **Location at rest:** In-memory (client SDK managed)
- **Retention:** ~1 hour, refresh managed by Firebase SDK
- **Existing controls:** App Check attestation binding for high-risk ops
- **Evidence:** `auth.ts`, `appCheckAttestation.ts`

### ASSET-005: Computer Use Audit Chain
- **Description:** SHA-256-linked log of all agent actions
- **Location at rest:** Local filesystem; signed terminal head (Ed25519)
- **Integrity:** Critical
- **Existing controls:** Content-addressed chain, signed head finalizer, fail-closed validation requiring signed head
- **Gaps:** Dual-file naming (`head.json` vs `signed_head.json`) could cause dispute confusion (FINDING-014)
- **Evidence:** `ComputerUseAuditChain.swift`, `ComputerUseAuditHeadFinalizer.swift`

### ASSET-006: Escrow Device Trust Chain
- **Description:** Ed25519 signatures binding devices to trusted root identity
- **Integrity:** Critical
- **Existing controls:** Trust chain signature verification, fingerprint immutability, controller key pinning (Keychain)
- **Gaps:** First-vault creation not server-mediated (FINDING-004)
- **Evidence:** `callables/computerUseSecurity.ts`, `escrowDeviceTrustChainSignature.test.ts`

### ASSET-007: Daemon Database (SQLCipher)
- **Description:** Local search index, cached session data, conversation snippets
- **Confidentiality:** High
- **Existing controls:** SQLCipher with fail-closed `cipher_version` self-check, Keychain key
- **Gaps:** None identified
- **Evidence:** `BurnBarDaemonDatabaseCipher.swift`, `DatabaseEncryptionService.swift`

### ASSET-008: Capability Tokens
- **Description:** Ed25519-signed tokens authorizing privileged input actions
- **Integrity:** Critical
- **Existing controls:** Token binding (escrow, attestation, scope), single-use nonce ledger (file-backed), offline verification, TTL
- **Gaps:** None critical (M-028 fixed)
- **Evidence:** `CapabilityToken.swift`, `VirtualHIDBridgeCapabilityGate.swift`

### ASSET-009: Privileged Input Kill Switch
- **Description:** File-existence flag at `/var/run/openburnbar-privileged-input-kill` that halts all HID dispatch
- **Integrity:** Critical — must not be disarmable by attacker
- **Existing controls:** Checked before every dispatch at two layers; file readable by all (so crashed app leaves flag)
- **Gaps:** Watchdog socket has no peer auth — root can clear it (FINDING-001)
- **Evidence:** `PrivilegedInputKillSwitch.swift`, `PrivilegedInputKillSwitchWatchdogMain.swift`

### ASSET-010: Daemon Socket Auth Token
- **Description:** Bearer token for daemon Unix socket authentication
- **Location at rest:** launchd `EnvironmentVariables` (not CLI args), plist 0600
- **Existing controls:** Constant-time comparison, env stripping for child processes, peer codesig gate
- **Gaps:** None identified
- **Evidence:** `OpenBurnBarDaemonServer.swift`, `OpenBurnBarSwitcherShell.swift`

### ASSET-011: Payment Data
- **Description:** Stripe customer ID, subscription state, App Store transaction IDs
- **Existing controls:** Webhook signature verification, entitlement binding, idempotent processing
- **Gaps:** None identified
- **Evidence:** `callables/stripe.ts`, `appstore/`

### ASSET-012: User PII (Email, Display Name)
- **Existing controls:** Email scrubbed from logs, UID hashed in Sentry, avatar owner-only read
- **Gaps:** None identified
- **Evidence:** `logging.ts`, `storage.rules`

### ASSET-013: Push Notification Tokens
- **Description:** APNs device token, FCM registration token
- **Retention:** 15-min TTL on outbound queue docs
- **Deletion:** Swept on account deletion + TTL
- **Existing controls:** Callable-gated writes, invalidated on delivery failure
- **Gaps:** Stable routing IDs visible to APNs/FCM by design (FINDING-010)
- **Evidence:** `callables/voipPush.ts`, `firestore.indexes.json`
