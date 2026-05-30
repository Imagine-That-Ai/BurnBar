# Remote MCP

BurnBar Pro feature: hosted encrypted semantic search for AI coding agents via the Model Context Protocol.

Full documentation: [`docs/HOSTED_REMOTE_MCP.md`](../../docs/HOSTED_REMOTE_MCP.md)

---

## Purpose

Coding agents (Claude Code, Codex, Cursor) can query a user's OpenBurnBar session history and usage data directly from within their context window. Instead of the agent guessing at spend or asking the user, it calls a BurnBar MCP tool and gets structured data back.

---

## Two components

### 1. `tools/openburnbar-mcp-remote/` — local stdio bridge

A local stdio shim for clients that do not support remote Streamable HTTP MCP (e.g., Cursor). It:
- Proxies tool calls to the hosted Cloud Run service
- Handles device-side decryption of encrypted session body pages
- Verifies chunk hashes before presenting decrypted content to the agent
- Supports `OBB Resume` — sends locally derived opaque query hashes (not raw memory text) to preserve privacy

### 2. `services/hosted-mcp/` — Cloud Run resource server

The production endpoint is `https://mcp.burnbar.ai/mcp`. It implements the 2025-11-25 MCP Streamable HTTP shape: `initialize`, `tools/list`, `tools/call`, `resources/list`, `resources/read`.

Security controls:
- Validates `Origin` header on all requests
- Rejects missing bearer auth with `WWW-Authenticate`
- Bounds request and response sizes
- Tool inputs never accept `uid` or arbitrary Firestore/Storage paths — the bearer token `sub` selects the user namespace
- Rate-limit buckets per tool

---

## Available tools

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

---

## Privacy mode

Default mode is `local_decrypt_shim`. The hosted service returns sealed titles, snippets, and encrypted body pages — **plaintext decrypt happens on-device**, never on the server. Silent hosted plaintext decryption is not implemented.

---

## Auth and entitlement

- Requires active `users/{uid}/entitlements/burnbar_pro` in Firestore
- OAuth token issuance: `functions/src/remoteMcpOAuth.ts`
- Grant management (create, revoke per-client): `functions/src/remoteMcpGrant.ts`
- Tokens are short-lived; grants can be revoked without revoking Firebase Auth

---

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

---

## Local MCP bridge (non-Pro)

`tools/openburnbar-mcp/` is a separate read-only MCP bridge to local SQLite — no Pro subscription required. It exposes tools for querying conversations, usage data, and artifacts directly from the on-device database. This is distinct from the hosted remote MCP and does not require Firebase Auth.
