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
│         ├──│  Local SQLite (GRDB)   │  canonical data store                  │
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
- Optional HTTP gateway mode can bind on TCP (`127.0.0.1:8317` by default); non-loopback binds require a bearer token.
- It does not execute shell commands or spawn subprocesses on behalf of RPC callers.
- It does not modify files outside its own support directory.
- It does not require root or elevated privileges.

### Threat surface

| Threat | Mitigation | Residual risk |
|---|---|---|
| Local user impersonation via socket | Socket is filesystem-permission-protected; only the owning user can connect. | Another process running as the same user can send RPC calls. This is inherent to single-user UNIX socket IPC. |
| Daemon compromise exposes Keychain secrets | Keychain items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Attacker with daemon code execution can read secrets for the current user. | Equivalent to any unsandboxed app running as that user. |
| Malicious RPC input | Request size capped at 64 KB (`BurnBarDaemonServer.maxRequestBytes`). Typed Codable deserialization rejects malformed payloads. | No known injection vectors; RPC methods are enumerated, not dynamic dispatch. |

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

## Cloud Surfaces (Opt-In)

### Firebase

- **Auth:** Google and Apple Sign-In via Firebase Auth. OAuth tokens managed by Firebase SDK.
- **Firestore:** Owner-scoped rules: `users/{uid}/...` and `workspaces/workspace-{uid}/...` are readable/writable only by the authenticated owner. Basic size limits enforced.
- **What syncs:** Usage rows, chat threads (for cross-device resume), and owner-scoped shared-artifact heads/revisions. Conversation metadata and full session-log backup are separately gated.
- **Privacy note:** Synced data can include project directory names, model names, chat content, and (if backup is enabled) full session log bodies with prompts or code.

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
| Firebase | Google Cloud | When cloud sync is enabled | Usage rows, chat threads, auth tokens |
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
