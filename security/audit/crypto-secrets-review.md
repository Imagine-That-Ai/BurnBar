# Crypto, Secrets, and Protocol Review

## G.1 Crypto Inventory

| Area | Algorithms/libraries | Key/nonce handling | Evidence | Confidence |
|---|---|---|---|---|
| Cloud Vault sealed text | AES-256-GCM, CryptoKit | random nonce, AAD context, key version | `CloudVaultCrypto.swift:31-82,115-141,470-486` | high |
| Cloud Vault blobs | AES-GCM envelope, integrity hash/HMAC fields | AAD and integrity validation | `CloudVaultCrypto.swift:143-175,523-668`, `validators.ts:297-341` | high |
| Signal envelope | Signal envelope type, additive/flag-gated | not default production writes | `CloudVaultCrypto.swift:202-223` | medium |
| Local SQLCipher | SQLCipher key in Keychain | 32 byte random key, recovery bundle AES-GCM/PBKDF2 | `DatabaseEncryptionService.swift:11-57,95-190` | medium |
| Keychain secrets | Apple Keychain | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | `KeychainStore.swift:87-188`, `vaultStore.ts:1-68` | high |
| Hosted MCP tokens | Ed25519 or legacy HMAC, JWT-like signed token | 15 minute access, refresh hash rotation | `hosted-mcp/src/auth.ts:82-187`, `oauthToken.ts:106-171` | high |
| Remote MCP grants | random 32 byte secrets, SHA-256 hashes | refresh token hash, revoke paths | `remoteMcpGrant.ts:38-119` | high |
| Webhooks | Stripe signature, GitHub HMAC | raw-body verification and timing-safe compare | `stripe.ts:536-575`, `knowledgeSync.ts:140-207` | high |
| Computer Use audit | SHA-256 content-addressed chain | canonical JSON, strict expected head option | `ComputerUseAuditChain.swift:81-180` | high |
| Daemon token compare | constant-time equality | padded fixed-time compare | `ConstantTimeCompare.swift:3-26` | high |

## G.2 Key and Secret Lifecycle

| Secret | Generated where | Stored where | Rotated/revoked | Logged | Blast radius | Gaps |
|---|---|---|---|---|---|---|
| Firebase Auth tokens | Firebase SDK/Auth | platform auth store/Keychain | Firebase revocation/session behavior | should be scrubbed | account access | exact revocation UX not reviewed |
| Cloud Vault key | client/local shim | Keychain | unclear/manual | not intended | user encrypted data | key rotation procedure needs review |
| SQLCipher key | macOS app | Keychain | recovery/import paths | error logs only | local database | fail-open persistence path |
| Provider/API secrets | user/app | Keychain or server secret refs | provider-specific | scrubbed | provider account | production admin access unknown |
| Hosted MCP access token | Functions/service | client/local shim memory | 15 minute expiry | redacted/hashes | scoped MCP access | signer rotation runbook unknown |
| Hosted MCP refresh token | Functions | local shim Keychain, hash in Firestore | rotate on refresh, revoke grant/client | hash only | grant renewal | production key management unknown |
| Daemon socket token | daemon config/token file | token file/local process config | manual | not intended | local daemon RPC | rotation UX unknown |
| Stripe secret/webhook secret | Firebase params/secrets | Firebase config/secrets | Stripe/Firebase | not intended | billing control | secret access review unknown |
| GitHub deploy secrets | GitHub environment/secrets | GitHub | manual | masked | production deploy | long-lived fallback paths |

## G.3 Crypto Red Flags

| Red flag | Result | Evidence |
|---|---|---|
| Hardcoded production secrets in reviewed evidence | Not found | no production secret committed in inspected paths |
| Static IV/nonce in Cloud Vault | Not found | random nonce generation and envelope validation |
| Encryption without authentication | Not found for Cloud Vault | AES-GCM used |
| AES-CBC without MAC | Not found | search evidence favored AES-GCM |
| Weak randomness | Not found for key paths reviewed | `SecRandom`/random bytes used |
| Plaintext token storage | Partially controlled | Keychain for local; hashed refresh in server; unknown external secrets |
| Secrets in logs | Controls present | `logging.ts:16-153`, Sentry scrubbers |
| Disabled TLS verification | Not found | remote shim requires trusted HTTPS or loopback |
| Replayable critical payloads | Controlled in several flows | high-risk nonce, passkey challenge, local-auth proof ledger |
| Downgrade-prone protocol | Partial | Signal envelope flag-off requires claim discipline |
| Catch-and-ignore crypto/key failure | Found | SQLCipher key persistence failure logs and returns generated key |

## G.4 Protocol Claims

### Cloud Vault

Claim status: partially defensible.

Defensible: Cloud Vault sealed fields use AES-GCM and context-bound AAD where the envelope and validators require it.

Unsafe: universal Signal-quality E2EE or universal client-only readability.

Evidence:

- `CloudVaultCrypto.swift:31-82` binds AAD to uid, collection, document ID, field, schema version, and purpose.
- `validators.ts:226-259` rejects malformed sealed text and requires AAD for schema v2+.
- `CloudVaultCrypto.swift:202-223` states Signal envelope is additive and flag-off.

### Remote MCP

Claim status: defensible for scoped token and local decryption design.

Evidence:

- `hosted-mcp/src/config.ts:29-52` rejects unsafe production token posture.
- `hosted-mcp/src/auth.ts:152-187` verifies bearer tokens, audience, client ID, and expiry.
- `hosted-mcp/src/oauthToken.ts:106-171` verifies refresh token hash, revocation, entitlement, and rotates refresh token.
- `tools/openburnbar-mcp-remote/src/shim.ts:87-151` performs local query preparation/decryption.

### Daemon Computer Use Proof

Claim status: partially defensible.

The verifier protocol itself has strong elements: pinned key lookup, signature, intent binding, freshness, and single-use ledger. The production executable currently does not wire it, so the protocol cannot be credited as enforced on the production daemon path.

Evidence:

- `DaemonLocalAuthProofVerifier.swift:68-74,100-160`.
- `OpenBurnBarDaemonMain.swift:54-86`.

