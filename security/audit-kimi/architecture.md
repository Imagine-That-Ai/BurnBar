# Architecture Review

## A.2.1 Components and Trust Boundaries

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                    Mac User                                  │
│  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐ │
│  │   AgentLens.app     │  │  VS Code Extension  │  │  Other AI Agents    │ │
│  │   (SwiftUI app)     │  │  (Node/TypeScript)  │  │  (MCP clients)      │ │
│  └──────────┬──────────┘  └──────────┬──────────┘  └──────────┬──────────┘ │
│             │ UNIX socket / JSON-RPC │       stdin/stdout     │            │
│             │        auth token      │       MCP protocol     │            │
│  ┌──────────▼────────────────────────┴────────────────────────▼──────────┐ │
│  │                    OpenBurnBarDaemon (Swift)                          │ │
│  │  - Log parsing (17 parsers)                                           │ │
│  │  - Local SQLite (GRDB; SQLCipher TBD)                                 │ │
│  │  - Computer Use coordinator                                           │ │
│  │  - Privileged input XPC / virtual HID                                 │ │
│  │  - iroh node for phone sync                                           │ │
│  └──────────┬──────────────────────────────┬─────────────────────────────┘ │
│             │ Local network / iroh QUIC     │ Cloud sync (HTTPS/Firebase) │
│  ┌──────────▼──────────┐        ┌───────────▼────────────┐                 │
│  │  iOS/Android app    │        │  Firebase Auth +       │                 │
│  │  (paired device)    │        │  Firestore + Storage   │                 │
│  └─────────────────────┘        └───────────┬────────────┘                 │
│                                             │                               │
└─────────────────────────────────────────────┼───────────────────────────────┘
                                              │
                       ┌──────────────────────▼──────────────────────┐
                       │   Firebase Cloud Functions (Node 22)        │
                       │   - Auth, billing, quota, entitlement       │
                       │   - Encrypted search index                  │
                       │   - Computer Use security / pairing         │
                       │   - Remote MCP service                      │
                       └──────────────┬──────────────────────────────┘
                                      │
                       ┌──────────────▼──────────────┐
                       │   BurnBar Pro services      │
                       │   - Hosted encrypted search │
                       │   - Hosted MCP              │
                       │   - Apple/Google/Stripe     │
                       └─────────────────────────────┘
```

## A.2.2 Data Flows

### 1. Local Log Ingestion

1. Daemon watches `~/.codex/sessions/`, `~/.claude/projects/`, `~/.anthropic`, etc.
2. Parsers normalize JSON/XML/text into `OpenBurnBarCore` model objects.
3. Data is written to local SQLite via GRDB.
4. UI reads via `DataStore` / `AppStore` pattern.

**Trust boundary**: Parser output crosses from untrusted log files into trusted in-memory models. No sandbox separates them.

### 2. Cloud Sync (Opt-In)

1. User signs in with Apple/Google/Firebase.
2. App Check attestation runs.
3. Device generates Cloud Vault key material (Signal/libsignal).
4. Sensitive fields are sealed with per-recipient envelopes before Firestore write.
5. Server stores sealed blobs; cannot read content.
6. Other devices fetch blobs and unseal with their own keys.

**Trust boundary**: Plaintext leaves the app only inside sealed envelopes. Routing metadata (provider, cost, timestamp, device IDs) is server-visible.

### 3. Computer Use

1. User enables Computer Use in UI or via phone.
2. Session key is established via iroh/Firebase.
3. Tool requests (click, type, browser action, file read, shell command) are sent to daemon.
4. Approval UI prompts user; trust mode can be "Trusted", "Step", or "Manual".
5. Panic kill switch can halt at any time.
6. Audit chain entries are hashed and optionally timestamped.

**Trust boundary**: The daemon can drive the entire Mac UI; approval UI is the primary security control.

### 4. Remote MCP / Hosted Search

1. MCP client requests `search` or `resume` tool.
2. Hosted MCP validates bearer token audience and entitlement.
3. Functions perform encrypted search over sealed index or return resume snippets.
4. Results are decrypted and returned via MCP.

**Trust boundary**: Server never decrypts user content; tokens bind client to account.

## A.2.3 Trust Boundaries

| Boundary | Entities | Controls |
|---|---|---|
| Process | App ↔ Daemon | UNIX socket, single auth token |
| Device | Mac ↔ iOS/Android | iroh pairing, passkey/escrow, Cloud Vault |
| Tenant | User A ↔ User B | Firestore owner-scoped rules, Firebase Auth UID |
| Network | Device ↔ Firebase | TLS, App Check (console-enforced) |
| Service | User ↔ BurnBar backend | Auth tokens, entitlements, sealed payloads |
| AI Agent | Untrusted logs ↔ LLM prompt | Delimiter wrapping, parser sanitization, human approval |

## A.2.4 Key Assumptions

1. **Same-user compromise is out of scope for the daemon** — the daemon must run with user privileges to access logs and perform Computer Use. It is therefore trusted as the user.
2. **App Check is configured in the Firebase console** — the client uses it; the repo does not programmatically enforce it.
3. **Apple/Google JWS/Play verification is configured correctly** — entitlement verification depends on provider public keys and console settings.
4. **Users do not store their machine backups in untrusted cloud** — a plaintext DB in a Time Machine/iCloud backup is outside our control.
5. **Cloud Functions runtime and Firestore rules are deployed as written** — drift between repo and production is possible.

## A.2.5 Residual Design Tensions

| Tension | Current Resolution | Audit Note |
|---|---|---|
| Local-first privacy vs. cloud sync convenience | Sync is opt-in; content sealed; metadata visible | FINDING-006 |
| Sandboxing vs. log access | App/daemon unsandboxed | FINDING-002 (accepted risk) |
| SQLCipher vs. open-source compliance | libsignal AGPL path exists; SQLCipher not yet enabled | FINDING-001 |
| Approval UX friction vs. safety | "Step" mode exists; "Trusted" mode bypasses per-action prompts | FINDING-003 |
| Hosted MCP utility vs. data exposure | Tokens + entitlements; no content decryption | FINDING-008 |
| AI agent tool power vs. misuse | Human approval required for Computer Use | FINDING-003, FINDING-004 |
