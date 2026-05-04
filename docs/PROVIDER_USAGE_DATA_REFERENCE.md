# Provider Usage Data Reference — External Prior Art

> Canonical sources-of-truth for real (not estimated) usage/quota data across five
> coding-agent providers. Compiled from open-source tools, API traffic analysis, and
> provider documentation. Last updated: 2026-05-02.

---

## 1. Claude Code (Anthropic)

### 1.1 Disk Artifacts — JSONL Session Logs

**Canonical source:** `~/.claude/projects/<project-name>/*.jsonl` (or `$CLAUDE_CONFIG_DIR/projects/...`)

**Resolution order** (matching `ccusage` by ryoppippi, 13,677 ⭐):
1. `$CLAUDE_CONFIG_DIR` env var (comma-separated paths)
2. `~/.config/claude/projects/` (XDG)
3. `~/.claude/projects/` (legacy default)

**JSONL entry schema** (Valibot-validated by `ccusage`):
```json
{
  "cwd": "/path/to/project",
  "sessionId": "abc123...",
  "timestamp": "2026-04-15T10:30:00.000Z",
  "version": "1.2.3",
  "message": {
    "usage": {
      "input_tokens": 1234,
      "output_tokens": 567,
      "cache_creation_input_tokens": 100,
      "cache_read_input_tokens": 200,
      "speed": "fast"
    },
    "model": "claude-sonnet-4-20250514",
    "id": "msg_abc123"
  },
  "costUSD": 0.0042,
  "requestId": "req_xyz789",
  "isApiErrorMessage": false
}
```

**Key fields:**
- `message.usage.input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`
- `message.model` — model identifier
- `costUSD` — optional, Claude Code may pre-compute this
- `sessionId` — for deduplication across requests
- `timestamp` — ISO 8601 with milliseconds
- Deduplication: `message.id` + `requestId` (cumulative usage per streaming chunk)

**Auth required:** None (local filesystem read only)

**Update cadence:** Real-time — every API call writes a new line

**Portability:** Swift `FileHandle` + `Codable` JSON parsing, trivial

### 1.2 CLI PTY — `/usage` Command

**Method:** Run `claude /usage --allowed-tools ""` in a PTY

**Auth required:**
- OAuth token in macOS Keychain (service: `Claude Code-credentials`)
- Or `~/.claude/.credentials.json` file
- Token must have `user:profile` scope (setup-tokens with `user:inference` won't work)

**Output:** Rendered terminal panel (ANSI-stripped):
- `Current session` → 5-hour window
- `Current week` → 7-day window
- `Claude Opus` / `Claude Sonnet` → model-specific weekly windows
- `Extra usage` → spend/limit (if API Usage Billing enabled)

**Fallback:** `/cost` command for API Usage Billing accounts (no `/usage` support)

**Rate limits:** 20s timeout default (ClaudeBar), PTY auto-responds to trust prompts

### 1.3 OAuth API (CodexBar / ClaudeBar)

**Endpoint:** `GET https://api.anthropic.com/api/oauth/usage`

**Auth:** `Authorization: Bearer <access_token>`, header `anthropic-beta: oauth-2025-04-20`

**Response mapping:**
- `five_hour` → session window
- `seven_day` → weekly window
- `seven_day_sonnet` / `seven_day_opus` → model-specific weekly
- `extra_usage` → monthly spend/limit

**Reference implementations:**
- `steipete/CodexBar` (11,528 ⭐) — Swift, uses Keychain + OAuth API
- `tddworks/ClaudeBar` (1,089 ⭐) — Swift, ClaudeUsageProbe via CLI PTY
- `Dicklesworthstone/coding_agent_usage_tracker` — Rust, multi-provider

### 1.4 Web API (cookies)

**Endpoints:**
- `GET https://claude.ai/api/organizations` → org UUID
- `GET https://claude.ai/api/organizations/{orgId}/usage` → session/weekly/opus
- `GET https://claude.ai/api/organizations/{orgId}/overage_spend_limit` → spend/limit
- `GET https://claude.ai/api/account` → email + plan

**Auth:** `Cookie: sessionKey=sk-ant-...`

### 1.5 Real-Time — Statusline Hook

**Method:** Claude Code writes JSON to stdin of a configured hook script

**JSON schema** (from `chongdashu/cc-statusline`, 587 ⭐):
```json
{
  "session_id": "...",
  "transcript_path": "...",
  "cwd": "...",
  "model": { "id": "...", "display_name": "..." },
  "workspace": { "current_dir": "...", "project_dir": "..." },
  "version": "1.2.3",
  "cost": {
    "total_cost_usd": 0.0042,
    "total_duration_ms": 15000,
    "total_api_duration_ms": 1200,
    "total_lines_added": 10,
    "total_lines_removed": 3
  },
  "context_window": {
    "total_input_tokens": 50000,
    "total_output_tokens": 2000,
    "context_window_size": 200000
  }
}
```

**Setup:** `.claude/settings.json` → `statusLine` hook entry
**Update cadence:** Per-turn (real-time)

---

## 2. Codex CLI (OpenAI)

### 2.1 Disk Artifacts — Session JSONL Logs

**Canonical source:** `~/.codex/sessions/*.jsonl` (or `$CODEX_HOME/sessions/...`)

**Resolution order** (matching `@ccusage/codex`):
1. `$CODEX_HOME` env var
2. `~/.codex/sessions/` (default)

**JSONL entry schema:**
```json
{
  "type": "token_count",
  "payload": {
    "type": "token_count",
    "input_tokens": 1234,
    "cached_input_tokens": 200,
    "output_tokens": 567,
    "reasoning_output_tokens": 100,
    "total_tokens": 1801,
    "info": {
      "model": "gpt-5",
      "model_name": "gpt-5"
    }
  },
  "timestamp": "2026-04-15T10:30:00.000Z"
}
```

**Key differences from Claude JSONL:**
- Cumulative counters (must subtract previous entry for per-event delta)
- `token_count` entry type
- `cached_input_tokens` (a.k.a `cache_read_input_tokens`)
- `reasoning_output_tokens` — **already included in `output_tokens`**; do not double-count
- `total_tokens` — may be absent in legacy logs, synthesize as `input + output`
- Model extraction: check `payload.info.model`, `payload.info.model_name`, `payload.metadata.model`

**Schema change note:** Modern entries include `total_tokens`; legacy entries may omit it. Codex includes reasoning in output (matching LiteLLM pricing).

**Auth required:** None (local filesystem)
**Update cadence:** Per-request (cumulative snapshots written)
**Portability:** Swift `FileHandle` + `Codable` JSON parsing + cumulative-delta math

### 2.2 CLI RPC — JSON-RPC

**Method:** Launch `codex -s read-only -a untrusted app-server`

**JSON-RPC over stdin/stdout:**
1. `initialize` — client info
2. `initialized` — notification
3. `account/rateLimits/read` → rate limits

**Response shape:**
```json
{
  "rateLimits": {
    "planType": "pro",
    "primary": { "usedPercent": 45.2, "resetsAt": 1715299200 },
    "secondary": { "usedPercent": 12.3, "resetsAt": 1715961600 }
  }
}
```

**Reference:** `DefaultCodexRPCClient` in `tddworks/ClaudeBar`

### 2.3 CLI PTY — `/status`

**Method:** Run `codex -s read-only -a untrusted`, send `/status`

**Parsed fields:** `Credits:` line, `5h limit` + `Weekly limit` percentages

**Fallback:** Used when RPC is unavailable; retries once with larger terminal size on parse failure

### 2.4 OAuth API (CodexBar)

**Endpoint:** `GET https://chatgpt.com/backend-api/wham/usage`

**Auth:** `Authorization: Bearer <access_token>` from `~/.codex/auth.json`

**Token refresh:** When `last_refresh` > 8 days old

**Auth file path:** `~/.codex/auth.json` (JWT tokens + refresh token)

### 2.5 Web Dashboard (CodexBar)

**URL:** `https://chatgpt.com/codex/settings/usage`

**Method:** Hidden `WKWebView` evaluating JS scraping scripts.
Extracts rate limits (5h + weekly), credits remaining, code review %, usage breakdown chart data.

**Opt-in:** Toggle in CodexBar prefs ("OpenAI web extras"). Battery-intensive.

---

## 3. Factory (Droid)

### 3.1 Web API (cookies)

**Auth method:** Browser cookies or WorkOS tokens → Factory API

**Cookie sources** (Safari → Chrome → Firefox):
- Domains: `factory.ai`, `app.factory.ai`, `auth.factory.ai`
- Required cookie names: `wos-session`, `__Secure-next-auth.session-token`, `next-auth.session-token`, `__Secure-authjs.session-token`, `session`, `access-token`

**API endpoints:**
- `GET https://app.factory.ai/api/app/auth/me` — org + subscription metadata + feature flags
- `POST https://app.factory.ai/api/organization/subscription/usage` — standard/premium token usage
  - Body: `{ "useCache": true, "userId": "<id>" }`

**Request headers required:**
```
Accept: application/json
Content-Type: application/json
Origin: https://app.factory.ai
Referer: https://app.factory.ai/
x-factory-client: web-app
Authorization: Bearer <token>   (when available)
Cookie: <session cookies>        (when available)
```

**WorkOS token minting** (for session-less auth):
- `POST https://api.workos.com/user_management/authenticate`
- Client IDs: `client_01HXRMBQ9BJ3E7QSTQ9X2PHVB7` or `client_01HNM792M5G5G1A2THWPXKFMXB`
- Grant type: `refresh_token`

**Usage response schema:**
```json
{
  "usage": {
    "startDate": 1715299200,
    "endDate": 1715385600,
    "standard": {
      "userTokens": 5000,
      "orgTotalTokensUsed": 50000,
      "totalAllowance": 100000,
      "usedRatio": 0.5,
      "orgOverageUsed": 0,
      "basicAllowance": 100000,
      "orgOverageLimit": 50000
    },
    "premium": {
      "userTokens": 1000,
      "orgTotalTokensUsed": 5000,
      "totalAllowance": 10000,
      "usedRatio": 0.5
    }
  }
}
```

**Auth required:** Browser cookies (session) or WorkOS bearer token
**Update cadence:** On API call (cached server-side with `useCache: true`)
**Rate limits/ToS:** No public API docs; scraping browser cookies is ToS gray area
**Portability:** Swift `URLSession` + HTTP cookies, `WKWebView` for login capture

**Reference:** `steipete/CodexBar` `FactoryStatusProbe.swift`, `docs/factory.md`

### 3.2 CLI Session Logs (speculative)

Factory's CLI may write session logs locally, but **no open-source tool has documented this path**. The primary data source is the web API.

---

## 4. Cursor

### 4.1 Web API — usage-summary

**Endpoint:** `GET https://cursor.com/api/usage-summary`

**Auth:** `Cookie: WorkosCursorSessionToken={userId}::{accessToken}`

**Response schema:**
```json
{
  "membershipType": "ultra",
  "isUnlimited": false,
  "billingCycleStart": "2026-02-06T03:34:49.000Z",
  "billingCycleEnd": "2026-03-06T03:34:49.000Z",
  "individualUsage": {
    "plan": {
      "enabled": true,
      "used": 326,
      "limit": 40000,
      "remaining": 39674
    },
    "onDemand": {
      "enabled": false,
      "used": 0,
      "limit": null,
      "remaining": null
    }
  }
}
```

**Additional endpoints:**
- `GET https://cursor.com/api/auth/me` — user email + name
- `GET https://cursor.com/api/usage?user=ID` — legacy request-based plan usage

### 4.2 Auth Token Extraction

**Source:** `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (SQLite)

**SQL query:**
```sql
SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'
```

**JWT decoding:** Extract `sub` claim from base64url-decoded payload

### 4.3 Cookie Import (CodexBar pattern)

**Browser cookies** (Safari → Chrome → Firefox):
- Domains: `cursor.com`, `cursor.sh`
- Required cookie: `WorkosCursorSessionToken`, `__Secure-next-auth.session-token`

**Cookie file paths:**
- Safari: `~/Library/Cookies/Cookies.binarycookies`
- Chrome: `~/Library/Application Support/Google/Chrome/*/Cookies`
- Firefox: `~/Library/Application Support/Firefox/Profiles/*/cookies.sqlite`

**Stored session fallback:** `~/Library/Application Support/CodexBar/cursor-session.json`

### 4.4 Enterprise / Team Support

- `limitType: "team"` → parses `teamUsage.onDemand` for team credits
- Enterprise plans: `limit: 0` → fall back to `breakdown.total`
- `totalPercentUsed` used for enterprise usage derivation

**Auth required:** Valid cursor.com session cookie (from browser or stored)
**Update cadence:** On API call (no streaming/push)
**Rate limits/ToS:** Unofficial endpoint, no public docs; cookie-auth is feasible
**Portability:** Swift `Process` to run `/usr/bin/sqlite3`, `URLSession` for API, `Codable` JSON

**Reference implementations:**
- `tddworks/ClaudeBar` `CursorUsageProbe.swift`
- `steipete/CodexBar` `docs/cursor.md`
- `Dwtexe/cursor-stats` (265 ⭐) — Cursor extension for status bar stats

---

## 5. Warp

### 5.1 GraphQL API

**Endpoint:** `POST https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo`

**Auth:** `Authorization: Bearer wk-...` (API key from Warp settings)

**GraphQL query:**
```graphql
query GetRequestLimitInfo($requestContext: RequestContext!) {
  user(requestContext: $requestContext) {
    __typename
    ... on UserOutput {
      user {
        requestLimitInfo {
          isUnlimited
          nextRefreshTime
          requestLimit
          requestsUsedSinceLastRefresh
        }
        bonusGrants {
          requestCreditsGranted
          requestCreditsRemaining
          expiration
        }
        workspaces {
          bonusGrantsInfo {
            grants {
              requestCreditsGranted
              requestCreditsRemaining
              expiration
            }
          }
        }
      }
    }
  }
}
```

**Response shape:**
```json
{
  "data": {
    "user": {
      "__typename": "UserOutput",
      "user": {
        "requestLimitInfo": {
          "isUnlimited": false,
          "nextRefreshTime": "2026-02-28T19:16:33.462988Z",
          "requestLimit": 1500,
          "requestsUsedSinceLastRefresh": 5
        },
        "bonusGrants": [
          { "requestCreditsGranted": 20, "requestCreditsRemaining": 10, "expiration": "2026-03-01T10:00:00Z" }
        ],
        "workspaces": [
          {
            "bonusGrantsInfo": {
              "grants": [
                { "requestCreditsGranted": "15", "requestCreditsRemaining": "5", "expiration": "2026-03-15T10:00:00Z" }
              ]
            }
          }
        ]
      }
    }
  }
}
```

### 5.2 Key Implementation Notes

- **User-Agent required:** `Warp/1.0` — Warp's edge limiter returns HTTP 429 for non-matching user agents
- **String numerics:** `requestCreditsGranted` and `requestsUsedSinceLastRefresh` may be strings in some responses
- **Bonus credits:** Aggregated from user-level `bonusGrants[]` + workspace-level `workspaces[].bonusGrantsInfo.grants[]`
- **Reset time:** `nextRefreshTime` is ISO 8601 with fractional seconds
- **Unlimited plans:** `isUnlimited: true` → full bar; values may be `null` rather than `false`

### 5.3 API Key Setup

- Warp → Settings → Platform → API Keys → create key (format: `wk-...`)
- Env vars: `WARP_API_KEY` or `WARP_TOKEN`
- Reference: `https://docs.warp.dev/reference/cli/api-keys`

**Auth required:** Warp API key (`wk-...`)
**Update cadence:** On GraphQL query (no streaming)
**Rate limits:** Edge limiter with HTTP 429 for non-Warp user agents
**Portability:** Swift `URLSession` with GraphQL query, `Codable` JSON, simple

**Reference:** `steipete/CodexBar` `WarpUsageFetcher.swift`, `docs/warp.md`

### 5.4 Disk Artifacts (speculative)

Warp AI request logs may exist under:
`~/Library/Application Support/dev.warp.Warp-Stable/`

**No open-source tool currently extracts usage from these logs.** The GraphQL API is the primary source.

---

## Summary Matrix

| Provider     | Primary Source                    | Auth Method              | Real-Time? | Disk Artifact? | HTTP Endpoint?          |
|-------------|-----------------------------------|--------------------------|------------|----------------|-------------------------|
| Claude Code | JSONL in `~/.claude/projects/`   | None (local)             | Per-turn   | Yes            | OAuth API (optional)    |
| Codex CLI   | JSONL in `~/.codex/sessions/`    | None (local)             | Cumulative | Yes            | RPC / OAuth API         |
| Factory     | Web API                           | Browser cookies/WorkOS   | On poll    | No             | Yes (`app.factory.ai`)  |
| Cursor      | Web API                           | SQLite JWT → cookie      | On poll    | No             | Yes (`cursor.com/api`)  |
| Warp        | GraphQL API                       | API key (`wk-...`)       | On poll    | No             | Yes (`app.warp.dev`)    |

## External Tool Reference Matrix

| Tool                          | Stars | Language | Providers Covered                        | Approach                          |
|-------------------------------|-------|----------|------------------------------------------|-----------------------------------|
| `ryoppippi/ccusage`           | 13.7k | TS       | Claude Code, Codex, OpenCode, Pi, Amp    | JSONL parsing                     |
| `steipete/CodexBar`           | 11.5k | Swift    | Claude, Codex, Cursor, Warp, Factory+    | macOS menu bar, multi-source      |
| `chongdashu/cc-statusline`    | 587   | TS/Bash  | Claude Code                               | Statusline hook JSON parsing      |
| `tddworks/ClaudeBar`          | 1.1k  | Swift    | Claude, Codex, Cursor, Gemini+           | macOS menu bar, CLI PTY/APIs      |
| `Dicklesworthstone/caut`      | 45    | Rust     | Codex, Claude, Gemini, Cursor, Copilot   | CLI, multi-provider unified       |
| `Dwtexe/cursor-stats`         | 265   | TS       | Cursor                                    | Cursor extension (status bar)     |
| `mm7894215/TokenTracker`      | 370   | ?        | Claude, Codex, Cursor, Gemini+           | Local, multi-provider             |
| `vicarious11/agenttop`        | 44    | ?        | Claude, Cursor, Kiro, Codex, Copilot     | htop-style terminal monitor       |
