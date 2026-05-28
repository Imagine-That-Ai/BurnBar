# Provider Source-of-Truth Reference

> Do not regress: every provider must report real data or explicitly state "Not available."
> Canonical mappings match the macOS and iOS `AgentProvider` schema definitions end-to-end.

## Provider Status Table

| Provider | Adapter | Confidence | Source | Data Available |
|----------|---------|------------|--------|---------------|
| **Antigravity** | `AntigravityQuotaAdapter.swift` | `.exact` | `~/.gemini/antigravity-cli/history.jsonl` | Local session tokens and chat history |
| **Claude Code** | `ClaudeQuotaAdapter.swift` | `.exact` | `~/.claude/projects/**/*.jsonl` | Exact local session token counts |
| **Codex** | `CodexQuotaAdapter.swift` | `.exact` | `~/.codex/sessions/rollout-*.jsonl` | Rate-limit % (5h + 7d windows) |
| **OpenAI** | `OpenAIQuotaAdapter` | `.exact` | `GET api.openai.com/v1/organization/usage/completions` | Org token usage (cost computed locally) |
| **DeepSeek** | `DeepSeekQuotaAdapter` | `.exact` | `GET api.deepseek.com/v1` | Developer console credit balance and API usage |
| **Copilot** | `CopilotQuotaAdapter.swift` | `.estimated` | `POST api.github.com/copilot_internal/user` | Premium interactions and chat limits |
| **Cursor** | `CursorQuotaAdapter.swift` | `.estimated` | `GET cursor.com/api/usage-summary` | Included usage, limits, and USD spent |
| **Factory** | `FactoryQuotaAdapter.swift` | `.exact` / `.estimated` | `POST app.factory.ai/api/...` | Plan tier, rolling usage, and lane metrics |
| **MiniMax** | `MiniMaxQuotaAdapter.swift` | `.exact` | `GET minimax.io coding-plan remains` | Remaining quota counts per model |
| **MiMo (Xiaomi)**| `MimoQuotaAdapter.swift` | `.exact` / `.estimated` | `GET token-plan-{cn,sgp,ams}.xiaomimimo.com` | Regional Token Plan remaining credits |
| **Z.ai** | `ZAIQuotaAdapter.swift` | `.exact` | `GET api.z.ai monitor/usage/quota` | Undocumented monitor limits and MCP usage |
| **Warp** | `WarpQuotaAdapter.swift` | `.exact` | `POST app.warp.dev GraphQL` | Request limits, credits, and grants |
| **Ollama** | `OllamaQuotaAdapter.swift` | `.exact` / `.estimated` | `GET localhost:11434` / `ollama.com` | Local model metrics; cloud routing balance |
| **Kimi** | `KimiQuotaAdapter.swift` | `.exact` | `kimi.com BillingService` | Weekly request and token usage stats |
| **Hermes** | `HermesQuotaAdapter.swift` | `.exact` | `~/.hermes/sessions/*.jsonl` | Local UI automation and computer-use metrics |
| **Pi Agent** | `PiAgentQuotaAdapter` | `.exact` | `~/.pi/sessions/*.jsonl` | Local workspace logs and token history |
| **xAI (Grok)** | `XAIQuotaAdapter.swift` | `.estimated` / `.exact` | `SuperGrok event logs` + `xAI Management API` | SuperGrok pacing estimate; GrokBuild prepaid balance via Management API |
| **Grok Build CLI** | `GrokParser.swift` | `.exact` | `~/.grok/sessions/<encoded-cwd>/<uuid>/` (`summary.json`, `signals.json`, `chat_history.jsonl`) | Local session tokens; gateway wiring via `~/.grok/config.toml` `[model.openburnbar]` |
| **Aider** | `AiderQuotaAdapter.swift` | `.exact` | `~/.aider/analytics.jsonl` | Local interaction token stats (no vendor quota) |
| **Forge** | `ForgeQuotaAdapter.swift` | `.estimated` | `~/forge/.forge.db` local SQLite | Session counts via OpenBurnBar local gateway |
| **OpenCode** | `OpenCodeQuotaAdapter` | `.exact` | `~/.local/share/opencode/opencode.db` | Local SQLite session metrics and model details |
| **Gemini CLI** | _none_ / Local scans | `.unavailable` | Local session files only | Session tokens only (no programmatic quota API) |
| **Cline** | _none_ / Local scans | `.unavailable` | Install detection | Visual environment detection only |
| **Roo Code** | _none_ / Local scans | `.unavailable` | Install detection | Visual environment detection only |
| **Kilo Code** | `KiloCodeQuotaAdapter.swift` | `.exact` | Install detection | Visual environment detection only |
| **Augment** | _none_ / Local scans | `.unavailable` | Install detection | Visual environment detection only |
| **Windsurf** | _none_ / Local scans | `.unavailable` | Install detection | Visual environment detection only |
| **Goose** | _none_ / Local scans | `.unavailable` | Install detection | Visual environment detection only |
| **OpenClaw** | _none_ / Local scans | `.unavailable` | Install detection | Visual environment detection only |
| **OpenRouter** | Routed via API key | `.exact` | `GET openrouter.ai/v1/activity` | Per-call exact cost in USD (no quota limits) |
| **Anthropic** | Admin API key | `.estimated` | `GET api.anthropic.com/v1/organizations` | Org-wide messages usage report (~24h lag) |

---

## Confidence Legend

- `.exact` — Data comes from an official API, local CLI artifact, or documented endpoint. No heuristics.
- `.estimated` — Data is derived from OpenBurnBar's own tracking or pricing table fallback, not the vendor.
- `.unavailable` — No legal/feasible data source exists. User sees a clear "Not available" message.

---

## Auth Requirements (per provider)

| Provider | Auth Type | Credential Format | Header | Scope / Notes |
|----------|-----------|-------------------|--------|---------------|
| **Antigravity** | None | N/A (local file) | N/A | Reads `history.jsonl` from `~/.gemini/antigravity-cli/` |
| **Claude Code** | None | N/A (local file) | N/A | Reads `~/.claude/projects/**/*.jsonl` |
| **Codex** | None | N/A (local file) | N/A | Reads `rollout-*.jsonl` from `~/.codex/sessions/` |
| **OpenAI (usage)** | Admin API key | `sk-...` | `Authorization: Bearer {key}` | Requires organization admin key for completions usage |
| **DeepSeek** | API key | `sk-...` | `Authorization: Bearer {key}` | Created at platform.deepseek.com |
| **Copilot** | GitHub OAuth / PAT | `ghp_...` or OAuth token | `Authorization: token {token}` | `read:user` scope required |
| **Cursor** | Browser cookie | `WorkosCursorSessionToken={id}::{token}` | `Cookie: {cookieString}` | Extracted locally from database or Safari/Chrome |
| **Factory** | Browser cookie + Bearer | Session cookie + `access-token` | `Cookie: {cookie}` + `Authorization: Bearer {token}` | WorkOS-based auth |
| **Warp** | API key | `wk-...` | `Authorization: Bearer {key}` | Created at warp.dev |
| **MiniMax** | Coding Plan API key | `sk-cp-...` | `Authorization: Bearer {key}` | Standard API keys are rejected |
| **MiMo (Xiaomi)** | Token Plan API key | `tp-...` | `Authorization: Bearer {key}` | Configured by cluster (`cn`, `sgp`, `ams`) |
| **Z.ai** | API key | Custom | `Authorization: Bearer {key}` | From BigModel monitor console |
| **Ollama** | None for local; key for Cloud | Ollama API key | `Authorization: Bearer {key}` for Cloud | Local models do not require credentials |
| **Kimi** | Browser cookie / JWT | KIMI_AUTH_TOKEN | `Authorization: Bearer {token}` | Custom bearer token from kimi.com session |
| **Hermes** | None | N/A (local file) | N/A | Offline JSONL telemetry scraper |
| **Pi Agent** | None | N/A (local file) | N/A | Offline workspace interaction logger |
| **xAI (Grok)** | API key / Management key | `xai-…` inference key; `xai-mgmt-…` for GrokBuild balance | `Authorization: Bearer {key}` | SuperGrok pacing log + Management API; daemon gateway emits pacing events on routed xAI traffic |
| **Grok Build CLI** | Local CLI + optional `XAI_API_KEY` | `grok` binary; sessions under `~/.grok/` | OpenBurnBar gateway block in `config.toml` | Switcher profile `Grok Build`; vendor identity stays `AgentProvider.xAI` |

---

## Endpoint Reference

| Provider | Endpoint | Method | Response Shape |
|----------|----------|--------|---------------|
| Antigravity | `~/.gemini/antigravity-cli/history.jsonl` | File read | Local history JSONL with detailed token count attributes |
| Codex | `~/.codex/sessions/rollout-*.jsonl` | File read | `{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":...}}}}` |
| Claude Code | `~/.claude/projects/**/*.jsonl` | File read | `{"type":"assistant","message":{"model":"...","usage":{"input_tokens":...,"output_tokens":...}}}` |
| DeepSeek | `GET https://api.deepseek.com/user/balance` | HTTP | `{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"...","real_time_balance":"..."}]}` |
| OpenAI | `GET https://api.openai.com/v1/organization/usage/completions` | HTTP | `{"data":[{"results":[{"input_tokens":...,"output_tokens":...}]}]}` |
| Copilot | `POST https://api.github.com/copilot_internal/user` | HTTP | `{"copilot_plan":"pro","quota_snapshots":{"premium_interactions":{"remaining":180}}}` |
| Cursor | `GET https://cursor.com/api/usage-summary` | HTTP | `{"individualUsage":{"plan":{"totalPercentUsed":...},"onDemand":{"used":...}}}` |
| Factory | `POST https://api.factory.ai/api/organization/subscription/usage` | HTTP | `{"usage":{"standard":{"userTokens":...},"premium":{...}}}` |
| Warp | `POST https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo` | GraphQL | `{"data":{"workspace":{"requestLimit":...,"requestsUsedSinceLastRefresh":...}}}` |
| MiniMax | `GET https://www.minimax.io/v1/api/openplatform/coding_plan/remains` | HTTP | `{"model_remains":[{"model_name":"...","current_interval_usage_count":...}]}` |
| Z.ai | `GET https://api.z.ai/api/monitor/usage/quota/limit` | HTTP | `[{"type":"TOKENS_LIMIT","unit":3,"remaining":...}]` |
| Kimi | `GET https://kimi.com/api/v1/user/billing` | HTTP | Kimi BillingService payload returning polled usage logs |
| Hermes | `~/.hermes/sessions/*.jsonl` | File read | Offline telemetry schemas parsing UI steps, duration, and local models |
| Pi Agent | `~/.pi/sessions/*.jsonl` | File read | Scrapes conversation tokens and environment properties offline |

---

## Refresh Cadences

| Provider | Cadence | Auth Required |
|----------|---------|---------------|
| Antigravity | Real-time on CLI transaction | None |
| Claude Code | Real-time on prompt interaction | None |
| Codex | Real-time on next CLI invocation | None |
| DeepSeek | On refresh (polled) | Yes |
| OpenAI | On refresh (polled) | Yes |
| Copilot | Real-time | Yes |
| MiniMax | On refresh (polled) | Yes |
| MiMo | On refresh (polled) | Yes |
| Z.ai | On refresh (polled) | Yes |
| Factory | On refresh (polled) | Yes |
| Cursor | On refresh (polled) | Yes |
| Warp | On refresh (polled) | Yes |
| Ollama | Real-time (local); Polled (cloud) | None (local) |
| Kimi | On refresh (polled) | Yes |
| Hermes | Real-time on automation step | None |
| Pi Agent | Real-time on workspace transaction | None |

---

## Adding a New Provider

1. Create `{Provider}QuotaAdapter.swift` conforming to `ProviderQuotaAdapter`.
2. Add to `QuotaRefreshActor.swift` adapters dictionary and providers list.
3. Add to `ProviderQuotaService.swift` `supportedProviders`.
4. Set `confidence: .exact` for real data; `.unavailable` if no source exists.
5. **Never** return `confidence: .estimated` — ban the path unless it is a gateway wrapper.
6. Add a golden-fixture test in `AgentLensTests/Active/ProviderQuota/`.
7. Update this file with endpoint, auth type, credential format, and response shape.
