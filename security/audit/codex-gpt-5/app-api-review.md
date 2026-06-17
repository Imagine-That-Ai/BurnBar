# Application, API, and Data Validation Review

## Endpoint Summary

| Surface | Entry points | Auth | Authorization | Validation | Rate limits | Risk notes |
|---|---|---|---|---|---|---|
| Firebase callable APIs | `functions/src/callables/*` | Auth/App Check unless public/platform | owner checks, high-risk proof | shared validators | callable-specific | strong baseline |
| Public Functions HTTP | health, CLI link, rundown, webhooks | public/signature/platform | endpoint-specific | handler validation | incomplete repo evidence | add public rate inventory |
| Stripe webhooks | raw-body endpoint | Stripe signature | customer mapping/idempotency | event parse | platform | strong core signature path |
| Hosted MCP `/mcp` | HTTP POST | bearer token | client/scope/entitlement/rate | bounded body/origin/protocol/schema | Firestore buckets | good posture |
| Daemon RPC | local socket | socket token and peer auth | capability profile | request bounds/decode | per-method limiter | Computer Use proof not wired |
| Firestore direct | Firebase SDK | Firebase Auth and deployed App Check expected | security rules | rule validation | Firebase limits | App Check state external |

## Controls Found

- Bounded strings, safe document IDs, numbers, arrays, and Cloud Vault contexts in `functions/src/callables/shared/validators.ts:73-204`.
- Sealed text and blob envelope validation in `validators.ts:226-341`.
- Owner-scoped Storage object paths and size/content-type checks in `functions/src/callables/shared/storage.ts:25-93`.
- SSRF guard in `functions/src/ssrfGuard.ts:1-79`.
- `resilientFetch` invokes SSRF guard before external API calls in `functions/src/resilienceHelpers.ts:31-40`.
- CI raw fetch guard in `scripts/ci/verify-resilience-wiring.sh:1-48`.
- Hosted MCP bounded body read and origin/protocol checks in `services/hosted-mcp/src/server.ts:21-43,97-180`.
- Daemon gateway max header/body and local CORS controls in daemon gateway files.

## Gaps

| Finding | Gap | Evidence | Recommendation |
|---|---|---|---|
| FINDING-003 | Non-HTTPS hosts containing `localhost` can pass URL validation | `validators.ts:344-356` | exact loopback detection and production allowlist |
| FINDING-005 | Public HTTP endpoints lack complete product-layer rate limit evidence | public endpoint catalog, `routerRundown.ts:205-220` | shared public rate limiter or edge verifier |

## Risk Review

| Risk | Result |
|---|---|
| SQL/NoSQL injection | no high-confidence issue found in reviewed core paths |
| Path traversal | controlled for reviewed document and storage paths |
| SSRF | controlled for provider HTTP through wrapper and CI guard |
| Open redirect | Stripe return URL helper bug found |
| CSRF | callable APIs use Firebase/Auth App Check; hosted MCP uses bearer/origin checks |
| File upload | reviewed encrypted body paths are owner-scoped and bounded |
| Webhook forgery | Stripe and knowledge webhooks verify signatures |
| Business logic abuse | high-risk owner action nonce/proof present; daemon proof production gap remains |

