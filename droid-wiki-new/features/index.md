# Features

Cross-cutting capability index. Each link goes to the detailed feature page.

## Tracking and data

**[Usage tracking](usage-tracking.md)**
Parses 17+ AI agent log formats into a unified token + cost ledger stored in local SQLite. The source of truth for all other features.

**[Provider quota](provider-quota.md)**
Per-provider API quota monitoring with 22+ adapters. Tracks remaining headroom and stores snapshots in Firestore + local cache.

**[Budget governance](budget-governance.md)**
Per-user daily ceiling, soft monthly cap, hard monthly cap, and Remote Config kill-switch.

## Intelligence

**[Insights](insights.md)**
Editorial Observatory intelligence cards: eyebrow + executive headline + numbered findings + Anomaly Atlas + Recommendations + Generated Views.

## Agent interaction

**[Hermes chat](hermes-chat.md)**
AI chat over two backends: Local Index mode (stateless CLI bridge) and Hermes mode (multi-turn via localhost:8642).

**[Computer Use](computer-use.md)**
Agent drives the Mac; phone mirrors and controls. Six phases from Agent Watch to trusted-scope polish.

## Communication

**[Mercury media](mercury-media.md)**
P2P file transfer, screen share, and 1:1 voice/video calls over iroh.

## Sync and storage

**[Cloud sync](cloud-sync.md)**
Optional cross-device continuity via Firestore + iCloud.

**[Remote MCP](remote-mcp.md)**
BurnBar Pro feature: hosted encrypted semantic search accessible to AI coding agents via MCP protocol.
