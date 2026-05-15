# Remote MCP Threat Model

## Assets

- BurnBar Pro entitlement state.
- MCP access and refresh tokens.
- Encrypted session bodies in Firebase Storage.
- Sealed title/snippet/body-preview envelopes in Firestore.
- Opaque token and semantic hashes.
- Cloud vault key wrappers.
- Audit and rate-limit metadata.

## Trust Boundaries

- Third-party MCP clients are not trusted with Firebase ID tokens or vault keys
  in config files.
- Hosted MCP is a resource server, not a provider credential broker.
- The local shim is trusted only on the user's device and should keep tokens in
  Keychain where possible.
- Firebase Admin SDK paths are always rooted from the token subject.

## Required Controls

- Bearer tokens are audience-bound to `https://mcp.openburnbar.com/mcp`.
- Token claims include `sub`, `client_id`, `scopes`, `entitlement_family`,
  `grant_mode`, `exp`, and `jti`.
- Tool calls recheck entitlement and scopes.
- Request body, output, search fanout, body page size, and rate limits are
  bounded.
- Logs and audit events hash identifiers and never store raw query text,
  snippets, bodies, bearer tokens, refresh tokens, signed URLs, provider
  credentials, or vault keys.
- Firestore rules deny client writes to remote MCP grants, audit events,
  rate-limit counters, and search index manifests.

## Abuse Cases

| Case | Control |
| --- | --- |
| Free user calls hosted MCP | entitlement check at grant and tool call |
| Revoked client keeps using refresh token | grant/client revoked server-side |
| Token replay against another service | audience validation |
| Cross-tenant resource URI | resource path comes from token `sub` |
| Prompt injection in transcript text | transcript text remains encrypted server-side |
| DNS rebinding against local/remote server | `Origin` validation |
| Log exfiltration | structured redaction and audit allowlist |
| Cost spike | rate limits, result caps, zero Storage reads during search |

## Launch Blockers

Production launch remains blocked until live paid, unpaid, revoked, expired,
wrong-audience, cross-tenant, malformed-cursor, oversized-query, deleted-body,
and log-leak proofs are run against the deployed endpoint.
