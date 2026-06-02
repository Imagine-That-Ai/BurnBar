# Remote MCP

## Purpose

BurnBar Pro feature: hosted encrypted semantic search for AI coding agents via the Model Context Protocol (MCP). Coding agents (Claude Code, Codex, Cursor) can query a user's OpenBurnBar session history and usage data directly from within their context window. Instead of the agent guessing at spend or asking the user, it calls a BurnBar MCP tool and gets structured data back.

## Directory layout

```
tools/openburnbar-mcp-remote/
├── package.json                         # Local stdio bridge (proxies to hosted Cloud Run service)
├── src/
│   ├── index.ts                         # Entry point: stdio ↔ HTTP proxy
│   ├── proxy.ts                         # Proxies tool calls to hosted service
│   ├── decrypt.ts                       # Device-side decryption of encrypted body pages
│   ├── hash.ts                          # Chunk hash verification
│   └── privacy.ts                       # OBB Resume — opaque query hashes, not raw memory text

services/hosted-mcp/
├── package.json                         # Cloud Run resource server
├── src/
│   ├── index.ts                         # Server entry (MCP Streamable HTTP)
│   ├── toolRegistry.ts                  # Tool registration and routing
│   ├── search.ts                        # Semantic + token search implementation
│   ├── capabilities.ts                  # Capability description endpoint
│   └── auth.ts                          # Bearer token validation

functions/src/callables/
├── remoteMcp.ts                         # Firebase Callable: issueRemoteMcpGrant, revokeRemoteMcpClient, searchStreams
├── remoteMcpOAuth.ts                    # OAuth token issuance
└── remoteMcpGrant.ts                    # Grant management (create, revoke per-client)

docs/
├── HOSTED_REMOTE_MCP.md                 # Full architecture and privacy documentation
├── REMOTE_MCP_RUNBOOK.md                # Operational runbook
└── architecture/003-error-handling.md   # Error handling ADR

scripts/
├── test-hosted-mcp-security.sh          # Security verification suite
├── test-hosted-mcp-compatibility.sh     # Client compatibility tests
└── prove-hosted-mcp-privacy-scan.mjs    # Privacy mode verification

android/app/src/main/java/com/openburnbar/ui/store/
└── CloudStoreViewMcpSections.kt         # Android Cloud Store MCP UI sections

OpenBurnBarMobile/Views/Store/
├── CloudStoreView.swift                 # iOS Cloud Store / Pro tier view
└── CloudTierComponents.swift            # Pro tier UI components
```

## Key abstractions

### Two components

#### 1. `tools/openburnbar-mcp-remote/` — local stdio bridge

A local stdio shim for clients that do not support remote Streamable HTTP MCP (e.g., Cursor). It:
- Proxies tool calls to the hosted Cloud Run service
- Handles device-side decryption of encrypted session body pages
- Verifies chunk hashes before presenting decrypted content to the agent
- Supports `OBB Resume` — sends locally derived opaque query hashes (not raw memory text) to preserve privacy

#### 2. `services/hosted-mcp/` — Cloud Run resource server

The production endpoint is `https://mcp.burnbar.ai/mcp`. It implements the 2025-11-25 MCP Streamable HTTP shape: `initialize`, `tools/list`, `tools/call`, `resources/list`, `resources/read`.

Security controls:
- Validates `Origin` header on all requests
- Rejects missing bearer auth with `WWW-Authenticate`
- Bounds request and response sizes
- Tool inputs never accept `uid` or arbitrary Firestore/Storage paths — the bearer token `sub` selects the user namespace
- Rate-limit buckets per tool

### `issueRemoteMcpGrant` (Firebase Callable)

```typescript
export const issueRemoteMcpGrant = onCall(
  {
    region: "us-central1",
    enforceAppCheck: true,
    maxInstances: 50,
    secrets: [REMOTE_MCP_TOKEN_HMAC_SECRET],
  },
  wrapCallableHandler("issueRemoteMcpGrant", async (request) => {
    // Validates auth, App Check, BurnBar Pro entitlement
    // Issues short-lived grant with selected scopes
  })
);
```

Grant modes:
- `local_decrypt_shim` (default) — hosted service returns sealed titles, snippets, and encrypted body pages; plaintext decrypt happens on-device
- `sealed_only` — no body pages, only metadata
- `remote_readable_explicit_opt_in` — explicit opt-in for remote plaintext (not implemented)

## How it works

```mermaid
graph TD
    A[Agent client
Claude Code / Codex / Cursor] --> B[Local stdio bridge
openburnbar-mcp-remote]
    B -->|HTTPS| C[Cloud Run
mcp.burnbar.ai/mcp]
    C --> D[Firebase Auth
Bearer validation]
    D --> E[Firestore
users/{uid}/chunks]
    E --> F[Sealed results
encrypted body pages]
    F --> B
    B --> G[Device-side decrypt
hash verify]
    G --> A
```

### Available tools

| Tool | What it does |
|------|-------------|
| `burnbar_search_conversations` | Semantic + token search over indexed session history |
| `burnbar_get_conversation_body` | Retrieve a decrypted conversation body by ID |
| `burnbar_list_search_index_status` | Status of the hosted search index |
| `burnbar_list_search_facets` | Available filter dimensions (provider, date range, etc.) |
| `burnbar_recent_usage` | Recent token usage and spend summary |
| `burnbar_list_resumable_conversations` | Sessions that can be resumed |
| `burnbar_resume_conversation` | Compose a sealed resume envelope for a session |
| `burnbar_resolve_capabilities` | Describe available capabilities for the current entitlement |

### Privacy mode

Default mode is `local_decrypt_shim`. The hosted service returns sealed titles, snippets, and encrypted body pages — **plaintext decrypt happens on-device**, never on the server. Silent hosted plaintext decryption is not implemented.

### Auth and entitlement

- Requires active `users/{uid}/entitlements/burnbar_pro` in Firestore
- OAuth token issuance: `functions/src/remoteMcpOAuth.ts`
- Grant management (create, revoke per-client): `functions/src/remoteMcpGrant.ts`
- Tokens are short-lived; grants can be revoked without revoking Firebase Auth

## Integration points

- **Cloud sync** — hosted search index upload requires BurnBar Pro subscription and cloud sync opt-in.
- **Usage tracking** — `burnbar_recent_usage` reads the same usage rows stored in Firestore by `UsageSyncService`.
- **Insights** — search results can be consumed by the `InsightEngine` for benchmark-aware rule evaluation.
- **Hermes chat** — follow-up questions can route through MCP tools for deep session queries.
- **Computer Use** — trusted-scope rules can reference MCP tool capabilities for agent delegation.

## Entry points for modification

- **Add a new MCP tool** — register it in `services/hosted-mcp/src/toolRegistry.ts`, add the handler, and update the local bridge.
- **Change privacy mode** — edit `tools/openburnbar-mcp-remote/src/privacy.ts` and the grant mode validation in `functions/src/callables/remoteMcp.ts`.
- **Update auth requirements** — modify `functions/src/remoteMcpOAuth.ts` token lifetimes or `functions/src/remoteMcpGrant.ts` scope validation.
- **Add client compatibility** — extend `scripts/test-hosted-mcp-compatibility.sh`.
- **Fix security issues** — run `scripts/test-hosted-mcp-security.sh` and `scripts/prove-hosted-mcp-privacy-scan.mjs`.

## Local verification

```bash
npm ci --prefix services/hosted-mcp
npm --prefix services/hosted-mcp run build
npm --prefix services/hosted-mcp test

npm ci --prefix tools/openburnbar-mcp-remote
npm --prefix tools/openburnbar-mcp-remote test

./scripts/test-hosted-mcp-security.sh
./scripts/test-hosted-mcp-compatibility.sh
```

## Local MCP bridge (non-Pro)

`tools/openburnbar-mcp/` is a separate read-only MCP bridge to local SQLite — no Pro subscription required. It exposes tools for querying conversations, usage data, and artifacts directly from the on-device database. This is distinct from the hosted remote MCP and does not require Firebase Auth.

---

Cross-links:
- [Cloud sync](cloud-sync.md)
- [Usage tracking](usage-tracking.md)
- [Insights](insights.md)
- [Hermes chat](hermes-chat.md)
- [Computer Use](computer-use.md)
