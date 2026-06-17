# Crypto, Secrets, and Protocol Review

## Crypto Inventory

| Area | Algorithms/libraries | Key/nonce handling | Evidence | Confidence |
|---|---|---|---|---|
| Cloud Vault sealed text | AES-256-GCM, CryptoKit | random nonce, AAD context, key version | `CloudVaultCrypto.swift:31-82,115-141,470-486` | high |
| Cloud Vault blobs | AES-GCM envelope, integrity hash/HMAC fields | AAD and integrity validation | `CloudVaultCrypto.swift:143-175,523-668`, `validators.ts:297-341` | high |
| Signal envelope | Signal envelope type | additive, flag-gated, not default production writes | `CloudVaultCrypto.swift:202-223` | medium |
| Local SQLCipher | SQLCipher key in Keychain | 32 byte random key, recovery bundle AES-GCM/PBKDF2 | `DatabaseEncryptionService.swift:11-57,95-190` | medium |
| Keychain secrets | Apple Keychain | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | `KeychainStore.swift:87-188`, `vaultStore.ts:1-68` | high |
| Hosted MCP tokens | Ed25519 or legacy HMAC | 15 minute access, refresh hash rotation | `hosted-mcp/src/auth.ts:82-187`, `oauthToken.ts:106-171` | high |
| Webhooks | Stripe signature, GitHub HMAC | raw-body verification and timing-safe compare | `stripe.ts:536-575`, `knowledgeSync.ts:140-207` | high |
| Computer Use audit | SHA-256 chain | canonical JSON and strict head option | `ComputerUseAuditChain.swift:81-180` | high |
| Daemon token compare | constant-time equality | padded fixed-time compare | `ConstantTimeCompare.swift:3-26` | high |

## Secret Lifecycle

| Secret | Stored where | Rotation/revocation | Logged? | Gaps |
|---|---|---|---|---|
| Firebase Auth tokens | platform auth store/Keychain | Firebase-managed | scrubbed | revocation UX not fully reviewed |
| Cloud Vault key | Keychain/local shim Keychain | unclear/manual | not intended | rotation runbook unknown |
| SQLCipher key | Keychain | recovery/import paths | error logs only | fail-open persistence path |
| Provider/API secrets | Keychain or server secret refs | provider-specific | scrubbed | production admin access unknown |
| Hosted MCP access token | client/local shim memory | 15 minute expiry | redacted/hashes | residual replay window |
| Hosted MCP refresh token | local shim Keychain, hash in Firestore | rotate on refresh, revoke grant/client | hash only | signer rotation runbook unknown |
| Daemon socket token | token file/local config | manual | not intended | rotation UX unknown |
| Stripe secrets | Firebase params/secrets | Stripe/Firebase | not intended | secret access review unknown |
| Deploy secrets | GitHub environment/secrets | manual | masked | long-lived fallback paths |

## Red Flags

| Red flag | Result |
|---|---|
| Hardcoded production secrets in reviewed evidence | not found |
| Static IV/nonce in Cloud Vault | not found |
| Encryption without authentication | not found for Cloud Vault |
| Disabled TLS verification | not found; remote shim requires trusted HTTPS or loopback |
| Replayable critical payloads | controlled in high-risk nonce, passkey challenge, local-auth proof ledger |
| Downgrade-prone protocol | partial; Signal envelope flag-off requires claim discipline |
| Catch-and-ignore crypto/key failure | found in SQLCipher key persistence path |

## Protocol Claims

Cloud Vault: AES-GCM with AAD is defensible; universal Signal-quality E2EE is not.

Remote MCP: scoped token and local decryption design is defensible for reviewed paths.

Daemon Computer Use proof: verifier protocol is reasonable when wired, but production executable currently passes nil.

