# Security

OpenBurnBar is a multi-surface product (macOS app, daemon, VS Code/Cursor extension, iOS/Android mobile apps, Firebase Cloud Functions). Security is layered: local-first data, opt-in cloud sync, encrypted device pairing, and explicit user consent for every high-risk action.

For the full threat model, see [`docs/THREAT_MODEL.md`](../../docs/THREAT_MODEL.md). For the LLM/agent-specific threat model, see [`docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md`](../../docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md).

## Threat model at a glance

The system runs as the logged-in macOS user. Trust boundaries:

- **macOS app (`AgentLens`)** ↔ **Daemon** — UNIX domain socket at `~/Library/Application Support/OpenBurnBar/openburnbar-daemon.sock`, filesystem ACL `0o600`, auth token required on every RPC request.
- **Extension** ↔ **Daemon** — same socket; extension does not touch the filesystem directly.
- **App** ↔ **Keychain** — secrets stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- **App** ↔ **Local SQLite (GRDB)** — canonical data store; optional SQLCipher at rest.
- **App** ↔ **Firebase / iCloud** — opt-in only; no silent full-transcript upload.

The app runs **without App Sandbox** (required for reading arbitrary agent log paths, Keychain access, iCloud, and daemon management). It is signed with Developer ID and notarized.

## Permission model

### macOS app
- Reads AI agent logs from `~/.claude/`, `~/.factory/`, `~/.codex/`, `~/.kimi/`, `~/.hermes/`, `~/.augment/`, `~/.forge/`, `~/.goose/`, and `~/Library/Application Support/`.
- Writes only to `~/Library/Application Support/OpenBurnBar/`.
- Does not execute untrusted code or spawn subprocesses on behalf of RPC callers.

### Daemon
- Serves only the local UNIX socket by default.
- Optional HTTP gateway binds `127.0.0.1:8317`; wildcard binds are rejected; non-loopback binds require a bearer token.
- Request size capped at 64 KB. Typed Codable deserialization rejects malformed payloads.
- Auth token is passed via launchd `EnvironmentVariables` (not CLI arguments) to prevent `ps aux` exposure. The plist is written with `0o600`.

### VS Code / Cursor extension
- Declares `untrustedWorkspaces.supported: false` — does not activate in restricted workspaces.
- Destructive tools (`apply_patch`, `run_terminal`) are gated by VS Code workspace trust level.

## Keychain and secrets

- Provider API keys, connector credentials, bearer tokens, and database encryption keys are stored in the macOS Keychain.
- **Database encryption:** Optional SQLCipher (SPM `GRDB-SQLCipher`). The key material is held in the Keychain (`DatabaseEncryptionService`). A passphrase-protected recovery bundle (PBKDF2-HMAC-SHA256 + AES-GCM) is available for explicit export.
- The app never writes plaintext secrets to disk.

## Ed25519 pairing for iroh

- Device pairing uses **Ed25519** signatures over the iroh transport.
- The Mac advertises a signed `iroh_pairing` record; iOS/Android clients verify the signature against the published Ed25519 public key before dialing the NodeId.
- Phone-as-controller intents (Computer Use Phase 12) are Ed25519-signed by the paired peer and verified server-side.
- Remote Unlock capability tokens are signed by a certification-provisioned Ed25519 issuer (`RemoteUnlockCapabilitySigningKeyStore`).

## Audit chain

- Computer Use sessions maintain a **content-addressed audit chain** (SHA-256 today, BLAKE3-swappable).
- Tamper detection covers every entry, including the terminal entry when `head.json` is supplied.
- Every action is recorded with a trace ID, timestamp, and outcome.

## Panic-kill paths

Three independent panic-kill mechanisms are available at all times during a Computer Use session:

1. **Global hotkey** — `⌃⌥⌘.` triggers immediate session halt.
2. **Phone three-finger long-press** — on the mirrored phone surface.
3. **NSWorkspace auth gate** — loginwindow / SecurityAgent / screen sleep events.
4. **Remote Config kill-switch** — `computer_use_kill_switch` or `media_kill_s*` (server-side flag) disables the feature for all users.

`ComputerUsePanicHaltCoordinator` evaluates all four paths.

## Exception capture and monitoring

- **Sentry** — Cloud Function callable errors auto-capture via `wrapCallableHandler` → `withCallableLogging` → `captureException()` in `functions/src/logging.ts`. Set `SENTRY_DSN` for production.
- **GCP Monitoring** — primary ops notification plane with log-based user metrics and Cloud Run metrics.
- **CI enforcement** — `scripts/ci/verify-ops-readiness.sh` runs callable logging + resilience wiring checks before release.

## CodeQL and supply chain

- **CodeQL** scanning is enabled in CI (`.github/workflows/openburnbar-pr-harness.yml`).
- **Supply chain audit** — `scripts/ci/verify-resilience-wiring.sh` enforces that no raw `await fetch` exists in `functions/src/`. All provider HTTP must use `providerFetch` from `functions/src/providers/httpClient.ts`.
- **Firestore secret prohibition** — Rules reject client-writable sync documents containing fields named `apiKey`, `token`, `refreshToken`, `accessToken`, `idToken`, `cookie`, `password`, `secret`, etc. `provider_account_secret_refs` is denied to clients entirely.
- **Encrypted credential transfer** — Provider credentials move between devices through an opt-in ECIES (P-256 + AES-GCM) escrow system. Ciphertext only is written to Firestore; plaintext never leaves the source device.

## Hosted quota — Apple JWS trust pipeline

- The server is the sole writer of entitlement state.
- Apple JWS signatures are verified against three pinned root certificates.
- `appAccountToken` UUIDs are pre-minted by the server and embedded in StoreKit purchases; replayed JWS from another user is rejected.
- Reconciliation re-verifies every `signedDate`; older payloads cannot overwrite newer verified state.
- The audit log redacts raw JWS strings and replaces them with SHA-256 hashes.
