# Systems

Internal building blocks shared across the OpenBurnBar platform. Each system is a distinct subsystem with its own codebase location, protocol, and lifecycle.

## Daemon

The background agent process that handles mission control, provider connector management, and the connector plane. Installed by the macOS app; supervised via launchd. Exposes a local JSON-RPC socket that the macOS app, iOS companion, and VS Code extension connect to.

→ [Daemon](daemon/index.md)

## Local database

GRDB/SQLite canonical store for all token usage events, conversations, sessions, and rollups. Lives entirely on-device. Cloud sync is optional and additive.

→ [Local database](local-database/index.md)

## Retrieval

Full-text search (FTS5) and HNSW vector search pipeline powering the Hermes chat context injection and the Local Index chat mode. Indexes session logs, conversations, skill docs, and agent docs.

→ [Retrieval](retrieval/index.md)

## iroh transport

Rust P2P library providing Ed25519-authenticated QUIC connections for Mercury media (file transfer, screen share, 1:1 calls) and Agent Watch (live screen mirror). UniFFI bindings expose the same Rust crate to Swift (xcframework) and Kotlin (AAR).

→ [iroh transport](iroh-transport.md)

## Cloud Functions

Firebase Cloud Functions (TypeScript, Node.js 18) backing optional cloud features: quota rollups, FCM push, VoIP call dispatch, Computer Use budget governance, and insight generation. All callables use App Check guards.

→ [Cloud Functions](cloud-functions.md)

## Hermes realtime relay

Node.js WebSocket relay service for real-time agent-to-device streaming. Runs as a separate service (`services/hermes-realtime-relay/`). Devices connect over the iroh `openburnbar/1` ALPN; all frames carry Ed25519 signatures for pairing authentication.

→ [Hermes realtime relay](hermes-relay.md)
