# Systems

Internal building blocks that power OpenBurnBar across platforms. These are architectural components that do not map to a single app or package.

## Daemon

The local JSON-RPC server that runs in the background. Owns provider routing, mission control, quota polling, the HTTP gateway, and the connector plane.

→ [Daemon](daemon/index.md)

## Local database

GRDB-backed SQLite is the canonical data store. Covers schema, migrations, query patterns, and the projection pipeline.

→ [Local database](local-database/index.md)

## Retrieval

The search and indexing substrate: FTS, vector embeddings, and the projection pipeline that builds searchable content from local SQLite.

→ [Retrieval](retrieval/index.md)

## Iroh transport

P2P transport over the Rust iroh crate, compiled to XCFramework and AAR via UniFFI. Powers Mercury media and Computer Use Agent Watch.

→ [Iroh transport](iroh-transport.md)

## Cloud functions

49 Firebase callable functions (TypeScript) with structured logging, circuit breakers, and Sentry integration.

→ [Cloud functions](cloud-functions.md)

## Hermes relay

Real-time relay for Hermes chat, iroh transport coordination, and media session state management.

→ [Hermes relay](hermes-relay.md)
