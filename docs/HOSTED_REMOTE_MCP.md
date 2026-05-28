# Hosted Remote MCP

OpenBurnBar Hosted Remote MCP is a BurnBar Pro cloud service that lets coding
agents search a user's encrypted hosted session memory.

The production endpoint is:

```text
https://mcp.burnbar.ai/mcp
```

## Architecture

- `services/hosted-mcp` is the Cloud Run resource server.
- Firebase Functions issue OpenBurnBar MCP grants and short-lived bearer tokens.
- Firestore stores client/grant/rate-limit/audit metadata under the signed-in
  user's namespace.
- Firebase Storage stores encrypted session bodies only.
- `tools/openburnbar-mcp-remote` is the local stdio bridge for clients that do
  not support remote Streamable HTTP MCP or need device-side decrypt.

The hosted service implements the 2025-11-25 MCP Streamable HTTP shape:
`initialize`, `tools/list`, `tools/call`, `resources/list`, and
`resources/read`. It validates `Origin`, rejects missing bearer auth with
`WWW-Authenticate`, bounds request/response sizes, and returns JSON-RPC errors.

## Tools

- `burnbar_search_conversations`
- `burnbar_get_conversation_body`
- `burnbar_list_search_index_status`
- `burnbar_list_search_facets`
- `burnbar_recent_usage`
- `burnbar_list_resumable_conversations`
- `burnbar_resume_conversation`
- `burnbar_resolve_capabilities`

Every tool has required scopes, an entitlement check, a rate-limit bucket, a
bounded schema, and audit metadata. Tool inputs never accept `uid` or arbitrary
Firestore/Storage paths; the token `sub` selects the user namespace.

## Privacy Mode

The default mode is `local_decrypt_shim`.

The hosted service searches opaque token/semantic hashes and returns sealed
titles, snippets, previews, and encrypted body pages. Plaintext decrypt happens
inside OpenBurnBar or the local shim after the user has an allowed vault-key
wrapper. Silent hosted plaintext decrypt is not implemented.

Hosted resume follows the same rule. The server composes only a sealed resume
envelope; `openburnbar-mcp-remote resume ...` checks for a local vault key before
the network call, decrypts the envelope on-device, verifies chunk hashes, then
prints, copies, opens, or explicitly spawns the rendered resume locally. Fuzzy
resume via `OBB Resume "memory"` sends locally derived opaque query hashes, not
the raw memory text, and renders a ranked local candidate list with decrypted
titles/snippets plus exact resume commands.
See [BurnBar Resume](BURNBAR_RESUME.md) for the local, hosted, daemon CLI, and
Mac app behavior.

## Entitlement

Remote MCP requires active `users/{uid}/entitlements/burnbar_pro`. The legacy
`hosted_quota_sync` entitlement remains accepted only for compatibility in
shared entitlement readers. Tokens are short-lived and grants can be revoked per
client.

## Local Verification

```bash
npm ci --prefix services/hosted-mcp
npm --prefix services/hosted-mcp run build
npm --prefix services/hosted-mcp test

npm ci --prefix tools/openburnbar-mcp-remote
npm --prefix tools/openburnbar-mcp-remote test
./scripts/test-hosted-mcp-security.sh
./scripts/test-hosted-mcp-compatibility.sh
```
