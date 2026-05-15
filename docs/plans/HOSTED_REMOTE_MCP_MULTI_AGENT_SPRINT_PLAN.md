# Hosted Remote MCP Multi-Agent Sprint Plan

Date: 2026-05-14

## TL;DR

Alberto wants OpenBurnBar Pro subscribers to get a hosted remote MCP server that
works from any serious coding-agent harness: Codex, Claude Code, Droid/Factory,
Kimi, Forge CLI, and generic MCP clients.

In easy English:

- A paying OpenBurnBar user should be able to add `OpenBurnBar MCP` to whatever
  coding agent they use.
- That MCP should let the agent search the user's indexed session history across
  all models, providers, and harnesses.
- The service must be paywalled by the user's OpenBurnBar subscription.
- The hosted database is Firebase/Firestore/Firebase Storage, but the system must
  preserve the privacy promise: session bodies stay encrypted in cloud storage;
  sensitive decrypt work happens on trusted devices or an explicitly approved
  local helper.
- For clients that support remote Streamable HTTP MCP, they connect directly to
  the hosted server.
- For stdio-only clients or privacy-sensitive decrypt flows, OpenBurnBar ships a
  local `openburnbar-mcp-remote` shim that talks to the hosted service and
  decrypts locally.
- The launch bar is production proof: live hosted endpoint, real subscription
  enforcement, real client compatibility tests, real negative tests, docs,
  monitoring, rollback, and a multi-agent audit.

This is an addition to BurnBar Pro. It does not replace Hosted Quota. BurnBar
Pro becomes:

1. Hosted quota.
2. Hosted MiniMax-backed intelligence.
3. Searchable encrypted hosted session logs.
4. Hosted remote MCP access to that searchable session memory.

## Source-Of-Truth Product Goal

Build and deploy OpenBurnBar's hosted remote MCP service as a paid BurnBar Pro
feature. The service gives coding agents controlled access to a user's
cross-provider session memory, using the indexed encrypted hosted session logs
already being added to Firebase.

The product must work across:

- Codex
- Claude Code
- Droid / Factory
- Kimi CLI
- Forge CLI
- Generic MCP clients
- Future clients that support MCP Streamable HTTP, OAuth, or stdio adapters

The service must not be a one-client integration. It is an OpenBurnBar platform
capability.

## Non-Negotiable Decisions

### 1. Remote MCP Is Standards-First

The hosted service exposes a standards-compatible MCP Streamable HTTP endpoint:

```text
https://mcp.openburnbar.com/mcp
```

The server supports:

- `initialize`
- `tools/list`
- `tools/call`
- `resources/list`
- `resources/read`
- `MCP-Protocol-Version`
- `WWW-Authenticate` challenges
- OAuth protected-resource metadata
- HTTPS only
- origin validation
- structured JSON-RPC errors
- bounded output sizes
- timeout-safe responses

References the implementation must track:

- MCP Streamable HTTP transport: `https://modelcontextprotocol.io/specification/2025-11-25/basic/transports`
- MCP authorization: `https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization`
- MCP security guidance: `https://modelcontextprotocol.io/docs/tutorials/security/security_best_practices`
- Claude Code MCP docs: `https://code.claude.com/docs/en/mcp`
- Factory MCP docs: `https://docs.factory.ai/cli/configuration/mcp`
- OpenAI MCP docs: `https://platform.openai.com/docs/mcp/`

### 2. The Paywall Is OpenBurnBar Pro

The canonical entitlement is:

```text
users/{uid}/entitlements/burnbar_pro
```

Legacy `hosted_quota_sync` can be accepted only where existing compatibility
requires it. New hosted remote MCP access should be sold, described, and audited
as a BurnBar Pro feature.

Rules:

- No active paid entitlement means no MCP search.
- Entitlement is checked at token mint.
- Entitlement is rechecked on refresh.
- Entitlement is rechecked for high-cost calls.
- Positive entitlement cache is short, target max 60 seconds.
- Negative entitlement cache is shorter, target max 15 seconds.
- Cancellation, refund, or subscription expiry must remove access quickly.

### 3. Firebase ID Tokens Are Not The MCP Bearer Token

Third-party MCP clients must not be asked to paste Firebase ID tokens or vault
keys into config files.

Correct shape:

1. User opens OAuth login from the MCP client or local installer.
2. User authenticates with OpenBurnBar-owned auth UI.
3. Auth broker verifies Firebase Auth server-side.
4. Broker verifies BurnBar Pro entitlement.
5. Broker mints short-lived OpenBurnBar MCP access tokens.
6. MCP server validates those OpenBurnBar MCP tokens.

MCP access token claims must include:

- `sub`: Firebase `uid`
- `aud`: hosted MCP resource audience
- `client_id`
- `scopes`
- `entitlement_family`
- `grant_mode`
- `exp`
- `jti`

### 4. Hosted MCP Does Not Get Provider Credentials

Remote MCP is session-memory access, not provider credential routing.

The hosted MCP server must never receive:

- Claude Code OAuth/setup tokens
- OpenCode auth JSON
- browser cookies
- raw provider API keys
- local filesystem access
- vault keys in plaintext
- arbitrary user-supplied Firebase paths

Provider quota policy remains separate:

- Codex hosted quota can remain hosted where already implemented.
- Claude Code hosted credential collection remains disallowed.
- OpenCode hosted credential collection remains disallowed.
- Claude/OpenCode quota can remain self-hosted where the user controls their own
  runner.

### 5. Privacy Requires A Two-Tier MCP Architecture

There are two surfaces:

```text
Direct remote MCP:
  client -> https://mcp.openburnbar.com/mcp -> Firebase encrypted index

Local decrypt shim:
  client -> local stdio MCP shim -> hosted MCP/Firebase -> local device decrypt
```

The default privacy-preserving architecture is:

- Firestore stores sealed metadata and opaque search signals.
- Firebase Storage stores encrypted session bodies.
- The server searches opaque token/semantic postings.
- The server returns encrypted envelopes, references, and safe metadata.
- The local shim or trusted app decrypts readable titles/snippets/bodies on
  device.

If a future `remote-readable` mode is offered, it must be explicit, opt-in,
revocable, audited, and separately labeled. Do not ship silent hosted
server-side decryption.

### 6. Search Must Be Fast Enough To Feel Native

Target budgets:

- Warm p50 search: under 300 ms.
- Warm p95 search: under 900 ms.
- Body fetch p95: under 2.5 s for normal transcripts.
- Firestore reads per ordinary search: target under 40, hard cap 150.
- Storage reads per search: 0.
- Storage reads per explicit body fetch: 1.
- Result cap: default 10 or 25, max 50.
- Query fanout cap: roughly 10 lexical hashes and 12 semantic hashes.

Search must not scan a user's whole Firestore corpus.

### 7. Every Tool Is Deny-By-Default

Every MCP tool declares:

- required scopes
- entitlement requirement
- input schema
- max input size
- max output size
- cost class
- rate-limit bucket
- audit event kind
- content redaction policy

No tool can choose its own auth behavior ad hoc.

## Target Architecture

```text
+----------------------+        +-----------------------------+
| Coding agent client  |        | Local decrypt shim          |
| Codex / Claude / ... |<------>| openburnbar-mcp-remote      |
+----------+-----------+ stdio  +--------------+--------------+
           |                                     |
           | Streamable HTTP MCP                 | HTTPS / OAuth
           v                                     v
+--------------------------------------------------------------+
| Hosted MCP Cloud Run service                                 |
| services/hosted-mcp                                          |
|                                                              |
| - MCP protocol adapter                                       |
| - OAuth bearer validation                                    |
| - entitlement gate                                           |
| - tool registry                                              |
| - search planner                                             |
| - cursor signer                                              |
| - audit logger                                               |
| - rate limiter                                               |
+------------------------------+-------------------------------+
                               |
                               v
+--------------------------------------------------------------+
| Firebase / GCP                                                |
|                                                              |
| Firestore:                                                    |
| - entitlements                                                |
| - cloud_search_index_manifest                                |
| - cloud_search_documents                                     |
| - cloud_search_chunks                                        |
| - cloud_search_postings                                      |
| - cloud_vault_key_wrappers                                   |
| - remote_mcp_audit_events                                    |
|                                                              |
| Firebase Storage:                                             |
| - encrypted session bodies                                   |
|                                                              |
| Secret Manager / KMS:                                         |
| - service secrets only                                       |
+--------------------------------------------------------------+
```

## Data Model Additions

### Firestore

Add or formalize:

```text
users/{uid}/cloud_search_index_manifest/current
users/{uid}/remote_mcp_clients/{clientId}
users/{uid}/remote_mcp_grants/{grantId}
users/{uid}/remote_mcp_audit_events/{eventId}
users/{uid}/remote_mcp_rate_limits/{bucketId}
```

`cloud_search_index_manifest/current`:

- active commit IDs by device
- latest committed timestamp
- schema version
- index version
- document count
- chunk count
- token posting count
- semantic posting count
- stale/error status
- compaction status

`remote_mcp_clients/{clientId}`:

- client display name
- client type
- hashed install fingerprint
- created at
- last used at
- allowed scopes
- grant mode
- revoked at

`remote_mcp_grants/{grantId}`:

- client ID
- scopes
- token family hash
- refresh token hash
- expires at
- revoked at
- entitlement snapshot

`remote_mcp_audit_events/{eventId}`:

- event kind
- trace ID
- hashed client ID
- hashed IP prefix
- hashed user agent
- scopes
- tool name
- result count
- deny reason
- entitlement source
- token `jti`
- opaque query hash count
- latency bucket
- cost bucket

Never store in audit logs:

- raw prompt text
- raw search query text
- raw snippets
- raw session body
- Firebase ID tokens
- OAuth codes
- refresh tokens
- vault keys
- signed URLs
- provider credentials

## MCP Tool Surface

Initial tools:

```text
burnbar_search_conversations
burnbar_get_conversation_body
burnbar_list_search_index_status
burnbar_list_search_facets
burnbar_recent_usage
burnbar_resolve_capabilities
```

### `burnbar_search_conversations`

Purpose: Search the user's indexed session memory.

Inputs:

- `query`
- `provider`
- `model`
- `projectName`
- `harness`
- `from`
- `to`
- `limit`
- `cursor`
- `includeBodyPreview`

Behavior:

- Requires active BurnBar Pro.
- Requires `search:read`.
- Uses the token `sub` as uid; never accepts uid input.
- Plans lexical and semantic candidate reads.
- Reads active commit generations only.
- Does no Storage reads.
- Returns bounded results with stable opaque resource IDs.
- In sealed-only mode, returns sealed snippets and tells the client to use the
  local shim for decrypted previews.

### `burnbar_get_conversation_body`

Purpose: Fetch one full session body after search.

Inputs:

- `resourceUri`
- `maxChars`
- `cursor`

Behavior:

- Requires active BurnBar Pro.
- Requires `conversation:read`.
- Requires explicit user/session-scoped resource ID returned from search.
- Reads at most one Storage object per page.
- Verifies body hash.
- Returns encrypted body to local shim by default.
- Local shim decrypts and chunks for the agent.

### `burnbar_list_search_index_status`

Purpose: Explain freshness and coverage.

Behavior:

- Requires active BurnBar Pro.
- Returns latest commit time, devices, document count, chunk count, stale state,
  and sync warnings.
- Does not expose secrets.

### `burnbar_list_search_facets`

Purpose: Let agents narrow search without hallucinating provider/project names.

Inputs:

- `kind`: `provider`, `model`, `project`, `harness`

Behavior:

- Returns bounded counts.
- Uses manifest/facet docs, not full scans.

### `burnbar_recent_usage`

Purpose: Let agents correlate session memory with recent provider/model use.

Behavior:

- Read-only.
- Scopes separate from conversation body access.
- Does not expose provider tokens.

### `burnbar_resolve_capabilities`

Purpose: Let a client know which mode is active.

Returns:

- active subscription state
- hosted MCP availability
- decrypt mode
- supported tools
- max limits
- stale index warning
- compatibility notes

## Client Compatibility Matrix

| Client | Preferred path | Fallback path | Installer output | Required proof |
| --- | --- | --- | --- | --- |
| Codex | Streamable HTTP remote MCP | local stdio shim | `codex mcp add openburnbar --url https://mcp.openburnbar.com/mcp` | login, tools/list, search, body fetch |
| Claude Code | Streamable HTTP if supported | local stdio shim | `claude mcp add --transport http openburnbar https://mcp.openburnbar.com/mcp` | OAuth, tools/list, timeout-free search |
| Droid / Factory | HTTP MCP config | local stdio shim | `.factory/mcp.json` or `droid mcp add` | list tools and run search |
| Kimi CLI | HTTP MCP if supported | local stdio shim | `kimi mcp add ...` or JSON config | list tools and run search |
| Forge CLI | imported MCP JSON | local stdio shim | `forge mcp import ...` | list tools and run search |
| Generic MCP | Streamable HTTP | local stdio bridge | `mcpServers` JSON | initialize, tools/list, tools/call |

The installer command should be:

```bash
openburnbar mcp install <codex|claude|droid|kimi|forge|generic>
```

The doctor command should be:

```bash
openburnbar mcp doctor
```

Doctor verifies:

- endpoint reachability
- OAuth/login state
- subscription entitlement
- token expiry
- supported protocol version
- tool listing
- search smoke
- body fetch smoke
- decrypt mode
- local shim keychain access
- index freshness

## Implementation Artifacts

Add:

```text
services/hosted-mcp/package.json
services/hosted-mcp/tsconfig.json
services/hosted-mcp/Dockerfile
services/hosted-mcp/src/server.ts
services/hosted-mcp/src/mcp.ts
services/hosted-mcp/src/auth.ts
services/hosted-mcp/src/oauthMetadata.ts
services/hosted-mcp/src/entitlements.ts
services/hosted-mcp/src/toolRegistry.ts
services/hosted-mcp/src/search.ts
services/hosted-mcp/src/resources.ts
services/hosted-mcp/src/cursors.ts
services/hosted-mcp/src/rateLimits.ts
services/hosted-mcp/src/audit.ts
services/hosted-mcp/src/logging.ts
services/hosted-mcp/src/redaction.ts
services/hosted-mcp/test/*.test.ts
services/hosted-mcp/test/fixtures/*

tools/openburnbar-mcp-remote/package.json
tools/openburnbar-mcp-remote/src/index.ts
tools/openburnbar-mcp-remote/src/oauth.ts
tools/openburnbar-mcp-remote/src/shim.ts
tools/openburnbar-mcp-remote/src/decrypt.ts
tools/openburnbar-mcp-remote/src/installers.ts
tools/openburnbar-mcp-remote/src/doctor.ts
tools/openburnbar-mcp-remote/test/*.test.ts

functions/src/cloudSearchCore.ts
functions/src/remoteMcpGrant.ts
functions/src/remoteMcpOAuth.ts
functions/scripts/prove-hosted-mcp-live.mjs

scripts/deploy-hosted-mcp.sh
scripts/test-hosted-mcp-compatibility.sh
scripts/test-hosted-mcp-security.sh

docs/HOSTED_REMOTE_MCP.md
docs/REMOTE_MCP_THREAT_MODEL.md
docs/REMOTE_MCP_RUNBOOK.md
docs/REMOTE_MCP_CLIENT_SETUP.md
```

Update:

```text
docs/HOSTED_QUOTA_SYNC.md
docs/OPENBURNBAR_SEARCH_ARCHITECTURE_SPINE.md
README.md
CHANGELOG.md
firestore.rules
firestore.indexes.json
.github/workflows/*
```

## Multi-Wave Sprint

### Wave 0: Baseline, Spec Lock, And Worktree Hygiene

Goal: start from truth, not assumption.

Streams:

- Architecture lead: read current hosted search, MCP, entitlement, quota, and
  relay docs.
- Protocol researcher: verify latest MCP transport/auth/client behavior.
- Security lead: map trust boundaries and subscription gates.
- QA lead: inventory existing tests and live proof scripts.

Tasks:

1. Capture clean baseline SHA.
2. Record dirty files and confirm whether they are unrelated.
3. Confirm existing local MCP behavior.
4. Confirm existing encrypted hosted search data path.
5. Confirm subscription entitlement docs and Stripe/App Store/Play gates.
6. Write a one-page implementation contract.

DOD:

- Baseline SHA captured.
- Relevant docs and source files mapped.
- No implementation starts before the privacy mode is explicit.
- Issue tracker or sprint checklist exists.

### Wave 1: Trust Boundary And Product Consent

Goal: define what the server can see.

Streams:

- Product/design: user-facing consent language.
- Security/privacy: threat model and data classification.
- Backend: grant model and scope model.
- Docs: update service mental model.

Decisions:

- Ship `sealed-only + local decrypt shim` as default.
- Do not ship silent hosted plaintext decrypt.
- Consider `remote-readable` only as future opt-in, with separate copy,
  telemetry, revocation, and legal review.

Tasks:

1. Define grant modes:
   - `sealed_only`
   - `local_decrypt_shim`
   - future `remote_readable_explicit_opt_in`
2. Define scopes:
   - `search:read`
   - `conversation:read`
   - `usage:read`
   - `index:status`
3. Add UI copy for app settings:
   - what is uploaded
   - what is encrypted
   - what agents can access
   - how to revoke
   - what the hosted service cannot see
4. Add remote MCP threat model.

DOD:

- No ambiguous privacy promise remains.
- Subscriber understands what the MCP can search.
- Subscriber can revoke every MCP client.
- Security doc states the server-side plaintext policy.

### Wave 2: Hosted MCP Cloud Run Service

Goal: create the production remote MCP endpoint.

Owner files:

```text
services/hosted-mcp/*
scripts/deploy-hosted-mcp.sh
```

Streams:

- Backend worker A: HTTP server, MCP protocol adapter, health checks.
- Backend worker B: auth middleware, entitlement checks, tool registry.
- Backend worker C: structured logging, redaction, rate limits.
- QA worker: protocol tests and HTTP negative tests.

Tasks:

1. Create Node 22 TypeScript Cloud Run service.
2. Add `/healthz`, `/readyz`, `/mcp`.
3. Implement Streamable HTTP request handling.
4. Implement MCP initialize/tools/list/tools/call/resources/list/resources/read.
5. Implement origin validation.
6. Implement protocol version negotiation.
7. Implement bounded request body size.
8. Implement structured JSON-RPC errors.
9. Add deploy script using existing Cloud Run style.

DOD:

- Local service starts.
- Unit tests pass.
- Protocol smoke passes.
- Invalid origin returns `403`.
- Missing auth returns `401`.
- Unknown tool returns structured MCP error.
- Oversized input returns bounded error.
- No plaintext logs.

### Wave 3: OAuth Broker, Tokens, And Subscription Gate

Goal: make access subscription-gated and client-safe.

Owner files:

```text
functions/src/remoteMcpOAuth.ts
functions/src/remoteMcpGrant.ts
services/hosted-mcp/src/auth.ts
services/hosted-mcp/src/entitlements.ts
firestore.rules
```

Streams:

- Auth worker: OAuth metadata, auth-code + PKCE, token exchange.
- Entitlement worker: BurnBar Pro checks, revocation, short TTL cache.
- Rules worker: Firestore rules for grant/client/audit docs.
- QA/security worker: paid/unpaid/revoked/cross-user tests.

Tasks:

1. Add OAuth protected-resource metadata.
2. Add authorization-server metadata if OpenBurnBar hosts broker endpoints.
3. Implement PKCE auth-code flow.
4. Implement device-friendly flow only if needed by CLI clients.
5. Mint short-lived MCP access tokens.
6. Store hashed refresh tokens only.
7. Bind tokens to audience and client ID.
8. Enforce `burnbar_pro`.
9. Reject Firebase ID tokens as final MCP bearer tokens.
10. Add client revocation.
11. Add audit events for grant, refresh, revoke, denied access.

DOD:

- Paid user can mint MCP token.
- Unpaid user cannot mint token.
- Expired subscription loses access within target TTL.
- Revoked client loses access immediately or within target TTL.
- Token audience mismatch fails.
- Token in query string is rejected.
- Refresh token plaintext is never stored.
- Firestore rules prevent client entitlement writes.

### Wave 4: Shared Hosted Search Core

Goal: expose fast indexed hosted search without duplicating brittle logic.

Owner files:

```text
functions/src/cloudSearchCore.ts
functions/src/index.ts
services/hosted-mcp/src/search.ts
services/hosted-mcp/src/resources.ts
firestore.indexes.json
```

Streams:

- Search worker A: extract shared search planner/core.
- Search worker B: manifest and freshness model.
- Search worker C: cursor and pagination.
- QA worker: encrypted search regression tests.

Tasks:

1. Extract Firestore search logic from callable code into shared core.
2. Ensure hosted MCP does not call App Check-protected callables internally.
3. Add `cloud_search_index_manifest/current`.
4. Ensure token postings and semantic postings are both written.
5. Search active generations only.
6. Batch hydrate top-K docs/chunks.
7. Add signed opaque cursors.
8. Add provider/model/project/harness filters.
9. Add facets.
10. Add stale index detection.

DOD:

- Search performs zero Storage reads.
- Search reads only active commit generations.
- Search has bounded Firestore reads.
- Search does not return plaintext from Firestore.
- No raw uid/path arguments accepted.
- Cursor cannot be tampered with.
- Manifest avoids scanning many device states.
- Tests cover empty, huge, stale, duplicate, malformed, and cross-user inputs.

### Wave 5: Local Remote Shim And Device-Side Decrypt

Goal: make the product work in stdio clients and preserve local decryption.

Owner files:

```text
tools/openburnbar-mcp-remote/*
tools/openburnbar-mcp/*
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift
docs/REMOTE_MCP_CLIENT_SETUP.md
```

Streams:

- CLI worker: stdio MCP bridge.
- OAuth worker: browser/device login in shim.
- Crypto worker: vault-wrapper/decrypt integration.
- Installer worker: config generators for all clients.
- QA worker: compatibility matrix.

Tasks:

1. Implement stdio MCP server shim.
2. Shim forwards MCP tool calls to hosted MCP.
3. Shim stores access/refresh tokens in OS keychain where possible.
4. Shim registers a client/device key.
5. Shim requests allowed vault-key wrapper.
6. Shim decrypts sealed snippets/bodies locally.
7. Shim chunks large bodies safely.
8. Shim never logs plaintext by default.
9. Add installers:
   - Codex
   - Claude Code
   - Droid/Factory
   - Kimi
   - Forge
   - generic JSON
10. Add `openburnbar mcp doctor`.

DOD:

- Stdio-only clients can use OpenBurnBar MCP.
- Decrypted content appears only in the local process and target agent context.
- Vault keys are never printed or written to config JSON.
- Installer output is deterministic and reversible.
- Doctor gives actionable failure messages.

### Wave 6: App UX For Setup, Revocation, And Status

Goal: make setup obvious and premium.

Owner files:

```text
AgentLens/*
OpenBurnBarMobile/*
android/app/src/main/java/com/openburnbar/*
docs/REMOTE_MCP_CLIENT_SETUP.md
```

Streams:

- macOS UX worker: MCP settings and client management.
- iOS/iPadOS UX worker: status, index freshness, revoke clients.
- Android UX worker: parity status and docs links.
- Product/design reviewer: copy, hierarchy, empty/error/loading states.

User flow:

1. User opens OpenBurnBar settings.
2. User selects "Connect coding agents".
3. App explains that BurnBar Pro adds hosted MCP session memory.
4. User chooses a client.
5. App shows one command and one config block.
6. User completes OAuth.
7. App shows connected client, scopes, last used, decrypt mode, and revoke.
8. App shows index freshness and sync health.

DOD:

- Premium gate is clear.
- Non-subscribers see upgrade path, not broken controls.
- Subscribers see setup commands.
- Users can revoke clients.
- Users can tell whether index is fresh.
- Error states explain what to fix.
- No UI claims server-side plaintext privacy that the architecture cannot prove.

### Wave 7: Production Deployment And Live Proof

Goal: deploy the real hosted endpoint and prove it works.

Owner files:

```text
scripts/deploy-hosted-mcp.sh
functions/scripts/prove-hosted-mcp-live.mjs
scripts/test-hosted-mcp-compatibility.sh
docs/REMOTE_MCP_RUNBOOK.md
```

Streams:

- SRE worker: Cloud Run, domain, Secret Manager, IAM.
- Backend worker: production config and env validation.
- QA worker: live proof scripts.
- Security worker: least privilege and logging proof.

Tasks:

1. Deploy `services/hosted-mcp` to Cloud Run.
2. Attach domain `mcp.openburnbar.com`.
3. Enforce TLS.
4. Configure service account least privilege.
5. Configure Secret Manager secrets.
6. Configure min/max instances.
7. Configure logs and alerts.
8. Run live paid-user proof.
9. Run live unpaid-user denial.
10. Run live revoked-client denial.
11. Run live cross-tenant denial.
12. Run client compatibility matrix.

DOD:

- `https://mcp.openburnbar.com/readyz` is healthy.
- `https://mcp.openburnbar.com/mcp` responds correctly.
- Paid account works.
- Unpaid account fails.
- Revoked client fails.
- Direct Firestore client writes stay denied.
- Cloud logs contain no plaintext content.
- Alerts exist for 401/403/429/5xx spikes, latency, and instance pressure.
- Rollback command is documented and rehearsed.

### Wave 8: Multi-Agent Audit And Remediation

Goal: prove launch readiness through adversarial review.

Audit streams:

- Principal engineer: architecture, modularity, future extensibility.
- Security reviewer: auth, scopes, tenant isolation, secrets, prompt injection.
- Privacy reviewer: encrypted storage, decrypt boundaries, logging.
- SRE reviewer: deploy, monitoring, rollback, cost, rate limits.
- QA lead: tests, failure modes, live proof.
- Product designer: onboarding, consent, status, revoke flows.
- Protocol reviewer: MCP spec/client compatibility.
- Staff maintainer: docs, ownership, naming, no duplicate patterns.

Audit tasks:

1. Review diff against clean baseline.
2. Run all gates.
3. Inspect every TODO/FIXME/stub related to MCP/search/auth.
4. Try unpaid access.
5. Try revoked access.
6. Try expired token.
7. Try wrong audience.
8. Try cross-user resource URI.
9. Try oversized query.
10. Try huge result pagination.
11. Try stale index.
12. Try deleted Storage body.
13. Try malformed cursor.
14. Try prompt injection in transcript text.
15. Try repeated body opens to hit rate limits.
16. Inspect logs for raw content leakage.
17. Inspect Firestore for plaintext leakage.
18. Inspect config files for token/key leakage.
19. Run all real clients.
20. Fix every reachable issue.

Audit DOD:

- Every audit stream writes a signed report.
- Findings are prioritized.
- Critical/high issues are fixed.
- Medium issues are either fixed or explicitly accepted with owner/date.
- Launch recommendation is `ship`, `hold`, or `continue hardening`.

## Required Test Matrix

### Unit Tests

- token verification
- scope enforcement
- entitlement cache
- grant revocation
- cursor signing
- cursor tamper rejection
- input schema validation
- output truncation
- redaction
- audit event sanitization
- search planner
- manifest parsing
- stale index detection
- rate limit keys

### Integration Tests

- MCP initialize
- tools/list
- tools/call
- resources/list
- resources/read
- OAuth protected-resource metadata
- auth-code + PKCE
- token refresh
- entitlement denial
- revoked client denial
- cross-tenant denial
- Firestore rules denial
- encrypted body hash verification
- Storage missing object
- stale generation ignored

### Compatibility Tests

Run real or hermetic client tests for:

- Codex
- Claude Code
- Droid/Factory
- Kimi
- Forge
- generic MCP inspector/client

Each client must prove:

- add/configure MCP
- authenticate
- list tools
- run index status
- run search
- open one result through correct decrypt mode
- fail gracefully when entitlement is missing

### Live Production Proof

Required commands or equivalents:

```bash
git status --short --branch
git rev-parse HEAD
git rev-list --left-right --count HEAD...@{upstream}

npm ci --prefix functions
npm --prefix functions run lint
npm --prefix functions run build
npm --prefix functions test
npm --prefix functions run test:firestore-rules

npm ci --prefix services/hosted-mcp
npm --prefix services/hosted-mcp run lint
npm --prefix services/hosted-mcp run build
npm --prefix services/hosted-mcp test

cd tools/openburnbar-mcp && .venv/bin/python -m pytest tests -q
npm --prefix tools/openburnbar-mcp-remote test

./scripts/test-openburnbar-swift.sh
./scripts/test-openburnbar-app.sh
./scripts/test-openburnbar-ts.sh
./scripts/test-openburnbar-extension-host.sh
./scripts/test-openburnbar-retrieval-evals.sh
./scripts/test-openburnbar-replay-evals.sh

./scripts/security/scan-publishable-tree.sh
./scripts/test-hosted-mcp-security.sh
./scripts/test-hosted-mcp-compatibility.sh

node functions/scripts/prove-hosted-mcp-live.mjs \
  --project burnbar \
  --region us-central1 \
  --paid-uid "$OPENBURNBAR_PROOF_PAID_UID" \
  --unpaid-uid "$OPENBURNBAR_PROOF_UNPAID_UID" \
  --endpoint "https://mcp.openburnbar.com/mcp"
```

## Production Definition Of Done

This is done only when all items below are true.

### Product

- BurnBar Pro visibly includes hosted remote MCP.
- Hosted Quota remains intact and separately described.
- Users can understand what is encrypted, searchable, and revocable.
- Non-subscribers get a clear upgrade path.
- Subscribers can connect at least Codex, Claude Code, Droid/Factory, Kimi,
  Forge, and generic MCP via direct remote or local shim.

### Architecture

- Hosted MCP is a separate Cloud Run service.
- Auth broker is standards-based.
- Entitlement logic is centralized.
- Search logic is shared, not copy-pasted.
- Tool registry is deny-by-default.
- Local shim owns device-side decryption.
- Provider credential policy remains separate from session-memory policy.

### Security

- No Firebase ID token as final MCP auth.
- No raw provider credentials in hosted MCP.
- No arbitrary uid/path arguments.
- No cross-tenant reads.
- No plaintext session content in Firestore.
- No plaintext session content in logs.
- No vault keys in config files.
- Refresh tokens are hashed at rest.
- Revocation works.
- Rate limits work.

### Reliability

- Cloud Run health/readiness works.
- Alerts exist.
- Structured logs exist.
- Rollback exists.
- Cursor pagination works.
- Search handles stale/missing/deleted data gracefully.
- Body fetch handles missing Storage objects gracefully.

### Performance

- Search p50/p95 meets target budgets in warm service.
- Storage reads are zero during search.
- Firestore reads are bounded.
- Large corpora do not time out.
- Cost dashboard separates Cloud Run, Firestore, Storage, KMS, and Redis.

### Testing

- Unit tests green.
- Integration tests green.
- Firestore rules tests green.
- Protocol tests green.
- Compatibility tests green.
- Live production proof green.
- Audit reports complete.

### Documentation

- `docs/HOSTED_REMOTE_MCP.md` explains the product and architecture.
- `docs/REMOTE_MCP_THREAT_MODEL.md` explains trust boundaries.
- `docs/REMOTE_MCP_RUNBOOK.md` explains deploy, monitor, rollback.
- `docs/REMOTE_MCP_CLIENT_SETUP.md` explains each client.
- `docs/HOSTED_QUOTA_SYNC.md` is updated to show the expanded BurnBar Pro
  bundle.
- `CHANGELOG.md` records the release.

## Risks To Track

### Critical: Privacy Mismatch

Remote MCP changes the trust boundary. A remote server can receive user queries.
Readable result content requires local decrypt or explicit hosted decrypt
consent. The default must stay local-decrypt.

### Critical: Subscription Bypass

Every path must fail closed without `burnbar_pro`. Tests must cover direct
tools, resource reads, token refresh, body fetch, and compatibility shims.

### High: Client Drift

MCP clients differ. The answer is installer generators, doctor checks, and a
compatibility matrix, not hand-written docs only.

### High: Cross-Tenant Admin SDK Bug

All Firestore paths are rooted from token `sub`. Tool input must never decide
uid or owner paths.

### High: Logs Leaking Content

Structured logging and tests must prove no raw query/session/snippet/body/token
content reaches logs.

### Medium: Search Quality

Encrypted semantic search will not behave exactly like plaintext embeddings.
Mitigation: hybrid lexical/semantic opaque postings, facets, freshness status,
and retrieval evals.

### Medium: Cost Spikes

Mitigation: manifest, bounded fanout, no Storage reads during search, rate
limits, output caps, and cost dashboards.

## Sprint Operating Model

Use parallel streams, but keep ownership clean.

Rules:

- No two agents edit the same high-risk file at the same time.
- Shared contracts are written before implementation splits.
- Every worker owns specific files.
- Every worker writes tests for its surface.
- The primary integrator reviews and normalizes naming/errors/logging.
- No worker introduces a new auth, logging, or error pattern without approval.

Suggested streams:

1. Protocol/backend stream: `services/hosted-mcp`.
2. Auth/paywall stream: Functions OAuth/grants/entitlements.
3. Search stream: shared hosted search core and manifest.
4. Local shim stream: `tools/openburnbar-mcp-remote`.
5. UX stream: macOS/iOS/Android setup and status.
6. QA stream: proof scripts and compatibility harness.
7. Docs/SRE stream: runbooks, threat model, deploy docs.
8. Security audit stream: adversarial tests and log inspection.

## Final Launch Recommendation Rule

Ship only when the evidence says:

- hosted endpoint is live,
- paid user can use it,
- unpaid user cannot,
- revoked user cannot,
- all target clients work directly or through shim,
- encrypted search remains encrypted server-side,
- local decrypt works,
- logs are clean,
- tests are green,
- docs are current,
- rollback is rehearsed.

If any one of those is missing, the recommendation is hold.
