# Provider Source-of-Truth Reference

> Auto-generated from `docs/PROVIDER_DATA_AUDIT.md` — the canonical audit.
> Do not regress: every provider must report real data or explicitly state "Not available."

## Provider Status Table

| Provider | Adapter | Confidence | Source | Data Available |
|----------|---------|------------|--------|---------------|
| **Codex** | `CodexQuotaAdapter.swift` | `.exact` | `~/.codex/sessions/rollout-*.jsonl` | Rate-limit % (5h + 7d windows) |
| **Claude Code** | `ClaudeQuotaAdapter.swift` | `.exact` | Bridge → JSONL → estimate | Bridge: rate-limit %. JSONL: token counts. |
| **Copilot** | `CopilotQuotaAdapter.swift` | `.exact` | `POST api.github.com/copilot_internal/user` | Premium + Chat rate windows |
| **MiniMax** | `MiniMaxQuotaAdapter.swift` | `.exact` | `GET .../coding_plan/remains` | Token plan remaining counts |
| **Z.ai** | `ZAIQuotaAdapter.swift` | `.exact` | `GET api.z.ai/api/monitor/usage/quota/limit` | Token + MCP limits |
| **Factory** | `FactoryQuotaAdapter.swift` | `.exact` / `.estimated` | `POST app.factory.ai/api/.../usage` | Standard + Premium token buckets |
| **Cursor** | `CursorQuotaAdapter.swift` | `.exact` / `.estimated` | `GET cursor.com/api/usage-summary` | Included + on-demand usage |
| **Warp** | `WarpQuotaAdapter.swift` | `.exact` / log-tailing | `POST app.warp.dev/graphql/v2` | Request credits |
| **Ollama** | `OllamaQuotaAdapter.swift` + routed-provider catalog | `.exact` | `GET localhost:11434/api/tags` + `/api/ps`; `https://ollama.com/api` for cloud routing | Local model counts; cloud API-key route state |
| **OpenAI** | `OpenAIQuotaAdapter` / `functions/src/providers/openai.ts` | `.exact` | `GET api.openai.com/v1/organization/usage/completions` | Organization token + request usage; hard quota limits unavailable |
| **Kimi** | _none_ | `.unavailable` | No public API | CLI token counts only |
| **Gemini CLI** | _none_ | `.unavailable` | No public API | Session JSONL tokens only |

## Confidence Legend

- `.exact` — Data comes from an official API, local CLI artifact, or documented endpoint. No heuristics.
- `.estimated` — Data is derived from OpenBurnBar's own tracking, not the vendor. **On the chopping block.**
- `.unavailable` — No legal/feasible data source exists. User sees a clear "Not available" message.

## Auth Requirements (per provider)

| Provider | Auth Type | Credential Format | Header | Scope / Notes |
|----------|-----------|-------------------|--------|---------------|
| **Codex** | None | N/A (local file) | N/A | Reads `rollout-*.jsonl` from `~/.codex/sessions/` |
| **Claude (bridge)** | None | N/A (local hook) | N/A | Installs shell wrapper in `~/.claude/settings.json` |
| **Claude (JSONL)** | None | N/A (local file) | N/A | Reads `~/.claude/projects/**/*.jsonl` |
| **Copilot** | GitHub OAuth / PAT | `ghp_...` or OAuth token | `Authorization: token {token}` | OAuth: `read:user` scope. Classic PAT: `read:user`. Device flow client ID: `Iv1.b507a08c87ecfe98` (VS Code). |
| **Cursor** | Browser cookie | `WorkosCursorSessionToken={userId}::{token}` | `Cookie: {cookieString}` | WorkOS-based auth. Cookie extracted from Safari/Chrome for `cursor.com` domains. Alternative: manual paste. |
| **Factory** | Browser cookie + Bearer | Session cookie + `access-token` from cookie | `Cookie: {cookie}` + `Authorization: Bearer {token}` | WorkOS-based auth. Cookie extracted from Safari/Chrome for `app.factory.ai`. |
| **Warp** | API key | `wk-...` | `Authorization: Bearer {key}` + `User-Agent: Warp/1.0` | Created at warp.dev. Spoofed UA required (HTTP 429 otherwise). |
| **MiniMax** | Coding Plan API key | `sk-cp-...` | `Authorization: Bearer {key}` | Standard `sk-api-...` keys are rejected. |
| **Z.ai** | API key | (no fixed prefix) | `Authorization: Bearer {key}` | From Z.ai dashboard. Coding plan or API quota access. |
| **Ollama** | None for localhost; API key for Ollama Cloud | `ollama` local placeholder or Ollama API key | `Authorization: Bearer {key}` for `https://ollama.com/api` | Local inventory needs `ollama serve`; cloud routing uses explicit Keychain-backed provider-plan slots. |
| **OpenAI (usage)** | Admin API key | `sk-...` | `Authorization: Bearer {key}` | Requires organization admin key for `/v1/organization/usage/completions`. |
| **Anthropic (usage)** | Admin API key | `sk-ant-admin-...` | `x-api-key: {key}` + `anthropic-version: 2023-06-01` | Requires admin key for `/v1/organizations/usage_report/messages`. |
| **OpenRouter (usage)** | API key | `sk-or-...` | `Authorization: Bearer {key}` | Any API key works. Returns `total_cost` directly. |

## Endpoint Reference

| Provider | Endpoint | Method | Response Shape |
|----------|----------|--------|---------------|
| Codex | `~/.codex/sessions/rollout-*.jsonl` | File read | `{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":...,"window_minutes":300},"secondary":{...}}}}` |
| Claude (bridge) | `~/.claude/settings.json` → statusline hook | Shell stdin | `{"rate_limits":{"five_hour":{"used_percentage":...},"seven_day":{...}}}` |
| Claude (JSONL) | `~/.claude/projects/**/*.jsonl` | File read | `{"type":"assistant","timestamp":"...","message":{"model":"...","usage":{"input_tokens":...,"output_tokens":...}}}` |
| Copilot | `POST https://api.github.com/copilot_internal/user` | HTTP | `{"copilot_plan":"pro","quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":180,"percent_remaining":60},"chat":{...}}}` |
| Cursor | `GET https://cursor.com/api/usage-summary` | HTTP | `{"individualUsage":{"plan":{"totalPercentUsed":...,"autoPercentUsed":...,"apiPercentUsed":...},"onDemand":{"used":...,"limit":...}}}` |
| Factory | `POST https://api.factory.ai/api/organization/subscription/usage` | HTTP | `{"usage":{"standard":{"userTokens":...,"totalAllowance":...},"premium":{...}}}` |
| Warp | `POST https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo` | GraphQL | `{"data":{"workspace":{"requestLimit":...,"requestsUsedSinceLastRefresh":...,"bonusGrants":[...]}}}` |
| MiniMax | `GET https://www.minimax.io/v1/api/openplatform/coding_plan/remains` | HTTP | `{"model_remains":[{"model_name":"...","current_interval_usage_count":...,"current_interval_total_count":...,"resets_at":"..."}]}` |
| Z.ai | `GET https://api.z.ai/api/monitor/usage/quota/limit` | HTTP | `[{"type":"TOKENS_LIMIT","unit":3,"number":5,"currentValue":...,"remaining":...,"percentage":...}]` |
| Ollama | `GET http://localhost:11434/api/tags`; `POST https://ollama.com/api/chat`; `GET https://ollama.com/api/tags` | HTTP | Local/cloud model list plus native chat response with `message.content`, `prompt_eval_count`, and `eval_count` |
| OpenAI | `GET https://api.openai.com/v1/organization/usage/completions?start_time=...&end_time=...&bucket_width=1d` | HTTP | `{"data":[{"results":[{"input_tokens":...,"output_tokens":...,"input_cached_tokens":...,"num_model_requests":...}]}]}` |

## Refresh Cadences

| Provider | Cadence | Auth Required |
|----------|---------|---------------|
| Codex | On next CLI invocation | None |
| Claude (bridge) | Every CLI prompt | None |
| Claude (JSONL) | Within 5 min of API call | None |
| Copilot | Real-time | GitHub OAuth token or PAT |
| MiniMax | On refresh (polled) | `sk-cp-...` Coding Plan key |
| Z.ai | On refresh (polled) | API key |
| Factory | On refresh (polled) | Browser cookie |
| Cursor | On refresh (polled) | Browser cookie |
| Warp | On refresh (polled) | `wk-...` API key |
| Ollama | On refresh (polled); on routed gateway request | None for localhost; Ollama Cloud API key for direct cloud API |
| OpenAI | On refresh (polled) | Organization admin API key |

## Adding a New Provider

1. Create `{Provider}QuotaAdapter.swift` conforming to `ProviderQuotaAdapter`
2. Add to `QuotaRefreshActor.swift` adapters dictionary and providers list
3. Add to `ProviderQuotaService.swift` `supportedProviders`
4. Set `confidence: .exact` for real data; `.unavailable` if no source exists
5. **Never** return `confidence: .estimated` — ban the path
6. Add a golden-fixture test in `AgentLensTests/Active/ProviderQuota/`
7. Update this file with endpoint, auth type, credential format, and response shape
