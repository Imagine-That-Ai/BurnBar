# Remote MCP Threat Model

## Assets

- BurnBar Pro entitlement state.
- MCP access and refresh tokens.
- Encrypted session bodies in Firebase Storage.
- Sealed title/snippet/body-preview envelopes in Firestore.
- Opaque token and semantic hashes.
- Cloud vault key wrappers.
- Audit and rate-limit metadata.
- Project source-code indexes are a separate asset class. They are local-only
  by default and are not accepted by hosted Remote MCP until a code-specific
  threat-model review ships.

## Trust Boundaries

- Third-party MCP clients are not trusted with Firebase ID tokens or vault keys
  in config files.
- Hosted MCP is a resource server, not a provider credential broker.
- The local shim is trusted only on the user's device and should keep tokens in
  Keychain where possible.
- Firebase Admin SDK paths are always rooted from the token subject.

## Required Controls

- Bearer tokens are audience-bound to `https://mcp.burnbar.ai/mcp`.
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

## Code Asset Class

Hosted code memory is disabled by default and is not covered by the prose-memory
launch gate. It can only be enabled after the code asset-class review passes.

Required code-specific controls:

- Tool visibility is gated by `OPENBURNBAR_HOSTED_CODE_MEMORY_TOOLS=true`;
  default hosted deployments hide and deny `burnbar_search_code` and
  `burnbar_get_code_document`.
- Code search requires `code:read`, a vault-keyed `projectHmac`, and a pinned
  `embeddingModelVersion`.
- General knowledge search refuses `sourceKind = code`; code rows are only
  reachable through the code tools.
- Hosted code responses are sealed-only: `sealedCiphertext` and
  `sealedMetadata` may leave the service, but raw source text, file paths,
  snippets, symbols, public embeddings, and content hashes must not.
- Logs may include hashed grant/client metadata and coarse counters only. They
  must not include source text, raw paths, query text, project names, or code
  HMAC preimages.
- Forget must be hard-delete by vault-keyed project/chunk HMAC with a receipt;
  pending deletes must remain visible in local doctor/status.

## Abuse Cases

| Case | Control |
| --- | --- |
| Free user calls hosted MCP | entitlement check at grant and tool call |
| Revoked client keeps using refresh token | grant/client revoked server-side |
| Token replay against another service | audience validation |
| Cross-tenant resource URI | resource path comes from token `sub` |
| Prompt injection in transcript text | transcript text remains encrypted server-side |
| Hosted code-memory sync leaks source structure | code-memory sync is disabled by default; local MCP indexes code only on device |
| DNS rebinding against local/remote server | `Origin` validation |
| Log exfiltration | structured redaction and audit allowlist |
| Cost spike | rate limits, result caps, zero Storage reads during search |

## Launch Blockers

Production launch remains blocked until live paid, unpaid, revoked, expired,
wrong-audience, cross-tenant, malformed-cursor, oversized-query, deleted-body,
and log-leak proofs are run against the deployed endpoint.
