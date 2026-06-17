# Application, API, and Data Validation Review

## H.1 Endpoint and Route Summary

| Surface | Entry points | Auth required | Authorization | Validation | Rate limits | Sensitive logging | Risk notes |
|---|---|---|---|---|---|---|---|
| Firebase callable APIs | `functions/src/callables/*` | Auth/App Check unless explicitly public/platform | owner checks, high-risk proof, endpoint catalog | shared validators, schema-specific checks | callable-specific; not universal | `logging.ts` scrubbers | strong baseline; keep generated matrix current |
| Public Functions HTTP | health, CLI link, router rundown, webhooks, knowledge repo push | public or signature/platform | endpoint-specific | handler validation | incomplete repo evidence | scrubbed logs | add explicit public rate inventory |
| Stripe webhooks | Stripe raw-body endpoint | Stripe signature | customer mapping/idempotency | Stripe event parse | Stripe/Function limits | scrubbed | signature and idempotency are strong |
| Hosted MCP `/mcp` | Node HTTP POST | bearer token | client/scope/entitlement/rate | bounded body/origin/protocol/schema | Firestore-backed bucket limits | redaction/hashes | good posture |
| Daemon RPC | local socket | socket token and peer auth | capability profile | max request bytes/decode | per-method limiter | local logs | Computer Use proof not wired |
| Daemon HTTP gateway | loopback HTTP | bearer/x-api-key unless debug opt-in | gateway routing/capability | header/body bounds/CORS | general and unauth loopback limiter | local logs | release unauth loopback denied |
| Firestore direct | Firebase SDK | Firebase Auth, deployed App Check expected | security rules | rules validation | Firebase limits | Firebase logs | App Check state external |

## H.2 Validation Controls Found

- Bounded strings, safe document IDs, numbers, arrays, and Cloud Vault contexts in `functions/src/callables/shared/validators.ts:73-204`.
- Sealed text and blob envelope validation in `validators.ts:226-341`.
- Owner-scoped Storage object paths and size/content-type checks in `functions/src/callables/shared/storage.ts:25-93`.
- SSRF guard for provider fetches in `functions/src/ssrfGuard.ts:1-79`.
- `resilientFetch` invokes SSRF guard before external API calls in `functions/src/resilienceHelpers.ts:31-40`.
- CI raw fetch guard exists in `scripts/ci/verify-resilience-wiring.sh:1-48`.
- Hosted MCP bounded body read and origin/protocol checks in `services/hosted-mcp/src/server.ts:21-43,97-180`.
- Daemon gateway max header/body and local CORS controls in `OpenBurnBarHTTPGatewayServer+Connection.swift:63-99` and `OpenBurnBarHTTPGatewayServer+HTTPTransport.swift:272-292`.

## H.3 Validation Gaps

| ID | Gap | Severity | Evidence | Recommendation |
|---|---|---|---|---|
| FINDING-003 | Non-HTTPS hosts containing `localhost` can pass URL validation | Medium | `validators.ts:344-356` | exact loopback detection and production allowlist |
| FINDING-005 | Public HTTP endpoints lack complete product-layer rate limit evidence | Medium | public endpoint catalog, `routerRundown.ts:205-220` | shared public rate limiter or edge verifier |

## H.4 Injection and Abuse Review

| Risk | Current evidence | Result |
|---|---|---|
| SQL injection | Firestore/GRDB/SQLCipher usage; no raw user SQL path reviewed as critical | no high-confidence issue found |
| NoSQL injection | Firestore paths validated in shared helpers and rules | controlled for reviewed paths |
| Path traversal | safe document ID helper rejects `/` and `..`; storage path helper owner-scopes | controlled for reviewed storage paths |
| SSRF | provider fetch wrapper and CI raw fetch guard exist | controlled for provider HTTP, but public endpoints still need rate inventory |
| Command injection | local daemon/tool surfaces exist; not enough evidence of untrusted shell path in reviewed core | continue focused review for tool execution |
| Open redirect | Stripe return URL helper bug found | FINDING-003 |
| CSRF | callable APIs use Firebase Auth/App Check; hosted MCP uses bearer/origin checks | controlled for reviewed APIs |
| File upload | Storage helper bounds owner path, existence, size, content type | controlled for reviewed encrypted body paths |
| Webhook forgery | Stripe signature and knowledge HMAC present | controlled for reviewed webhooks |
| Business logic abuse | high-risk owner action nonce/proof present | daemon proof production gap remains |

