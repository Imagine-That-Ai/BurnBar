# Security Definition

## What "Secure" Means for OpenBurnBar

OpenBurnBar is a **local-first** productivity app with optional cloud sync, device pairing, and a paid hosted tier. Security for this product means three things at different layers:

1. **User data stays on the user's device unless the user explicitly opts in to sync.** The product's core value proposition is a private dashboard of AI agent activity. Any unauthorized read of the local database, cloud backups, or synced payloads is a critical failure.
2. **When cloud sync is enabled, the service provider cannot read private content.** This is an E2EE-style privacy claim implemented via Cloud Vault / Signal-libsignal sealed envelopes and per-device keys.
3. **Computer Use, hosted MCP, and device-control features cannot be silently weaponized.** Because the product intentionally grants screen-reading, keyboard/mouse, browser, and phone-control capabilities, approval, scope, audit, and kill-switches are safety-critical controls.

## Actors and Trust Levels

| Actor | Trust | Boundaries |
|---|---|---|
| End user (Mac) | Highest | Owns device, keychain, local DB |
| OpenBurnBar macOS app | Same user, trusted | Local process; must not leak data to other processes/cloud without consent |
| OpenBurnBar daemon | Same user, privileged | Runs outside sandbox to read logs and perform input; must enforce least-privilege per RPC method |
| iOS/Android companion app | Paired device, user-trusted | Authenticated via passkey/escrow; must not cross-pair without user consent |
| Browser console (`app.burnbar.ai`) | User-trusted, device-trusted after escrow | WebAuthn + device escrow establishes trust |
| Other local AI agents (MCP clients) | Untrusted | Must be mediated by user approval or scoped capability tokens |
| BurnBar/Firebase backend | Semi-trusted | Can see routing metadata, costs, account info; must not read sealed content or bypass ownership |
| Third-party AI providers (OpenAI, Anthropic, etc.) | Untrusted | Token summaries are local; only explicit hosted queries leave the device |
| Public internet attackers | Untrusted | No direct access to local app; can target cloud surface, release binaries, or phishing |

## Scope

### In Scope

- macOS app, daemon, and shared core
- iOS/Android companion apps
- Firebase Cloud Functions and Firestore rules
- Remote MCP hosted service
- Local MCP server
- VS Code/Cursor extension
- CI/CD release pipeline
- Supply chain and dependency management
- AI/agentic surfaces: log parsers, chat/RAG, Computer Use tools

### Explicitly Out of Scope

- Security of third-party AI agent CLIs that BurnBar reads (Claude Code, Codex, etc.) except how BurnBar parses their output
- Security of Apple's/Google's cloud identity infrastructure except configuration of our use
- Physical security of the user's Mac or phone
- Browser security of websites visited via Computer Use browser tools (we analyze the bridge only)

## Key Data Classes

| Class | Examples | Sensitivity |
|---|---|---|
| Agent session logs | Messages, commands, code, file paths, errors | **Critical** — often contains source code, credentials, IP |
| Provider API keys/tokens | Cursor, Anthropic, OpenAI, GitHub tokens | **Critical** — direct access to paid services and data |
| Token/cost summaries | Provider usage, spend, model names | **Medium** — financial/privacy metadata |
| Identity/auth tokens | Firebase ID token, App Check token, Apple JWS | **Critical** — account takeover vectors |
| Device pairing secrets | Escrow tokens, iroh node IDs | **High** — cross-device control |
| Telemetry/debug logs | Crash reports, analytics | **Low-Medium** — scrubbed but may contain fragments |

## Threat Model Priorities

| Priority | Threat Family | Rationale |
|---|---|---|
| 1 | Unauthorized local data access | Core product claim; plaintext DB is the biggest gap |
| 2 | Unauthorized cloud data access / BOLA | Owner-scoped rules help; App Check and encryption must hold |
| 3 | Device/cross-device takeover | Phone-control, Computer Use, and escrow are high-impact |
| 4 | Prompt/RAG/agentic injection | Untrusted agent logs become trusted context |
| 5 | Supply-chain / CI compromise | Could ship malicious update to all users |
| 6 | Abuse of paid features | Entitlement fraud, token theft, meter bypass |

## Compliance and Business Context

- **Privacy-first marketing** creates legal/brand risk if local data is not encrypted or cloud metadata leaks more than users expect.
- **BurnBar Pro / paid tiers** require strong entitlement verification (Apple/Google/Stripe) to prevent revenue loss.
- **GDPR/CCPA data deletion** is implemented via callable functions; completeness depends on Firestore/storage rules and local deletion.
- **Computer Use safety** could become a regulatory/safety concern if the tool can act on the user's behalf without clear approval.
