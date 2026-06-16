# Cryptography, Secrets & Protocols Review — Opus 4.8 1M lane

Verdict: **Solid primitives, no homegrown content crypto in the hot path, no hardcoded secrets.** Headline "sealed before Firestore" claim **holds with narrowing**. Findings: OPUS-F-001 (collaboration plaintext, Medium), OPUS-F-003 (partial AAD), OPUS-F-004 (local DB plaintext, disclosed).

## G.1 Crypto inventory

| Use | Algorithm | Library | Key | Nonce/IV | Evidence | Note |
|---|---|---|---|---|---|---|
| CloudVault at-rest seal (prod, the 6 named types + session_logs) | AES-256-GCM | Apple CryptoKit | 256-bit | random 96-bit | `OpenBurnBarCore/.../CloudVaultCrypto.swift:470,498,605,618` | AAD binds uid\|collection\|docID\|field\|schemaVer\|purpose |
| Device escrow key-wrap | ECIES P-256 + HKDF-SHA256 + AES-256-GCM | CryptoKit | P-256/256-bit | fresh ephemeral/random | `CloudVaultCrypto.swift:1008-1046` | labeled `ECIES-P256-AESGCM` |
| Trusted-device chain signature | libsignal identity sign/verify | LibSignalClient | P-256 | n/a | `CloudVaultTrustedDeviceChainVerifier.swift:181-199` | fingerprint re-bound |
| Backend credential storage | KMS envelope: AES-256-GCM DEK + KMS-wrapped DEK | Node `crypto` + Google KMS | 256-bit DEK | `randomBytes(12)` + 16B tag | `functions/src/secrets.ts:103-122` | Firestore stores only resource/version name |
| Gateway relay (phone↔AI) | P-256 HKDF AES-GCM (v2) / RFC9180 HPKE-Auth (v3) / homegrown Double Ratchet | bespoke `gateway/crypto/` | P-256/256-bit | per-message | `functions/src/hermesGatewayEnvelope.ts:28-90` | gateway is **not** user-blind for routing — honestly disclosed |
| DB recovery bundle | PBKDF2-HMAC-SHA256 (100k) + AES-256-GCM | CommonCrypto + CryptoKit | 256-bit | random 16B salt | `DatabaseEncryptionService.swift:161-275` | passphrase-protected |
| Search trapdoors | HKDF-SHA256 → HMAC-SHA256 | CryptoKit | 256-bit | deterministic (SSE) | `CloudVaultCrypto.swift:812-890` | leaks equality/prefix by design |
| libsignal HPKE at-rest seal | X25519/HKDF/AES-256-GCM + Ed25519 sig | LibSignalClient (linked) | — | — | `OpenBurnBarSignalCore/SignalAtRestSealer.swift:67-193` | **wired but INERT** (registry scheme = `cloudvault-aesgcm-v2`, RemoteConfig default-off) |
| Local SQLite at-rest | none (plaintext) | stock libsqlite3 | — | — | `DataStoreCoordinator.swift:216-261` | OPUS-F-004 |
| Collaboration artifacts | none (plaintext) | — | — | — | `CollaborationSyncService.swift:1001-1003` | OPUS-F-001 |

## G.2 Key/secret lifecycle
- **CloudVault symmetric key (32B):** `SecRandomCopyBytes`; macOS Keychain; never plaintext to Firestore — only ECIES-wrapped to escrow devices (`CloudVaultKeyAccess.swift:399-418`).
- **Escrow / Signal identity keypairs:** Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, non-syncable; only public key + fingerprint leave the device.
- **Backend secrets:** Secret Manager (ciphertext) + KMS + IAM; no hardcoded secrets (targeted grep of `functions/src` = 0 hits). No `Math.random()` for crypto, no static/zero IVs, no AES-CBC, no disabled TLS verification across `functions/`, `AgentLens/`, `OpenBurnBarMobile/`.

## G.3 Red-flag sweep — clean
No committed private keys, no nonce reuse, no encrypt-without-authenticate, no homegrown primitive in the content path (the homegrown Double Ratchet is the **gateway** relay, which is honestly disclosed as not user-blind for routing). The libsignal device-to-device Double Ratchet package is explicitly `STATUS: inert / flag-off`.

## G.4 "Sealed before Firestore" claim — DEFENSIBLE WITH NARROWING
- **TRUE** for the six enumerated types + `session_logs`: every traced write path seals via `CloudVaultCrypto.sealText/sealPayload/sealBlob` (AES-256-GCM under a device-held key the server never holds); plaintext fields are `FieldValue.delete()`'d; session_logs rule now enforces an allowlist (M-005 fixed).
- **NOT** "Signal/libsignal-sealed": that path is linked but inert — map marketing to "AES-256-GCM / CryptoKit," not "Signal Protocol."
- **NOT extended** to collaboration/shared artifacts (OPUS-F-001, plaintext) or local at-rest DB (OPUS-F-004, plaintext).
- **AAD binding partial** (OPUS-F-003): enforced for `conversations`/`mobile_assistant_chats`/`session_logs`; other sealed surfaces still global-AAD → same-account ciphertext relocation.

## G.5 Policy/ADR vs implementation
`docs/security/ADR-001-crypto-architecture.md` + `crypto-architecture-policy.json` match the escrow / trusted-chain / gateway constructions and honestly flag the inert libsignal lanes. A CI gate (`scripts/ci/check_burnbar_crypto_architecture_policy.py`, `license-posture.yml:93`) fails the build on manifest drift or invariant violation (iOS libsignal-free, gateway = homegrown ratchet, claim mapping) — a genuine policy-enforcement control.
