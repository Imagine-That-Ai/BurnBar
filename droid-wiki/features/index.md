# Features

Cross-cutting capability index. Each link goes to the detailed feature page.

---

## Tracking and data

**[Usage tracking](usage-tracking.md)**  
Parses 17+ AI agent log formats (Claude Code, Factory Droid, Codex, Cursor Agent, Gemini CLI, Goose, Kimi, Warp, Windsurf, and more) into a unified token + cost ledger stored in local SQLite. The source of truth for all other features.

**[Provider quota](provider-quota.md)**  
Per-provider API quota monitoring with 22+ adapters. Tracks remaining headroom (Anthropic 5-hour rolling window, OpenAI rate limits, others), stores snapshots in Firestore + local cache, and shows quota bars in the popover when a provider approaches limits.

**[Budget governance](budget-governance.md)**  
Per-user daily ceiling, soft monthly cap, hard monthly cap, and Remote Config kill-switch. Computer Use has dedicated limits: soft $1,500/mo, hard $2,500/mo. `BudgetGate` blocks actions at the hard limit and warns at the soft limit.

---

## Intelligence

**[Insights](insights.md)**  
Editorial Observatory intelligence cards: eyebrow + executive headline + numbered 01/02/03 Top Findings + Anomaly Atlas + Recommendations + Generated Views. Ships on iOS, iPadOS, and Android with benchmark-aware model-routing suggestions.

---

## Agent interaction

**[Hermes chat](hermes-chat.md)**  
AI chat over two backends: Local Index mode (stateless CLI bridge to `codex` or `claude`) and Hermes mode (multi-turn via `hermes webapi` at `localhost:8642`, OpenAI-compatible SSE). Mercury design identity — shimmer gradient borders, pooling droplet thinking animation, collapsible tool cards.

**[Computer Use](computer-use.md)**  
Agent drives the Mac; phone mirrors and controls. Six phases: Agent Watch (read-only mirror), Browser (Playwright Chromium), Trust modes + audit chain, Mac System CGEvent+AX (Developer ID only), Phone-as-controller (Ed25519-signed intents), and Polish (trusted-scope library, audit export). Three independent panic-kill paths.

---

## Communication

**[Mercury media](mercury-media.md)**  
P2P file transfer, screen share, and 1:1 voice/video calls over iroh (UniFFI Rust crate, Ed25519 pairing). Ships on macOS, iOS, and Android. Includes incoming-call sheets, per-partner save preferences, and Mercury audio over ALPN `openburnbar/mercury/audio/1`.

---

## Sync and storage

**[Cloud sync](cloud-sync.md)**  
Optional cross-device continuity via Firestore + iCloud. Usage rows, quota snapshots, and conversation metadata sync automatically when signed in. Session-log backups and chat message bodies require explicit opt-in. Local SQLite is always canonical.

**[Remote MCP](remote-mcp.md)**  
BurnBar Pro feature. Hosted encrypted semantic search accessible to AI coding agents via MCP protocol. Local stdio bridge (`tools/openburnbar-mcp-remote/`) for Cursor; hosted Cloud Run service (`services/hosted-mcp/`) for direct agent connections. Eight tools including conversation search, usage data, and resumable sessions.
