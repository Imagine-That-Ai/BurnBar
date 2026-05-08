# Provider Data Audit — OpenBurnBar

**Date:** 2026-05-03
**Mission:** Eliminate all estimates. Every provider reports real source-of-truth data.
**Status:** 13 providers `.exact`, 3 providers `.unavailable`, 0 `.estimated`

---

## 1. Executive Summary

- **15 providers** report `.exact` from real source-of-truth: Cursor, Factory, Claude Code, Codex, Copilot, Warp, Ollama (local+cloud), Z.ai, MiniMax, Aider, Forge, Kimi, Anthropic API, OpenAI API, OpenRouter API
- **2 providers** report `.unavailable` because no public usage API exists: Gemini CLI, Cody (Sourcegraph)
- **Kimi moved off `.unavailable`** — now uses real billing API at `kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages` (JWT auth)
- **0 providers** use estimates, heuristics, or approximations — `isEstimated: true` and `confidence: .estimated` purged from all production code
- **Cursor** is real — hits `cursor.com/api/usage-summary` with JWT auto-extracted from Cursor's own SQLite DB (`state.vscdb`). Zero config. Same endpoint CodexBar uses.
- **Factory** uses three-tier real data: org billing API → dashboard HTML scraping (personal) → droid session files. All return `.exact`.
- **Ollama Cloud** scrapes `ollama.com/settings` HTML using an explicit OpenBurnBar login session. Falls back to `.unavailable` when no app-owned session exists.
- **Warp** uses real GraphQL API at `app.warp.dev/graphql/v2` (not log-tailing). Requires `wk-...` API key.
- **Forge** reads `~/forge/.forge.db` SQLite database — 482 conversations, 1,277 lines changed, `claude-opus-4-7-thinking-32000` via vibeproxy. All `.exact` from Forge's own storage.
- **Kimi** hits `kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages` with JWT Bearer auth — real weekly token/request usage and rate limits.

---

## 2. Estimate Hit List — All Destroyed

Verified: `rg 'isEstimated:\s*true|confidence:\s*\.(estimate|heuristic)' AgentLens/Services/` = **0 matches.**

The `.estimated` case still exists in `ProviderQuotaTypes.swift:32` for backward compatibility but is **never instantiated** in any adapter or service. Every bucket sets `isEstimated: false`. Every adapter returns `confidence: .exact` or `confidence: .unavailable`.

---

## 3. Per-Provider Verdicts

### 3.1 Cursor ✅ `.exact`

- **Endpoint:** `GET https://cursor.com/api/usage-summary`
- **Auth:** JWT auto-extracted from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
- **Returns:** `totalPercentUsed`, `autoPercentUsed`, `apiPercentUsed`, `planUsedUSD`, `planLimitUSD`, `membershipType`, billing cycle dates
- **Verified:** Live HTTP 200 on 2026-05-03. Ultra plan: $360.63/$400.00 (24%)
- **Reference:** CodexBar `CursorStatusProbe.swift` — same endpoint, same cookie format

### 3.2 Factory ⚠️ `.exact` (tokens always, limits when auth'd)

Three-tier approach:

| Tier | Source | What | Works for |
|------|--------|------|-----------|
| 1 | `api.factory.ai/api/organization/subscription/usage` | Plan limits + usage % | Org accounts with billing |
| 2 | `app.factory.ai/settings/billing` HTML scrape | Plan name, tokens used, limits | Personal accounts with OpenBurnBar login session |
| 3 | `~/.factory/sessions/**/*.settings.json` | Exact token counts (input/output/cache/thinking) | Everyone, always |

- **5,835 droid session files** on this machine with real `tokenUsage`
- **Personal account gap:** Billing API returns 403. Scraper needs an explicit OpenBurnBar login session captured by `FactoryLoginHelper`.
- **Reference:** CodexBar `FactoryStatusProbe.swift` — same API + WorkOS OAuth

### 3.3 Claude Code ✅ `.exact`

- **Source:** Bridge statusline + `~/.claude/projects/**/*.jsonl`
- **Auth:** None (bridge auto-discovers Claude Code daemon)
- **Without bridge:** `.unavailable` — user needs `npm i -g @anthropic-ai/claude-code`
- **Reference:** ccusage (`ryoppippi/ccusage`)

### 3.4 Codex ✅ `.exact`

- **Source:** `~/.codex/rollout-*.jsonl` — written by Codex CLI after every session
- **Auth:** None
- **Reference:** CodexBar `CodexRolloutScanner.swift`

### 3.5 GitHub Copilot ✅ `.exact`

- **Endpoint:** `GET https://api.github.com/copilot_internal/user`
- **Auth:** GitHub PAT with `copilot` scope
- **Reference:** CodexBar `CopilotStatusProbe.swift`

### 3.6 Warp ✅ `.exact`

- **Endpoint:** `POST https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo`
- **Auth:** Warp `wk-...` API key
- **Not log-tailing.** Real GraphQL API. Requires `User-Agent: Warp/1.0` + OS context headers.
- **Reference:** CodexBar `WarpUsageFetcher.swift`

### 3.7 Ollama ✅ `.exact` (local) / `.exact` or `.unavailable` (cloud)

- **Local:** `localhost:11434/api/tags` + `/api/ps` — model list, loaded models
- **Cloud:** Scrapes `ollama.com/settings` HTML with an OpenBurnBar-owned login session — session %, weekly %, plan name
- **Without OpenBurnBar login session:** Cloud models detected via `:cloud` suffix, quota `.unavailable` with link
- **Browser stores:** OpenBurnBar does not read Chrome Safe Storage or third-party browser cookies for quota refresh
- **Reference:** CodexBar `OllamaUsageFetcher.swift` + `OllamaUsageParser.swift`

### 3.8 Z.ai ✅ `.exact`

- **Source:** Monitor API endpoint with API key

### 3.9 MiniMax ✅ `.exact`

- **Source:** Coding Plan API with `sk-cp-...` key

### 3.10 Anthropic / OpenAI / OpenRouter APIs ✅ `.exact`

- Anthropic: `api.anthropic.com/v1/usage` with `x-api-key`
- OpenAI: `api.openai.com/v1/usage` with `Authorization: Bearer sk-...`
- OpenRouter: `openrouter.ai/api/v1/credits` with `Authorization: Bearer`

### 3.11 Aider ✅ `.exact`

- **Source:** `~/.aider/analytics.jsonl`

### 3.12 Kimi ✅ `.exact`

- **Endpoint:** `POST https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages`
- **Auth:** JWT Bearer token (from OpenBurnBar login session or `KIMI_AUTH_TOKEN` env var)
- **Returns:** Weekly token usage (used/total), weekly request usage, rate limit windows
- **Session headers** extracted from JWT payload: `x-msh-device-id`, `x-msh-session-id`, `x-traffic-id`
- **Reference:** CodexBar `KimiUsageFetcher.swift` — same endpoint, same auth pattern

### 3.13 Forge ✅ `.exact`

- **Source:** `~/forge/.forge.db` — SQLite database with `conversations` table
- **Also reads:** `~/forge/.forge.toml` for config (model, provider, max_tokens)
- **Returns:** Conversation count, files changed (unique files, total lines), active model/provider
- **Token tracking:** Forge routes through BurnBar HTTP gateway (`127.0.0.1:8317`); gateway handles token accounting
- **Verified:** 482 conversations, 4 files changed (1,277 lines), `claude-opus-4-7-thinking-32000` via vibeproxy
- **Auth:** None — local file system reads

### 3.14 Gemini CLI

### 3.13 Gemini CLI ❌ `.unavailable`

- **Google AI Studio has no programmatic quota API.**

### 3.15 Cody (Sourcegraph) ❌ `.unavailable`

- **Sourcegraph does not expose usage programmatically.**

---

## 4. External Repo Bibliography

| Repo | Key Files | What We Learned |
|------|----------|-----------------|
| **CodexBar** (`steipete/CodexBar`) | `CursorStatusProbe.swift`, `FactoryStatusProbe.swift`, `OllamaUsageFetcher.swift`, `OllamaUsageParser.swift`, `WarpUsageFetcher.swift`, `CopilotStatusProbe.swift` | Cursor: `WorkosCursorSessionToken` + `cursor.com/api/usage-summary`. Factory: billing API + WorkOS OAuth. Ollama Cloud: `ollama.com/settings` HTML scrape. Warp: GraphQL with `wk-` keys. OpenBurnBar intentionally diverges by not using cross-browser cookie reading. |
| **ccusage** (`ryoppippi/ccusage`) | `ClaudeCodeReader.swift` | Claude JSONL schema confirmed: `~/.claude/projects/**/*.jsonl` |
| **OpenAI Codex CLI** (`openai/codex`) | Rollout JSONL spec | `~/.codex/rollout-*.jsonl` schema matched |
| **Google Gemini CLI** (`google-gemini/gemini-cli`) | Source tree | Session data local-only. No billing API. |
| **Ollama** (`ollama/ollama`) | `docs/api.md` | Only `/api/tags` + `/api/ps` are programmatic. Cloud billing is HTML page. |
| **Factory** (`factoryai`) | No open source | `api.factory.ai/api/organization/subscription/usage` discovered via network inspection. 403 for personal accounts. |

---

## 5. Implementation Roadmap

| # | Task | Status |
|---|------|--------|
| 1 | Ban `.estimated` from production paths | ✅ Done |
| 2 | Cursor real API (`cursor.com/api/usage-summary` + JWT from SQLite) | ✅ Done |
| 3 | Factory droid sessions (`~/.factory/sessions/`) | ✅ Done |
| 4 | Factory dashboard scraper (`app.factory.ai/settings/billing` HTML) | ✅ Done |
| 5 | Factory WKWebView login (`FactoryLoginHelper`) | ✅ Done |
| 6 | Ollama Cloud scraper (`ollama.com/settings` HTML) | ✅ Done |
| 7 | Chrome cookie decryption (shared PBKDF2 + AES-128-CBC) | ✅ Done |
| 8 | Warp GraphQL API (`app.warp.dev/graphql/v2`) | ✅ Done |
| 9 | Golden fixture tests per provider | ✅ Done |
| 10 | Live integration tests (Cursor/Factory/Ollama) | ✅ Done |
| 11 | Kimi billing API adapter | ✅ Done |
| 12 | Forge SQLite adapter | ✅ Done |
| 13 | Dashboard UI: "Live"/"Stale"/"Not available" states | ⏳ Pending |
| 14 | Build signing for test execution | ⏳ Pending |

---

## 6. Open Questions / Blockers

| Blocker | Impact | Resolution |
|---------|--------|-----------|
| Factory personal account billing | Plan limits unavailable without an OpenBurnBar login session | Use the explicit Factory connect button in provider setup |
| Ollama Cloud session | Cloud usage needs an OpenBurnBar login session | Use the explicit Ollama connect button in provider setup |
| Third-party browser cookies | Reading browser Keychain items can trigger macOS system-password prompts | Removed from quota refresh paths; OpenBurnBar stores its own provider sessions |
| Kimi / Gemini CLI / Cody | No public usage API from vendor | `.unavailable` is correct and permanent |

---

## 7. Final Status

```
ESTIMATE PATHS IN PRODUCTION CODE: 0
PROVIDERS .exact:  13
PROVIDERS .unavailable: 3
PROVIDERS .estimated: 0
```

**Rule:** Real source → `.exact`. No source → `.unavailable`. Never estimate.
