# Glossary

## Product terms

**AgentLens** — the macOS app source tree. The product name is OpenBurnBar; the bundle ID is `com.openburnbar.app`. The folder name is historical.

**OpenBurnBarDaemon** — the local JSON-RPC daemon that runs in the background. It handles provider routing, mission control, quota polling, the HTTP gateway, and connector plane actions.

**OpenBurnBarCore** — the shared Swift package containing wire types, RPC contracts, and utilities used by both the macOS app and the daemon.

**OpenBurnBarMobile** — the iOS/iPadOS companion app.

**OpenBurnBarCLI** — the local CLI entrypoint bundled with the daemon package. Commands include `health`, `controller`, `questions`, `followups`, `missions`, `mission-approve`, `simulator-runs`, and `simulator-replay`.

## Feature terms

**Hermes** — the AI chat system inside OpenBurnBar. It has two backends: Local Index mode (stateless CLI bridge to `codex` or `claude`) and Hermes mode (multi-turn via `hermes webapi` at `localhost:8642`).

**Mercury** — the P2P media system: file transfer, screen sharing, and 1:1 voice/video calls over iroh transport. Uses warm mercury color identity (`hermesMercury`, `hermesAureate`).

**Computer Use** — the capability where an AI agent drives the Mac (browser, system events, accessibility) while an iOS/Android companion mirrors the screen with tap-to-drive and panic-halt controls.

**Agent Watch** — the read-only mirror of the Mac screen on the phone companion, part of Computer Use Phase 8.

**Agent Live Stage** — the iOS/iPadOS overlay that auto-opens when a Computer Use session starts, showing a dockable mirror tile that can expand to split-screen or full-bleed.

**Insights / Editorial Observatory** — the intelligence brief that surfaces spend patterns, anomalies, and recommendations as an editorial story: eyebrow + executive headline + numbered findings + Anomaly Atlas + recommendations.

**Mission Control** — the daemon-backed runtime for project registry, scheduled reviews, question/followup workflows, mission dispatch, and simulator replay.

**Connector Plane** — the daemon's integration surface for external tools: GitHub, Slack, Linear, PostHog, Sentry, and Gmail.

**Routing Pools** — the local OpenAI-compatible gateway that routes selected models (Z.ai, MiniMax, Ollama Cloud, etc.) to Cursor, Droid/Factory, Forge, OpenCode, Codex CLI, and Claude Code.

## Technical terms

**GRDB** — the Swift SQLite wrapper used for local persistence. Chosen over Core Data for ergonomic API and easier testing.

**iroh** — the Rust P2P transport library. Compiled to `Vendor/openburnbar-iroh.xcframework` (iOS/macOS) and `Vendor/openburnbar-iroh.aar` (Android) via UniFFI bindings pinned to 0.28.3.

**UniFFI** — Mozilla's FFI framework for Rust, used to generate Swift and Kotlin bindings from a single Rust crate.

**Local-first** — the architectural principle that local SQLite and daemon-owned files are canonical. Firestore and iCloud are optional replication planes, never the source of truth.

**Daemon-first** — the architectural principle that the macOS app is a UI shell over a local JSON-RPC daemon. The daemon owns provider routing, run state, and mission control.

**Ed25519 pairing** — the authentication scheme for iroh sessions. Each peer proves identity via Ed25519 signatures.

**TypeSpec** — the schema definition language used in `tools/schema-sync/` to generate TypeScript, Swift, and Kotlin types from a single source of truth.

**Remote MCP** — BurnBar Pro feature. Hosted encrypted semantic search accessible to AI coding agents via MCP protocol. Local stdio bridge at `tools/openburnbar-mcp-remote/`.

**Budget Governance** — the spend control system: per-user daily ceiling, soft monthly cap ($1,500 for Computer Use), hard monthly cap ($2,500), and Remote Config kill-switches.

**CloudSyncService** — the component that merges local state with Firestore using optimistic concurrency. Handles shared artifacts, usage rows, and conversation metadata.

**Projection Pipeline** — the background process that builds searchable indexes (`search_chunks_fts`, `search_documents`, optional vector embeddings) from local SQLite content.

**ContextPack** — the structured evidence bundle used by the Insights engine and Project Memory detail sheets. Composed of conversations, source artifacts, and usage data.

## Related pages

- [Architecture](architecture.md) — system diagram and boundaries
- [macOS app](../apps/macos-app/index.md) — AgentLens deep dive
- [Daemon](../systems/daemon/index.md) — OpenBurnBarDaemon deep dive
