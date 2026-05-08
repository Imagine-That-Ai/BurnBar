# OpenBurnBar Threat Model and Permission Model

This document describes the security boundaries, permissions, and trust model for the daemon, extension, and app surfaces.

## System Components and Trust Boundaries

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│  User's Mac  (single-user, all components run as the logged-in user)        │
│                                                                             │
│  ┌─────────────┐       UNIX socket (filesystem ACL)       ┌──────────────┐  │
│  │  macOS App   │◄────────────────────────────────────────►│  Daemon      │  │
│  │  (AgentLens) │       JSON-RPC, local only               │  (launchd)   │  │
│  └──────┬──────┘                                           └──────┬───────┘  │
│         │                                                         │          │
│         │  ┌────────────────────────┐                              │          │
│         ├──│  macOS Keychain        │◄─────── secrets ────────────┘          │
│         │  └────────────────────────┘                                        │
│         │                                                                    │
│         │  ┌────────────────────────┐                                        │
│         ├──│  Local SQLite (GRDB)   │  canonical; optional SQLCipher at rest  │
│         │  └────────────────────────┘                                        │
│         │                                                                    │
│         │  ┌────────────────────────┐    opt-in                              │
│         ├──│  Firebase (cloud)      │───────────► Firestore, Auth            │
│         │  └────────────────────────┘                                        │
│         │                                                                    │
│         │  ┌────────────────────────┐    opt-in                              │
│         └──│  iCloud Documents      │───────────► Apple iCloud               │
│            └────────────────────────┘                                        │
│                                                                              │
│  ┌─────────────────┐    UNIX socket (same as above)                          │
│  │  VS Code/Cursor  │◄── daemon RPC ──────────────────────┘                  │
│  │  Extension        │                                                       │
│  └─────────────────┘                                                         │
│                                                                              │
│  ┌─────────────────┐    opt-in, short-lived                                  │
│  │  Cloudflare      │◄── HTTPS tunnel for Cursor BYOK connector              │
│  │  quick tunnel    │                                                        │
│  └─────────────────┘                                                         │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Daemon

### What it is

A local JSON-RPC server listening on a UNIX domain socket at `~/Library/Application Support/OpenBurnBar/openburnbar-daemon.sock`.

### Permissions it needs

| Permission | Why |
|---|---|
| Filesystem read: `~/.claude/`, `~/.factory/`, `~/.codex/`, `~/.kimi/`, `~/.hermes/`, `~/.augment/`, `~/.forge/`, `~/.goose/`, `~/Library/Application Support/` | Reads AI agent session logs for usage parsing |
| Filesystem write: `~/Library/Application Support/OpenBurnBar/` | Stores daemon state, run journals, connector config, search index |
| UNIX socket listen | JSON-RPC IPC with app and extension |
| macOS Keychain read/write | Stores and retrieves provider API keys, connector credentials, bearer tokens |
| Network (outbound, opt-in only) | Provider API calls for routed models; connector test/sample requests to GitHub, Slack, Linear, PostHog, Sentry, Gmail APIs |

### What it cannot do

- By default it serves only the local UNIX socket (no network-accessible TCP listener).
- Optional HTTP gateway mode can bind on TCP (`127.0.0.1:8317` by default); wildcard binds are rejected, non-loopback binds require a bearer token, and rate-limit identities use token digests instead of raw token-derived log labels.
- It does not execute shell commands or spawn subprocesses on behalf of RPC callers.
- It does not modify files outside its own support directory.
- It does not require root or elevated privileges.

### Threat surface

| Threat | Mitigation | Residual risk |
|---|---|---|
| Local user impersonation via socket | Socket is filesystem-permission-protected (`0o600`); only the owning user can connect. Auth token required on every RPC request from app, extension, CLI, and smoke scripts. The auth token is passed via launchd `EnvironmentVariables` (not CLI arguments) to prevent `ps aux` exposure. | Another process running as the same user and able to read the user's LaunchAgent plist can send RPC calls. This is inherent to single-user UNIX socket IPC. |
| Daemon compromise exposes Keychain secrets | Keychain items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Attacker with daemon code execution can read secrets for the current user. | Equivalent to any unsandboxed app running as that user. |
| Malicious RPC input | Request size capped at 64 KB (`BurnBarDaemonServer.maxRequestBytes`). Typed Codable deserialization rejects malformed payloads. | No known injection vectors; RPC methods are enumerated, not dynamic dispatch. |
| Daemon auth token leak via process listing | Auth token is passed via `EnvironmentVariables` in the launchd plist, not as a CLI argument. The plist file is written with `0o600` permissions (owner read/write only). | launchd plist is visible to the owning user. Other local users cannot read it. The plist path is `~/Library/LaunchAgents/` which has `0o755` directory permissions — a local admin could escalate. |

## Extension (VS Code / Cursor)

### What it is

A sidebar extension that talks to the daemon over the same UNIX socket. It does **not** access the filesystem directly for AI agent logs — all data comes through the daemon.

### Permissions it requests

The extension declares `untrustedWorkspaces.supported: true` in `package.json`, meaning it activates even in restricted mode. However, it gates capabilities by trust level:

| Workspace state | Available tools | Gated tools |
|---|---|---|
| Trusted local workspace | `read_file`, `search_workspace`, `apply_patch`, `run_terminal` | — |
| Untrusted / restricted workspace | `read_file`, `search_workspace` | `apply_patch`, `run_terminal` |
| Read-only workspace | `read_file`, `search_workspace` | `apply_patch` |
| Virtual workspace | `read_file`, `search_workspace` | `run_terminal` |
| No workspace open | — | All workspace tools |

### What it cannot do

- It does not read or write files outside the VS Code/Cursor extension API.
- It does not spawn processes except through the daemon RPC bridge.
- It does not make network requests except to the local daemon socket.
- It does not access the macOS Keychain directly.

### Threat surface

| Threat | Mitigation | Residual risk |
|---|---|---|
| Extension displays stale/misleading daemon state | Refresh and reconnect actions are explicit. Health view shows daemon version and protocol mismatch. | A compromised daemon could send false state. |
| Workspace trust bypass | Tool gating is enforced in `capabilities.ts` based on VS Code's `isTrusted` API. | If VS Code itself is compromised, trust decisions are unreliable. |

## macOS App

### Sandbox status

The app runs **without App Sandbox** (`com.apple.security.app-sandbox = false`). This is required for:
- Reading AI agent log files from arbitrary home-directory locations
- Reliable Keychain access for Firebase Auth
- iCloud Documents integration
- Daemon subprocess management

### Consequence

If the app is compromised, the attacker has full access to the user's home directory. This is equivalent to any unsandboxed macOS utility. Mitigations:
- Secrets stored in Keychain, not plaintext files
- App does not execute untrusted code
- App is distributed via Developer ID signing (Gatekeeper + notarization provide an alternative security boundary)

### Local database (GRDB and optional SQLCipher)

- **Default:** The on-disk file at `~/Library/Application Support/OpenBurnBar/OpenBurnBar.sqlite` is a standard SQLite database opened via GRDB.
- **Optional encryption:** When the user enables database encryption in Settings, production builds use **SQLCipher** (linked through the SPM `GRDB-SQLCipher` package in `project.yml`, aligned with the daemon’s GRDB pin). A `PRAGMA key` is applied on every connection; the key material is held in the Keychain (`DatabaseEncryptionService`). The app checks `PRAGMA cipher_version` and refuses to use a silent plaintext path when encryption is requested but the library is not SQLCipher.
- **License:** SQLCipher is a community / commercial dual-licensed product; see [Zetetic’s SQLCipher licensing page](https://www.zetetic.net/sqlcipher/license/) for distribution terms. OpenBurnBar does not modify SQLCipher itself.
- **Migration:** Toggling encryption on for an **existing** plaintext database is a destructive migration path: users should rely on in-app or documented backup/restore flows rather than only flipping the switch on an old file (see [RUNBOOK](RUNBOOK.md)).
- **Key recovery (SOTA):** There is no automatic plaintext recovery file. The SQLCipher key is stored exclusively in the macOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, meaning it is unavailable when the device is locked and cannot migrate to another device via iCloud Keychain. If the Keychain is lost (macOS migration, Keychain reset, device loss), the encrypted database is unrecoverable. Users who want a recovery path must explicitly export a passphrase-protected recovery bundle (`DatabaseEncryptionService.exportRecoveryBundle(password:)`). The bundle uses PBKDF2-HMAC-SHA256 (100k iterations, random 16-byte salt) to derive a 256-bit AES key from the user passphrase, then encrypts the database key with AES-GCM. The bundle is safe to write to disk or transfer because it cannot be decrypted without the passphrase. Recovery is performed with `importRecoveryBundle(data:password:)`, which re-imports the unwrapped key into the Keychain. This design trades automatic convenience for genuine security: a same-user local compromise cannot read the key from a plaintext file.

## Cloud Surfaces (Opt-In)

### Firebase

- **Auth:** Google and Apple Sign-In via Firebase Auth. OAuth tokens managed by Firebase SDK.
- **App Check (Firestore):** The macOS app initializes App Check before Firebase. **Production** projects must **enforce** App Check for **Cloud Firestore** in the Firebase console so traffic without a valid attestation is rejected; Auth alone is not a substitute (see [FIREBASE_APP_CHECK_ENFORCEMENT.md](FIREBASE_APP_CHECK_ENFORCEMENT.md)).
- **Firestore:** Owner-scoped explicit collection rules cover supported `users/{uid}/...` sync paths and `workspaces/workspace-{uid}/...` shared-artifact paths. Client-writable sync documents reject plaintext-looking secret field names. Usage rollups, rate-limit docs, and top-level `provider_account_secret_refs` credential reference docs are server-only. Basic size limits are enforced. Authorization is expressed in rules; **app attestation** is expected via console App Check enforcement.
- **Hermes hosted relay:** The Cloud Run WebSocket relay is premium-only and accepts sockets only after Firebase Auth, App Check, explicit host/client role binding, and an unexpired Apple-verified hosted entitlement. It routes encrypted frames through Redis and never receives plaintext Hermes request or response bodies.
- **What syncs:** Usage rows, chat-thread metadata (for cross-device resume), and owner-scoped shared-artifact heads/revisions. Chat message bodies, conversation metadata, and full session-log backup are separately gated.
- **Privacy note:** Synced data can include project directory names and model names. Chat content requires **Back Up Chat Message Content**; full session log bodies with prompts or code require the session-log backup setting.

### iCloud

- Copies parsed session log files into the user's personal iCloud Drive container.
- Files sync through Apple's infrastructure, not OpenBurnBar servers.
- No merge/conflict resolution — iCloud may produce conflict copies.

### Cursor Connector Tunnel

- When enabled, a Cloudflare quick tunnel exposes the local OpenAI-compatible router on a public HTTPS URL.
- The tunnel exists because Cursor blocks `localhost` for BYOK endpoints.
- The tunnel URL is short-lived and tied to the active connector session.
- Provider API keys stay in Keychain; only a short-lived session token is written to the local support directory.

## Connector Plane (Experimental)

The daemon can optionally integrate with external services:

| Connector | Auth model | What it does |
|---|---|---|
| GitHub | Bearer token / API key | Test connection, sample API request |
| Slack | Bearer token | Test connection, sample API request |
| Linear | API key | Test connection, sample API request |
| PostHog | API key | Test connection, sample API request |
| Sentry | Bearer token | Test connection, sample API request |
| Gmail | OAuth access token | Test connection, sample API request |

All connector credentials are stored in macOS Keychain. Connectors are disabled by default and must be explicitly configured. Current actions are limited to `test_connection` and `sample_request` — no bulk data access or write operations.

## Runtime Network Dependencies

The app makes outbound network requests in the following categories:

| Category | Destination | When | User data sent |
|---|---|---|---|
| Provider logos | `raw.githubusercontent.com/lobehub/lobe-icons/...` | On UI render (SwiftUI `AsyncImage`) | None (standard HTTP metadata only) |
| Quota/usage APIs | Provider endpoints (MiniMax, Cursor, Factory, Z.ai) | When quota polling is enabled | Provider API keys (in auth headers) |
| Firebase | Google Cloud | When cloud sync is enabled | Usage rows, chat-thread metadata by default; chat content, conversation backup, session logs, and hosted Hermes relay traffic require explicit backup settings plus the server-written hosted entitlement |
| iCloud | Apple iCloud | When iCloud mirroring is enabled | Session log file copies |
| Connector APIs | GitHub, Slack, Linear, PostHog, Sentry, Gmail | When individual connectors are configured and tested | Connector-specific auth tokens |
| Telegram | `api.telegram.org` | When Telegram bot is configured | Bot token, notification payloads |
| Cursor tunnel | Cloudflare | When Cursor connector tunnel is active | Routed model requests (provider keys stay in Keychain) |
| Local services | `localhost:8642`, `localhost:18789`, etc. | When Hermes/OpenClaw backends are available | Chat messages, retrieval context |

All network requests except provider logos are opt-in and require explicit user configuration. The app is fully functional offline with only local SQLite as the data source.

## Summary of Trust Assumptions

1. The user's Mac is a single-user trusted environment.
2. Processes running as the same user are equally trusted (UNIX socket model).
3. macOS Keychain protects secrets at rest.
4. Cloud features are opt-in and do not replace local state.
5. The extension trusts VS Code's workspace trust API for tool gating.
6. External API calls use provider-specific auth (API keys, bearer tokens, OAuth) — OpenBurnBar does not proxy credentials through its own servers.

## Mobile Escrow & Device Trust

### Encrypted Credential Transfer

Provider credentials only move between devices through an opt-in encrypted escrow system:
- Each device generates a durable P-256 encryption keypair on first launch. Private keys stay in platform Keychain (macOS Keychain / iOS Keychain).
- Public keys sync through Firestore (`users/{uid}/escrow_public_keys/{deviceId}_{keyVersion}`).
- When a user opts to transfer a provider credential, the source device encrypts it for the destination device's public key using ECIES (P-256 + AES-GCM). Only ciphertext is written to Firestore (`users/{uid}/escrow_envelopes/{envelopeId}`).
- The destination device downloads the ciphertext, decrypts locally with its private key, stores the credential in its platform Keychain, and validates against the provider API.
- Success is proven only after provider readback — not optimistic transport success.

### Device Trust Model

| Phase | Description |
|---|---|
| **Registration** | A device signing into Firebase automatically registers as `pending` in `users/{uid}/escrow_devices/{deviceId}`. It can view synced stats but cannot import credentials. |
| **Approval (normal)** | An existing trusted device approves the pending device. This creates an `EscrowGrant` and updates the device trust state to `trusted`. |
| **Bootstrap (first device)** | If no trusted device exists, the user explicitly confirms "this is my first device" to bootstrap trust. No silent auto-approval. |
| **Revocation** | A trusted device can revoke another device's trust. All outstanding grants to the revoked device are invalidated. |

### Firestore Secret Prohibition

- Firestore rules reject client-writable sync documents containing fields named `apiKey`, `token`, `refreshToken`, `accessToken`, `idToken`, `cookie`, `password`, `secret`, `secretVersionName`, `authorization`, `bearer`, or `credential`; `provider_account_secret_refs` is denied to clients entirely.
- Unit tests prove plaintext secret strings are never serialized into Firestore-bound documents.
- Firebase never sees plaintext provider credentials — only ciphertext and non-sensitive metadata (provider ID, account label, credential kind, device IDs, timestamps).

### Key Management

- Private keys live exclusively in the platform Keychain (iOS Keychain / macOS Keychain) with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Key versioning supports rotation. Old keys are retained for decrypting historic envelopes.
- Missing private key is a recoverable state — surfaced as a classified error, not a crash.
- Encryption keys are not derivable by Firebase, Firestore rules, Cloud Functions, or backend infrastructure.

## Hosted Quota Subscription — Apple JWS Trust Pipeline

Hosted quota sync is gated by a paid Apple subscription. The server is the
sole writer of entitlement state; the iOS client never trusts its own
StoreKit verification result for authorization.

### Threat model

| Threat | Mitigation |
|---|---|
| **Forged JWS from a non-Apple signer** | Server verifies the chain against three vendored Apple root certificates (`AppleRootCA-G3`, `AppleRootCA-G2`, `AppleIncRootCertificate`) using `@apple/app-store-server-library`. SHA-256 fingerprints are pinned in `functions/src/appstore/verifier.ts:ROOT_CERT_FILES` and checked at cold start; any tamper with the vendored DER refuses to start the function. |
| **Replayed JWS from another user** | Pre-purchase, the server mints an `appAccountToken` UUID and writes `users/{uid}/entitlement_bindings/{token}`. StoreKit embeds the UUID inside the Apple-signed JWS via `Product.PurchaseOption.appAccountToken`. The reconciler reads `payload.appAccountToken`, looks it up in the binding collection, and rejects with `binding_mismatch` if it resolves to a different UID. |
| **Replayed older JWS reviving a revoked entitlement** | Reconciler calls `getAllSubscriptionStatuses` for the inbound `originalTransactionId` and re-verifies every JWS in the response. The "winning" transaction is the one with the most recent `signedDate`; older payloads cannot overwrite a newer verified state. `shouldOverwrite` keys replay protection to Apple `signedDateMs`, not local wall-clock verification time. |
| **Bundle / app id confusion** | Decoded JWS payloads must match `appStore.bundleId`; production notifications must additionally match `appStore.appAppleId`. Mismatches throw `bundle_id_mismatch` and never write the entitlement. |
| **Sandbox JWS aimed at production (or vice versa)** | The verifier auto-falls-back to the alternate environment when configured (`autoFallbackEnvironment`), but the matching `Environment` is stamped on the entitlement doc so operators can audit which environment a user's purchase actually verified under. |
| **Apple S2S replay** | Webhook endpoint is idempotent on `notificationUUID` via Firestore `create()` semantics on `users/{uid}/entitlement_events/{n_<uuid>}`. The audit append is the same operation regardless of how many times Apple retries. |
| **Missed S2S delivery** | A scheduled `reconcileHostedEntitlementsDaily` job re-pulls live state for every active entitlement. Missed renewals/revocations converge within 24 hours without operator intervention. |
| **Client-driven false claim of inactivity** | Clients only forward signed JWS strings; the server is authoritative. The iOS surface uses `restoreHostedQuotaEntitlement` (re-runs ASC reconciliation) when no local entitlement is found, instead of writing `active = false` on the client's behalf. |
| **Audit log secret exposure** | The audit `decoded` payload runs through a redactor that drops nested `signedTransactionInfo` / `signedRenewalInfo` / `signedPayload` strings and replaces them with their SHA-256. The raw JWS itself is never persisted; only its hash. `appAccountToken` UUIDs are stored on the entitlement doc but only logged with the first/last 4 chars (`abcd…7890`). |
| **Function deploy with stale or missing ASC creds** | The verifier and ASC client throw at first-use rather than silently degrading. Operators see `APP_STORE_ASC_KEY_ID is not set` etc. on the first call, not as a quiet verification regression. |

### Firestore Rules

- `users/{uid}/entitlements/{entitlementId}` — owner read; `write` denied to all clients.
- `users/{uid}/entitlement_events/{eventId}` — owner read; `write` denied to all clients.
- `users/{uid}/entitlement_bindings/{bindingId}` — server-only, denied to clients for both read and write.

### Schema versioning

The entitlement doc carries `schemaVersion: 2` and `verificationVersion: 2` for
the Apple-JWS-verified path. The `source` literal `apple_jws_verified` is
written by every callable / S2S / scheduled write; legacy v1 docs (which
trusted only a SHA-256 of a client-supplied JWS) are migrated forward on the
next verified event.
