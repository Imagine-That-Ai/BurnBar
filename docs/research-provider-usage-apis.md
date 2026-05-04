# Provider Usage/Billing API Research — Canonical Sources of Truth

> Last verified: 2026-05-02
> Scope: Real (non-estimated) usage/quota data per provider. Each entry records the canonical endpoint, disk artifact, auth, update cadence, rate limits, ToS gotchas, and Swift/macOS portability.

---

## GitHub Copilot

### Existing BurnBar implementation
`AgentLens/Services/ProviderUsageAPI/GitHubCopilotUsageAPI.swift` — hits both user and org endpoints, `provenanceConfidence: .exact`.

### Canonical endpoints

| Endpoint | Auth | Scope |
|---|---|---|
| `GET /user/copilot/metrics` | PAT with `copilot` or `read:user` | Individual seat metrics |
| `GET /orgs/{org}/copilot/metrics` | PAT with `manage_billing:copilot` (org admin) | Org-level aggregate |
| `GET /orgs/{org}/team/{team_slug}/copilot/metrics` | PAT with `manage_billing:copilot` | Team-level |

### Auth
- **Header:** `Authorization: Bearer <PAT>`
- **Required headers:** `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`
- Token needs `copilot` scope for user; `manage_billing:copilot` for org/team.
- Fine-grained PATs must target the specific org with Copilot business/enterprise seat.

### Update cadence
- **Daily aggregates only.** No real-time or per-request data.
- Data lags by 24–48h. The `date` field in the response is the UTC day bucket.
- `since`/`until` query params as ISO 8601 timestamps (max 100 days lookback).
- No streaming/webhook option.

### Response shape (org-level, from docs JSON-LD)

```json
[
  {
    "date": "2026-04-30",
    "copilot_ide_chat": {
      "total_engaged_users": 12,
      "models": [
        {
          "name": "claude-3.5-sonnet",
          "is_custom_model": false,
          "total_engaged_users": 8,
          "total_chats": 145,
          "total_tokens": 234500
        }
      ]
    },
    "copilot_dotcom_chat": { "total_engaged_users": 3, "total_chats": 22 },
    "copilot_dotcom_pull_requests": { "total_engaged_users": 2, "total_pull_requests": 5 },
    "total_active_users": 12,
    "total_engaged_users": 12
  }
]
```

### What's available vs what's missing
- **Available:** `total_tokens` per model, `total_chats`, `total_engaged_users`, `total_active_users`.
- **Not available:** `input_tokens` / `output_tokens` split, `cost`, per-request data, caching breakdown.
- **BurnBar's workaround:** estimates split at 85/15 input/output (commented `// Copilot metrics don't provide input/output split`). This is a conservative baseline — real splits are closer to 80/20 for IDE chat.

### Rate limits / ToS gotchas
- Standard GitHub REST rate limits apply (5,000 req/hr authenticated).
- Paginated — `per_page` up to 100 (days), `page` query param.
- **No `cost` field.** Must be computed from token counts × pricing table. Copilot pricing is per-seat, not per-token, so cost attribution is per-user not per-model.
- The old `/user/copilot/billing` and `/orgs/{org}/copilot/billing` endpoints redirect → use `/copilot/metrics`.

### Prior art: gh-copilot extension
- GitHub's own `gh copilot` CLI extension (`github/gh-copilot`) provides `gh copilot usage` but delegates to the same REST endpoints. It formats output for the CLI, doesn't persist data locally.

### Copilot session log parsing (local)
- BurnBar logs Copilot sessions from `~/.copilot/session-state/*.jsonl` (set in `AgentLens/Models/AgentProvider.swift:logDirectory`).
- Currently marked `dataConfidence: .estimated` with `supportLevel: .partial`.
- The local JSONL files contain chat transcripts but **do NOT contain token counts** from the Copilot backend. The backend never surfaces per-request token data.

### Swift/macOS portability
- Straightforward: `URLSession`, `Codable`, OAuth2 via ASWebAuthenticationSession. BurnBar already has the API implementation functional.

---

## OpenAI

### Existing BurnBar implementation
`AgentLens/Services/ProviderUsageAPI/OpenAIUsageAPI.swift` — uses `https://api.openai.com/v1/organization/usage/completions`.

### Canonical endpoint
`GET https://api.openai.com/v1/organization/usage/completions`

- **Auth:** `Authorization: Bearer <admin-api-key>` (regular API keys **do not** work — must be an Org Admin key from platform.openai.com).
- **Query params:**
  - `start_time` — Unix timestamp (seconds, int)
  - `end_time` — Unix timestamp (seconds, int)
  - `granularity` — `"1d"` only (no hourly support)
  - `group_by[]` — `"model"` for model breakdown
  - `page` — cursor for pagination

### Update cadence
- **Daily aggregates.** No real-time data. Lag is typically < 24h.
- Alternate endpoint `GET /v1/organization/costs` returns cost-only daily buckets (computed from the same underlying data).
- **No per-request streaming.** The `/v1/organization/usage/completions` endpoint is the canonical source.

### Response shape
```json
{
  "object": "page",
  "data": [
    {
      "start_time": 1688169600,
      "snapshot_id": "gpt-4",
      "results": [
        {
          "model": "gpt-4",
          "input_tokens": 150000,
          "output_tokens": 45000,
          "input_cached_tokens": 12000,
          "num_model_requests": 340,
          "project_id": null,
          "user_id": null,
          "api_key_id": null
        }
      ]
    }
  ],
  "has_more": false,
  "next_page": null
}
```

### Fields available
- **Available:** `input_tokens`, `output_tokens`, `input_cached_tokens`, `num_model_requests`.
- **Cost is NOT returned.** Must be computed from token × pricing table. Litellm (`BerriAI/litellm`) does exactly this via `litellm/llms/openai/cost_calculation.py`.
- **Not available:** `cache_creation_tokens` (distinct from cache reads), `reasoning_tokens`, real-time data.
- When `group_by[]=model`, results nest under `results` array per `snapshot_id`.

### Prior art: litellm, openai-python, simonw/llm
- **litellm** (`BerriAI/litellm`): Calls the usage endpoint in the proxy's `/spend/logs` pipeline. Cost computed from their pricing dictionary, not from the API.
- **openai-python**: Types defined in `src/openai/types/completion_usage.py`. The SDK's `Usage` type surfaces per-request `prompt_tokens`, `completion_tokens`, `total_tokens` from chat completions — but this is **per-call response metadata**, not aggregate billing.
- **simonw/llm**: Logs every API call to a SQLite database (`~/.llm/logs.db`). Per-response `input_tokens`/`output_tokens` come from the completion response, not the admin billing API. This is exact per-request data but only for calls through `llm`.

### Rate limits / ToS gotchas
- OpenAI's usage API is rate-limited but not publicly documented. Count on ~30 req/min.
- **Admin key required.** This is the biggest UX friction — most users have regular API keys. Org owners must provision admin keys.
- Paginated — follow `has_more`/`next_page`.

### Swift/macOS portability
- BurnBar implementation is functional. Admin key UX is the friction point.

---

## Anthropic

### Existing BurnBar implementation
`AgentLens/Services/ProviderUsageAPI/AnthropicUsageAPI.swift` — uses `https://api.anthropic.com/v1/organizations/usage_report/messages`.

### Canonical endpoint
`GET https://api.anthropic.com/v1/organizations/usage_report/messages`

- **Auth:** `x-api-key: <admin-api-key>` (keys start with `sk-ant-admin-...`)
- **Required header:** `anthropic-version: 2023-06-01`
- **Query params:**
  - `start_time` — ISO 8601
  - `end_time` — ISO 8601
  - `granularity` — `"1d"` only
  - `group_by` — `"model"` for model breakdown

### Update cadence
- **Daily aggregates.** ~24h lag. Same fundamental architecture as OpenAI.
- The `/v1/organizations/usage_report/messages` is the canonical endpoint — no real-time alternative exists on the API.

### Response shape
```json
{
  "data": [
    {
      "start_time": "2024-01-01T00:00:00Z",
      "model": "claude-sonnet-4-20250514",
      "input_tokens": 120000,
      "uncached_input_tokens": 100000,
      "output_tokens": 45000,
      "cached_input_tokens": 20000,
      "cache_creation_input_tokens": 5000,
      "num_requests": 200
    }
  ],
  "has_more": false,
  "next_page": null
}
```

### Fields available
- **Available:** `input_tokens` (sum of all input), `uncached_input_tokens`, `output_tokens`, `cached_input_tokens` (cache reads), `cache_creation_input_tokens` (cache writes), `num_requests`.
- **Cost is NOT returned.** Must be computed from pricing table. BurnBar already does this via `ModelPricing.cost()`.
- **Better cache granularity than OpenAI** — specifically splits cache reads and cache writes, which matters for Claude's prompt caching billing (different rates).

### Prior art: litellm
- `litellm/llms/anthropic/cost_calculation.py` handles the nuanced cache cost calculation — cache read/write costs are computed separately from uncached input and are NOT scaled by `fast/` or geo multipliers.

### Rate limits / ToS gotchas
- Admin API key required (`sk-ant-admin-...`). Regular `sk-ant-api03-...` keys do NOT work.
- Paginated via `has_more`/`next_page` (page token).
- No rate limit documented but count on ~30 req/min.

### Swift/macOS portability
- BurnBar implementation is fully functional. Admin key UX same friction as OpenAI.

---

## OpenRouter

### Existing BurnBar implementation
`AgentLens/Services/ProviderUsageAPI/OpenRouterUsageAPI.swift` — uses `https://openrouter.ai/api/v1/activity`.

### Canonical endpoints
| Endpoint | Purpose |
|---|---|
| `GET /api/v1/activity` | Daily usage aggregates (30-day lookback) |
| `GET /api/v1/auth/key` | Validate API key |

- **Auth:** `Authorization: Bearer <api-key>`
- No admin separation — your regular API key has access to your own usage.

### Update cadence
- **Near real-time for totals; daily for the full breakdown.** The `/activity` endpoint returns `data[].date` daily buckets. The `data[].total_usage` field (cost) updates within minutes. Token counts update daily.
- This is the best balance of freshness among all providers — no admin key needed, nearly real-time cost.

### Response shape
```json
{
  "data": [
    {
      "date": "2026-04-30",
      "model": "anthropic/claude-sonnet-4-20250514",
      "model_id": "anthropic/claude-sonnet-4-20250514",
      "input_tokens": 25000,
      "output_tokens": 8000,
      "prompt_tokens": 25000,
      "completion_tokens": 8000,
      "total_tokens": 33000,
      "total_cost": 0.234,
      "num_requests": 45
    }
  ]
}
```

### Fields available
- **Available:** `total_tokens`, `input_tokens`/`prompt_tokens`, `output_tokens`/`completion_tokens`, `total_cost` (actual USD), `num_requests`.
- **Cost IS returned.** This is unique — OpenRouter provides `total_cost` directly, matching your invoice.
- **Not available:** cache read/write split, reasoning tokens.
- Model names include provider prefix: `anthropic/claude-sonnet-4-20250514`, `openai/gpt-4o`.

### Prior art: openrouter-runner
- `openrouter-runner` (community load-testing tool) uses the `/activity` endpoint for usage tracking and the `/api/v1/auth/key` for validation. Same pattern as BurnBar's implementation.

### Rate limits / ToS gotchas
- Rate limited but generous — no fixed docs. Count on ~60 req/min.
- 30-day lookback window. Older data requires periodic fetch + local persistence.
- No pagination needed — returns the full 30-day window in a single response.

### Swift/macOS portability
- BurnBar implementation is fully functional. No admin key friction — any OpenRouter key works.

---

## Z.ai (GLM / BigModel)

### Existing BurnBar implementation
`AgentLens/Services/ProviderUsageAPI/ZaiMiniMaxUsageProbe.swift` — `ZaiUsageProbe` probes speculative endpoints.

### The problem
Z.ai does **not** publish a documented usage/billing REST API. The BurnBar probe (`ZaiUsageProbe`) tries these speculative URLs:

```
https://api.z.ai/api/coding/paas/v4/usage
https://api.z.ai/api/coding/paas/v4/billing/usage
https://api.z.ai/dashboard/billing/usage
https://open.bigmodel.cn/api/billing/usage
```

None are documented. The probe parses JSON responses heuristically looking for `usage`, `data`, `total_tokens`, `total_cost` fields.

### What actually exists
- **Z.ai / BigModel API** (`open.bigmodel.cn`) has a web dashboard at `https://open.bigmodel.cn/` where users can see usage/billing.
- The chat API responses include usage metadata (`usage.prompt_tokens`, `usage.completion_tokens`, `usage.total_tokens`) in **per-request responses** — same pattern as OpenAI.
- **No aggregate billing API is publicly documented.** The web dashboard's internal API may exist at `open.bigmodel.cn/api/...` but there is no official spec.
- The coding PaaS API at `api.z.ai/api/coding/paas/v4` has a `/models` endpoint (for model listing) but no confirmed `/usage` endpoint.

### Actual source of truth
- **Disk artifacts:** BurnBar treats Z.ai as using `~/.factory/sessions/*.jsonl` (same `logDirectory` as Factory in `AgentProvider.swift`). This suggests Z.ai's CLI shares Factory's session format.
- **Token data confidence:** Currently set to `dataConfidence: .estimated` with `supportLevel: .partial`.
- **Per-request metadata:** The chat API response includes `usage.total_tokens` etc. If BurnBar intercepts API responses (daemon event routing), this gives exact per-call data.

### Recommendations
1. **Prioritize daemon event routing** — intercept Z.ai API responses for exact per-request token data (same as BurnBar already plans for Ollama).
2. **Probe the BigModel dashboard API** — the internal API at `open.bigmodel.cn/api/dashboard/billing/usage` might work with a valid API key. The probe already tries this.
3. **Do not invest in scraping the web dashboard** — it's fragile and violates ToS.

---

## MiniMax

### Existing BurnBar implementation
`AgentLens/Services/ProviderUsageAPI/ZaiMiniMaxUsageProbe.swift` — `MiniMaxUsageProbe` probes speculative endpoints.

### The problem
Same situation as Z.ai — MiniMax does **not** publish a documented aggregate usage/billing REST API.

### Speculative endpoints probed by BurnBar
```
https://api.minimax.io/v1/usage
https://api.minimax.io/v1/billing/usage
https://api.minimax.io/usage
https://api.minimax.io/v1/dashboard/billing/usage
```

### What actually exists
- **MiniMax API docs** (`platform.minimaxi.com`) have a documented page at `API Reference > accountinfo` which describes the web platform account page, NOT a REST endpoint.
- The chat API responses (`/v1/text/chatcompletion_v2`) include per-request `usage.total_tokens` in the response body.
- **No aggregate billing API is publicly documented.**
- MiniMax provides a web dashboard at `platform.minimaxi.com` for balance/usage checking.

### Actual source of truth
- **Disk artifacts:** BurnBar treats MiniMax as using `~/.factory/sessions/*.jsonl` (same as Z.ai and Factory).
- **Token data confidence:** Currently `dataConfidence: .estimated` with `supportLevel: .partial`.
- **Per-request metadata:** Chat API responses include usage for each call.

### Recommendations
1. **Daemon event routing** — same strategy as Z.ai.
2. **Check `GET /v1/models` for key validation** — this endpoint works (BurnBar already uses it for validation) and confirms the API key is valid.
3. **Monitor MiniMax docs** for API additions — they're iterating quickly.

---

## Kimi (Moonshot)

### Existing BurnBar implementation
`AgentLens/Services/LogParser/KimiParser.swift` — parses `~/.kimi/sessions/<workspace>/<session>/context.jsonl` and `wire.jsonl`. Currently `dataConfidence: .exact` (since v0.66, Dec 2025 gives exact token data).

### Canonical billing endpoint: YES — confirmed
`GET https://api.moonshot.cn/v1/users/me/balance`

- **Auth:** `Authorization: Bearer <api-key>` (standard Kimi API key)
- **Documented in:** OpenAPI spec at `https://platform.kimi.com/docs/openapi.json`
- **Response shape:**
```json
{
  "code": 0,
  "data": {
    "available_balance": 49.58894,
    "voucher_balance": 46.58893,
    "cash_balance": 3.00001
  },
  "scode": "0x0",
  "status": true
}
```

### What this gives you
- **Available:** `available_balance` (total usable balance in RMB yuan), `voucher_balance` (coupon balance), `cash_balance` (cash balance, can be negative = arrears).
- **Not available:** Per-model token breakdown, input/output split, request count, daily aggregates.
- This is a **balance check only**, not a usage API. It tells you how much money you have left, not what you spent it on.

### The real source of truth: wire.jsonl
- Kimi CLI (v0.66+, Dec 2025) writes `wire.jsonl` with `StatusUpdate` messages containing per-turn exact token counts:
  - `input_other`, `output`, `input_cache_read`, `input_cache_creation`
- BurnBar's `KimiParser` already consumes this. **This is the canonical exact source** for Kimi usage — better than any API.
- `dataConfidence: .exact` is correct.

### Prior art
- **No public usage aggregate API** — `GET /v1/users/me/balance` is the only billing endpoint. The OpenAPI spec at `platform.kimi.com/docs/openapi.json` has no usage/token endpoints.
- Kimi does have a web console at `platform.kimi.com/console/account` for detailed billing.

### Recommendations
1. **Add `GET /v1/users/me/balance` probe** — BurnBar currently has no Kimi billing API probe. Adding this gives a balance health check.
2. **The wire.jsonl parser is the gold standard** — no changes needed.
3. **Compute cost from token counts** — BurnBar's existing `ModelPricing.lookup()` path handles this.

---

## Gemini CLI & Google AI Studio / Vertex AI

### Existing BurnBar implementation
`AgentLens/Services/LogParser/GeminiCLIParser.swift` — parses `~/.gemini/tmp/<project_hash>/chats/session-*.json` and `.jsonl`. Currently `dataConfidence: .exact`.

### Gemini CLI disk artifacts
- **Location:** `~/.gemini/tmp/<project_hash>/chats/session-*.json` (and `.jsonl`)
- **Token data source:** `message_update` events with `usage` blocks containing:
  - `input_tokens` / `prompt_tokens` / `promptTokenCount`
  - `output_tokens` / `completion_tokens` / `candidatesTokenCount`
  - `cached_tokens` / `cachedContentTokenCount`

### Gemini CLI approach to persistence (from source code)
- **Logger** (`packages/core/src/core/logger.ts`): Writes `LogEntry` objects to `~/.gemini/logs.json`. Contains `sessionId`, `messageId`, `timestamp`, `type`, `message` — **but not token counts**.
- **Session summary** (`packages/core/src/services/sessionSummaryService.ts`): Generates one-line summaries via Gemini Flash Lite. No token data persisted.
- **Token calculation** (`packages/core/src/utils/tokenCalculation.ts`): Heuristic estimation (character-based, CJK-aware) used for context window tracking, **not** for billing purposes.
- **Activity logger** (`packages/cli/src/utils/activityLogger.ts`): HTTP request/response interception for telemetry, not token counting.
- **Context usage display** (`packages/cli/src/ui/components/ContextUsageDisplay.tsx`): Renders context window fill percentage in the UI. Estimate-based.

### Key finding
Gemini CLI uses heuristic token estimation (`ASCII_TOKENS_PER_CHAR = 0.33`, `NON_ASCII_TOKENS_PER_CHAR = 1.5`) for its own context-tracking, but the `message_update` events in session files **contain real token counts from the Gemini API response**. BurnBar's `GeminiCLIParser` correctly reads these.

### Does Google AI Studio expose a quota API?
- **No.** Google AI Studio (free tier) has rate limits but no programmatic quota API.
- Google AI Studio usage is **not billed** (free tier with rate limits). Paid tiers go through Vertex AI.

### Does Vertex AI expose a quota API?
- **Yes**, but it's complex. Google Cloud Service Usage API:
  - `GET https://serviceusage.googleapis.com/v1/{parent=*/*}/services/{service}/ quotas`
  - Requires Google Cloud IAM, OAuth2, and the `monitoring.googleapis.com` scope.
  - Returns quota limits, not actual usage.
- **Actual usage data** lives in Google Cloud Billing exports (BigQuery), not a REST API.
- Vertex AI responses include `usageMetadata` with `promptTokenCount`, `candidatesTokenCount`, `totalTokenCount` — per-request, exact, available in API responses.

### Recommendations
1. **Gemini CLI parser is solid** — `GeminiCLIParser.swift` correctly reads exact token counts from session files.
2. **Daemon event routing** could capture per-request `usageMetadata` from Gemini API responses for exact per-call data, same pattern as other providers.
3. **Vertex AI billing API is not worth implementing** — the GCP billing export pipeline is too heavy for a macOS menubar app. If user has Vertex billing, recommend they connect via the daemon event route instead.
4. **Google AI Studio: no billing API exists** — document this limitation.

---

## Ollama

### Existing BurnBar implementation
`AgentLens/Services/ProviderUsageAPI/OllamaUsageProbe.swift` — probes `GET /api/tags` for model discovery. Token accounting deferred to daemon event routing.

### Canonical endpoints
| Endpoint | Purpose | Auth |
|---|---|---|
| `GET /api/tags` | List installed models | None (local) |
| `GET /api/ps` | List running models | None (local) |
| `POST /api/chat` | Chat completion (response includes `eval_count`) | None (local) |
| `POST /api/generate` | Text generation (response includes `eval_count`) | None (local) |

### The fundamental truth
**Ollama has no billing. There is no usage API.**

- Token counts are only available in **per-response metadata** from `POST /api/chat` and `POST /api/generate`:
  - `prompt_eval_count` — input tokens
  - `eval_count` — output tokens
  - `total_duration`, `load_duration`, `prompt_eval_duration`, `eval_duration`
- These are returned in each streaming/non-streaming response as the final JSON object.
- `/api/ps` returns currently-loaded models (name, size, VRAM usage, time until unload) — useful for live status.
- `/api/tags` returns installed models — useful for discovery.

### Token accounting strategy (per BurnBar architecture)
Token counts **must come from daemon event routing** — BurnBar's daemon can intercept or observe the Ollama HTTP server traffic, extract `prompt_eval_count` and `eval_count` from each response, and attribute them to sessions by tracking chat history context.

### Prior art
- **Open WebUI** (the most popular Ollama UI): Tracks token usage by intercepting Ollama's streaming responses and summing `eval_count`/`prompt_eval_count` across turns. Persists to its own database.
- **Litellm** with Ollama provider: Uses the same response metadata. Cost is $0 since Ollama is local.
- **Simonw/llm** with `llm-ollama` plugin: Logs each call with token counts from response metadata.

### Recommendations
1. **Daemon event routing is the right call** — BurnBar's documentation is correct.
2. **`/api/ps` and `/api/tags` for live status** — already implemented in `OllamaUsageProbe.validate()`.
3. **Cost is always $0** — document this clearly.
4. **Model pricing shouldn't attempt to estimate compute cost** — Ollama models have no per-token billing.

### Swift/macOS portability
- All Ollama interactions are local HTTP to `localhost:11434` (or custom `OLLAMA_HOST`).
- `URLSession`, no auth in standard config. Optional `Authorization: Bearer` if the user has configured a proxy/auth layer.
- BurnBar's `OllamaUsageProbe` covers this pattern.

---

## Summary: Provider confidence matrix

| Provider | Canonical source | Confidence | Update cadence | Cost from API? |
|---|---|---|---|---|
| GitHub Copilot | REST `/copilot/metrics` | Exact (daily) | Daily, 24–48h lag | No (must compute) |
| OpenAI | REST `/v1/organization/usage/completions` | Exact (daily) | Daily, < 24h lag | No (must compute) |
| Anthropic | REST `/v1/organizations/usage_report/messages` | Exact (daily) | Daily, ~24h lag | No (must compute) |
| OpenRouter | REST `/api/v1/activity` | Exact (daily) | Daily + near-real-time cost | **Yes** (unique) |
| Z.ai (GLM) | No documented API → daemon events | Per-request exact; aggregate N/A | Per-request | No |
| MiniMax | No documented API → daemon events | Per-request exact; aggregate N/A | Per-request | No |
| Kimi (Moonshot) | `wire.jsonl` disk + `GET /v1/users/me/balance` | Exact (disk), balance (API) | Per-session (disk), real-time (balance) | No |
| Gemini CLI | `~/.gemini/tmp/*/chats/session-*.json` | Exact (disk) | Per-session | No (must compute) |
| Google AI Studio | No billing API | — | — | — |
| Vertex AI | GCP Billing (BigQuery) + per-request metadata | Exact (per-request) | Per-request | No |
| Ollama | Per-response `/api/chat` metadata | Exact (per-request) | Per-request | $0 (local) |

---

## Patterns observed across open-source tools

### litellm (BerriAI/litellm)
- **Approach:** Model-pricing dictionary + response usage parsing.
- **Cost calculation:** `generic_cost_per_token()` dispatches to provider-specific cost functions. Each `cost_calculation.py` handles provider nuances (cache, geo multipliers).
- **Usage tracking:** The proxy logs all calls to its own database with token counts and computed cost.
- **Key insight:** Litellm does NOT call billing APIs — it computes cost from per-request `Usage` objects. The billing APIs are only used for reconciliation/dashboard views.

### simonw/llm
- **Approach:** SQLite database (`~/.llm/logs.db`) stores every prompt/response.
- **Token tracking:** Extracts `input_tokens` and `output_tokens` from each API response's `usage` block.
- **Key insight:** This is the simplest, most portable pattern — intercept the API response, extract the usage object, persist it. No billing API dependency.

### Gemini CLI
- **Approach:** Character-based heuristic for context tracking; per-request `usageMetadata` from Gemini API responses for actual token counts.
- **Session persistence:** `~/.gemini/tmp/` session files with message_update events containing token data.
- **Key insight:** Even Google's own CLI doesn't have a billing API — it relies on per-request metadata saved to disk.

---

## Action items for BurnBar

1. **Kimi balance API** — Add `KimiBalanceProbe` hitting `GET /v1/users/me/balance` with existing Kimi API key. Low effort, high value.
2. **Z.ai/MiniMax daemon event routing** — Instead of probing speculative billing APIs, invest in daemon event routing that captures per-request usage from API responses. This is the only reliable path for these providers.
3. **OpenRouter cost is already returned** — BurnBar's `OpenRouterUsageAPI` correctly uses `total_cost` from the API when available. Verify this path is fully tested.
4. **GitHub Copilot split estimation** — The current 85/15 input/output split is a heuristic. Consider gathering real data from the Copilot extension's network traffic to refine this ratio. The `/copilot/metrics` API only returns `total_tokens`.
5. **Ollama `eval_count` routing** — Implement daemon event routing to capture `eval_count`/`prompt_eval_count` from Ollama responses. Reliable and straightforward.
6. **Google AI Studio limitation** — Document that no billing API exists. Free tier only.
