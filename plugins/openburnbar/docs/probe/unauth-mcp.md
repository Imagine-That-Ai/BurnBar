# Probe: hosted MCP authentication surface (unauthenticated)

Captured 2026-08-16 against production. Hosted MCP: `https://mcp.burnbar.ai/mcp`,
protocol header `MCP-Protocol-Version: 2025-11-25`. No `Authorization` header on
the unauthenticated requests. No device codes were minted and no tokens are
present in this transcript.

This transcript backs the auth decision locked in
[`AUTH.md`](../../AUTH.md): GitHub-style bearer plugin variable, no OAuth
Connect, no DCR, and no stdio server in the marketplace `mcp.json`.

## 1. Unauthenticated `initialize` → 401 `missing_auth` + `WWW-Authenticate`

Request (headers shown are the complete request surface; no bearer):

```
POST https://mcp.burnbar.ai/mcp
MCP-Protocol-Version: 2025-11-25
Content-Type: application/json
Accept: application/json, text/event-stream

{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"auth-probe-honesty","version":"1.0.0"}}}
```

Response:

```
HTTP/2 401
content-type: application/json; charset=utf-8
www-authenticate: Bearer resource_metadata="https://mcp.burnbar.ai/.well-known/oauth-protected-resource"
```

Body:

```json
{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Missing OpenBurnBar MCP bearer token.","data":{"code":"missing_auth"}}}
```

No successful initialize result is returned.

## 2. Protected-resource metadata (from the `WWW-Authenticate` challenge)

```
GET https://mcp.burnbar.ai/.well-known/oauth-protected-resource
```

`HTTP/2 200`:

```json
{"resource":"https://mcp.burnbar.ai/mcp","authorization_servers":["https://mcp.burnbar.ai"],"scopes_supported":["search:read","conversation:read","usage:read","index:status"],"bearer_methods_supported":["header"],"resource_documentation":"https://burnbar.ai/docs/remote-mcp"}
```

Note: `scopes_supported` is exactly the default grant scope set
`search:read`, `conversation:read`, `usage:read`, `index:status`.

## 3. Authorization-server well-known document

The AS well-known is at the standard RFC 8414 path on the advertised
`authorization_servers` origin (`https://mcp.burnbar.ai`):

```
GET https://mcp.burnbar.ai/.well-known/oauth-authorization-server
```

`HTTP/2 200`:

```json
{"issuer":"https://mcp.burnbar.ai","token_endpoint":"https://mcp.burnbar.ai/oauth/token","grant_types_supported":["refresh_token"],"scopes_supported":["search:read","conversation:read","usage:read","index:status"],"token_endpoint_auth_methods_supported":["none"]}
```

`grant_types_supported` is exactly `["refresh_token"]` — no
`authorization_code`, no `client_credentials`. The AS offers a refresh
mechanism only; it does not implement the browser-authorize flow a
Linear-style URL-only OAuth Connect plugin needs.

## 4. Dynamic client registration (DCR) is not offered

```
GET  https://mcp.burnbar.ai/oauth/register  → HTTP/2 404  {"error":"not_found"}
POST https://mcp.burnbar.ai/oauth/register  → HTTP/2 404  {"error":"not_found"}
```

No registration document, no 2xx.

## 5. No OAuth authorize endpoint

```
GET https://mcp.burnbar.ai/oauth/authorize?client_id=x&redirect_uri=https://example.com/cb&response_type=code
  → HTTP/2 404  {"error":"not_found"}
```

No login or consent redirect. URL-only OAuth Connect cannot work against
this server.

## 6. Unauthenticated `tools/list` and `tools/call` cannot bypass the 401

`tools/list`:

```
POST https://mcp.burnbar.ai/mcp  (MCP-Protocol-Version: 2025-11-25, no Authorization)
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
→ HTTP/2 401
  www-authenticate: Bearer resource_metadata="https://mcp.burnbar.ai/.well-known/oauth-protected-resource"
  {"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Missing OpenBurnBar MCP bearer token.","data":{"code":"missing_auth"}}}
```

`tools/call` (`burnbar_resolve_capabilities`, an always-visible metadata tool):

```
POST https://mcp.burnbar.ai/mcp  (MCP-Protocol-Version: 2025-11-25, no Authorization)
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"burnbar_resolve_capabilities","arguments":{}}}
→ HTTP/2 401
  {"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Missing OpenBurnBar MCP bearer token.","data":{"code":"missing_auth"}}}
```

Neither method leaks a tool list or a result to an anonymous caller.

## 7. Garbage bearer still 401 (placeholder only)

The only bearer used in any probe is the placeholder below; no real token was
ever sent or recorded.

```
POST https://mcp.burnbar.ai/mcp  (MCP-Protocol-Version: 2025-11-25)
Authorization: Bearer not-a-real-openburnbar-token
{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"auth-probe-honesty","version":"1.0.0"}}}
→ HTTP/2 401
  {"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Malformed OpenBurnBar MCP Ed25519 access token.","data":{"code":"malformed_token"}}}
```

Malformed/garbage bearer values are rejected with 401 before any result is
returned.

## 8. Wrong-host CLI start trap

`https://mcp.burnbar.ai/api/cli-link/start` is **not** the device-code start
route:

```
POST https://mcp.burnbar.ai/api/cli-link/start  → HTTP/2 404  {"error":"not_found"}
GET  https://mcp.burnbar.ai/api/cli-link/start  → HTTP/2 404  {"error":"not_found"}
```

The real start route lives on the website host, `https://burnbar.ai/api/cli-link/start`
(see [`link-appcheck.md`](./link-appcheck.md)). The unpublished CLI derives the
start URL from the MCP host by default, which is why the operator must override
the endpoint (see `AUTH.md`).
