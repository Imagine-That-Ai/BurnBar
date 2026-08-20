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
| **Cursor Agent CLI**| `CursorAgentParser.swift` | `.exact` | `~/.cursor-agent/sessions/` (`transcript.jsonl`, `summary.json`, `*.jsonl`) | Local session tokens; exact token limits |
| **Factory** | `FactoryQuotaAdapter.swift` | `.exact` / `.estimated` | `POST app.factory.ai/api/...` | Plan tier, rolling usage, and lane metrics |
| **Junie (JetBrains)** | `JunieParser.swift` | `.exact` / `.estimated` | `~/.junie/sessions/index.jsonl` + `<sessionId>/events.jsonl` (+ live latches in `~/.junie/processes/*.json`) | Local session tokens (explicit usage buckets when present, character-estimate fallback otherwise); no vendor quota API |
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
| **Devin** | _none_ / Local scans | `.unavailable` | `devin` CLI + `/Applications/Devin.app` (Devin Desktop — successor to Windsurf) + `~/.config/Devin/sessions/*.jsonl` | Local CLI + Desktop (Both: `devin-cli` / `devin-desktop` toggle). No Devin session parser is registered (`"ingestion": "unavailable"` in `contracts/provider-ingestion-catalog.json`), so usage stays unavailable and the catalog entry is accounting-only until a parser or API ingestion path ships |
| **Goose** | _none_ / Local scans | `.unavailable` | Install detection | Visual environment detection only |
| **OpenClaw** | _none_ / Local scans | `.unavailable` | Install detection | Visual environment detection only |
| **OpenClaude** | `OpenClaudeQuotaAdapter` | `.unavailable` | Install detection / `openclaude` CLI | Spawned Claude Code fork; no usage API or programmatic quota source |
| **OMP** | `OMPQuotaAdapter` | `.exact` | `omp usage --json --redact` | Oh My Pi local CLI quota reports by provider/account/window |
| **Prime Agent (Prime Intellect)** | `PrimeAgentParser` (local) | `.exact` | `~/.prime/agent/sessions/*.jsonl` (local jsonl: `message.usage` + `cost`) | Recursive Language Model + Continual Harness sessions; per-turn input/output/cacheRead/cacheWrite + exact USD cost; provider auto-detects underlying model (e.g. `muse-spark-1.2`, `gpt-5.6-luna`) |
| **Muse (Meta)** | `MuseParser` (local) | `.exact` | `~/.local/share/muse/sessions/**/*.jsonl` (envelope JSONL, `model_completed` usage, `tool_batch` tools, `started` prompts; microsecond `recorded_at`) | Local session tokens + cached/read/write + reasoning + exact USD via catalog (`muse-spark-1.2` standard $1.25/$4.25/$0.15 or contributor $0.10/$0.20/$0.002); auto-detects workspace + subagent sessions |
| **Vercel fx** | `FxParser.swift` | `.exact` | `~/.fx/sessions/<sessionId>/` (`session.json`, `usage-v2.json`, `events.jsonl`, `display.json`) | Local session exact token counts and exact USD cost via `usage-v2.json`; transcript and tool lifecycle via `events.jsonl`; chat bridge via `fx ask --json` / `--resume` |
| **OpenRouter** | Routed via API key | `.exact` | `GET openrouter.ai/v1/activity` | Per-call exact cost in USD (no quota limits) |
| **Anthropic** | Admin API key | `.estimated` | `GET api.anthropic.com/v1/organizations` | Org-wide messages usage report (~24h lag) |

---

## Confidence Legend

- `.exact` — Data comes from an official API, local CLI artifact, or documented endpoint. No heuristics.
- `.estimated` — Data is derived from OpenBurnBar's own tracking or pricing table fallback, not the vendor.
- `.unavailable` — No legal/feasible data source exists. User sees a clear "Not available" message.

---

## Execution-Source Attribution

Token usage stores three independent identities:

- `provider` / `providerID`: who served or owns the model.
- `usageSource`: how OpenBurnBar learned about the usage (`provider_log`,
  `daemon`, `billing_api`, and so on).
- `executionSourceID` / `executionSourceName` / `executionSourceKind`: the
  product surface that initiated the request, such as `cursor`, `grok-build`,
  `codex-cli`, or `codex-desktop`.

Gateway clients should send `X-OpenBurnBar-Client` with a stable product marker.
Known user-agent markers are accepted as a fallback, but raw header values are
never stored. Dedicated local parsers provide derived-exact historical source
identity. Codex history is attributed from each rollout's `session_meta`; rows
without durable source evidence stay `unknown`.

### Known Execution Sources (visual-toggle eligible → `Both` = `["cli","desktop"]`)

| Source ID | Display Name | Kind | Provider | Visual Surfaces |
|-----------|--------------|------|----------|-----------------|
| `codex-cli` | Codex CLI | `.cli` | Codex | Both (`cli` + `desktop`) |
| `codex-desktop` | Codex Desktop | `.desktopApp` | Codex | Both |
| `claude-code` | Claude Code | `.cli` | Claude Code | Both |
| `claude-desktop` | Claude Desktop | `.desktopApp` | Claude Code | Both |
| `cursor` | Cursor | `.ide` | Cursor | Both (`cli` via `cursor-agent` + IDE) |
| `cursor-desktop` | Cursor Desktop | `.ide` | Cursor | Both |
| `factory-droid` | Factory Droid | `.automation` | Factory | Both |
| `factory-desktop` | Factory Desktop | `.desktopApp` | Factory | Both |
| `minimax-cli` | MiniMax CLI | `.cli` | MiniMax | Both |
| `minimax-desktop` | MiniMax Desktop | `.desktopApp` | MiniMax | Both |
| `zai-cli` | Z.ai CLI | `.cli` | Z.ai | Both |
| `zcode-desktop` | ZCode Desktop | `.desktopApp` | Z.ai | Both |
| `devin-cli` | Devin CLI | `.cli` | Devin | Both |
| `devin-desktop` | Devin Desktop | `.desktopApp` | Devin (successor to Windsurf) | Both |
| `windsurf` | Windsurf | `.ide` | Windsurf (LEGACY) | Legacy → `devin-desktop` |
| `warp` | Warp | `.cli` | Warp | Both |
| `warp-desktop` | Warp Desktop | `.desktopApp` | Warp | Both |
| `ollama` | Ollama | `.service` | Ollama | Both |
| `ollama-desktop` | Ollama Desktop | `.desktopApp` | Ollama | Both |
| `opencode` | OpenCode | `.cli` | OpenCode | Both |
| `hermes` | Hermes | `.cli` | Hermes | Both |
| `hermes-desktop` | Hermes Dashboard | `.desktopApp` | Hermes | Both |
| `cline` | Cline | `.ide` | Cline | CLI-only (plugin — no toggle) |
| `kilo-code` | Kilo Code | `.ide` | Kilo Code | Plugin-only |
| `roo-code` | Roo Code | `.ide` | Roo Code | Plugin-only |
| `augment` | Augment | `.ide` | Augment | Plugin-only |
| `junie` | Junie | `.ide` | Junie | Plugin-only |
| `fx` | fx | `.cli` | fx | CLI-only |

> **Audit-corrected 2026-05-09:** Both = 11 active: `codex`, `claude`, `cursor`, `factory`, `minimax`, `z.ai`, `devin`, `hermes`, `warp`, `opencode`, `ollama` (Windsurf is LEGACY → Devin). Plugin-only (no toggle): `cline`, `kilo`, `roo`, `augment`, `junie`. Toggle eligibility = `visualSurfaces` contains both `cli` and `desktop` in `catalog.json`.

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
| **Cursor Agent** | None | N/A (local file) | N/A | Reads session logs from `~/.cursor-agent/sessions/` |
| **Factory** | Browser cookie + Bearer | Session cookie + `access-token` | `Cookie: {cookie}` + `Authorization: Bearer {token}` | WorkOS-based auth |
| **Warp** | API key | `wk-...` | `Authorization: Bearer {key}` | Created at warp.dev |
| **MiniMax** | Coding Plan API key | `sk-cp-...` | `Authorization: Bearer {key}` | Standard API keys are rejected |
| **MiMo (Xiaomi)** | Token Plan API key | `tp-...` | `Authorization: Bearer {key}` | Configured by cluster (`cn`, `sgp`, `ams`) |
| **Z.ai** | API key | Custom | `Authorization: {key}` (raw) for `/api/monitor/*`; `Authorization: Bearer {key}` for `/api/paas/v4/*` | From BigModel monitor console; Coding Plan quota uses raw-token monitor auth, standard-API validation keeps Bearer |
| **Ollama** | None for local; key for Cloud | Ollama API key | `Authorization: Bearer {key}` for Cloud | Local models do not require credentials |
| **Kimi** | Browser cookie / JWT | KIMI_AUTH_TOKEN | `Authorization: Bearer {token}` | Custom bearer token from kimi.com session |
| **Hermes** | None | N/A (local file) | N/A | Offline JSONL telemetry scraper |
| **Pi Agent** | None | N/A (local file) | N/A | Offline workspace interaction logger |
| **Vercel fx** | CLI auth | N/A (local session files + CLI auth) | N/A | Reads `~/.fx/sessions/` (`session.json`, `usage-v2.json`, `events.jsonl`) |
| **xAI (Grok)** | API key / Management key | `xai-…` inference key; `xai-mgmt-…` for GrokBuild balance | `Authorization: Bearer {key}` | SuperGrok pacing log + Management API; daemon gateway emits pacing events on routed xAI traffic |
| **Grok Build CLI** | Local CLI + optional `XAI_API_KEY` | `grok` binary; sessions under `~/.grok/` | OpenBurnBar gateway block in `config.toml` | Switcher profile `Grok Build`; vendor identity stays `AgentProvider.xAI` |
| **OMP** | Local CLI | `omp` binary | N/A | Uses installed Oh My Pi CLI; OpenBurnBar stores no provider credential |
| **Prime Agent** | None | N/A (local file) | N/A | Reads `~/.prime/agent/sessions/*.jsonl`; sessions are Recursive Language Model + Continual Harness JSONL; `auth.json` / `models.json` hold API keys per routed backend but are not read by BurnBar |
| **Muse** | None | N/A (local file) | N/A | Reads `~/.local/share/muse/sessions/**/*.jsonl` envelope JSONL; `~/.local/share/muse/model-catalog/*.json` holds pricing ($0.10/$0.20/$0.002 contributor, $1.25/$4.25/$0.15 standard) but is not required — catalog fallback pricing applies |

---

## Ollama Local Endpoints

`ollama-local` supports multiple local or LAN Ollama daemons through
`ollamaEndpoints` on the provider config:

```json
{
  "providerID": "ollama-local",
  "baseURL": "http://localhost:11434/v1",
  "ollamaEndpoints": [
    {"id": "desktop", "label": "Desktop", "baseURL": "http://localhost:11434", "priority": 0, "enabled": true},
    {"id": "studio", "label": "Studio", "baseURL": "http://studio.local:11434", "priority": 10, "enabled": true}
  ]
}
```

When the array is absent, the daemon synthesizes one enabled `default` endpoint
from `OLLAMA_HOST`, then the legacy provider base URL with `/v1` stripped, then
`http://localhost:11434`. Each enabled endpoint becomes its own route slot
(`credentialSlotID == endpoint.id`), so cooldown on one local daemon does not
remove the others from routing.

Endpoint `baseURL` values must be `http` or `https`. `apiKeyRef` is optional and
points at a daemon secret-store key for secured LAN proxies; local Ollama uses an
empty key by default.

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
| Cursor Agent | `~/.cursor-agent/sessions/` | File read | Offline session JSONL containing message role, content, and token details |
| Factory | `POST https://api.factory.ai/api/organization/subscription/usage` | HTTP | `{"usage":{"standard":{"userTokens":...},"premium":{...}}}` |
| Warp | `POST https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo` | GraphQL | `{"data":{"workspace":{"requestLimit":...,"requestsUsedSinceLastRefresh":...}}}` |
| MiniMax | `GET https://www.minimax.io/v1/api/openplatform/coding_plan/remains` | HTTP | `{"model_remains":[{"model_name":"...","current_interval_usage_count":...}]}` |
| Z.ai | `GET https://api.z.ai/api/monitor/usage/quota/limit` | HTTP | `[{"type":"TOKENS_LIMIT","unit":3,"remaining":...}]` |
| Kimi | `GET https://kimi.com/api/v1/user/billing` | HTTP | Kimi BillingService payload returning polled usage logs |
| Hermes | `~/.hermes/sessions/*.jsonl` | File read | Offline telemetry schemas parsing UI steps, duration, and local models |
| Pi Agent | `~/.pi/sessions/*.jsonl` | File read | Scrapes conversation tokens and environment properties offline |
| OMP | `omp usage --json --redact` | Local process | Redacted machine-readable usage reports with provider windows and quota buckets |
| Muse | `~/.local/share/muse/sessions/**/session.jsonl` | File read | Envelope JSONL (`runtime.session` → `model_completed` with `input_tokens`/`output_tokens`/`cached_tokens`/`cache_read_tokens`/`reasoning_tokens`, `tool_batch.effect.started` tools, `started` prompts; `session-index.db` is index-only, not parsed) |
| Prime Agent | `~/.prime/agent/sessions/*.jsonl` | File read | Flat JSONL (`type: session` + `type: message` with `message.usage.{input,output,cacheRead,cacheWrite,cost}`) |

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
| Cursor Agent | Real-time on prompt interaction | None |
| Warp | On refresh (polled) | Yes |
| Ollama | Real-time (local); Polled (cloud) | None (local) |
| Kimi | On refresh (polled) | Yes |
| Hermes | Real-time on automation step | None |
| Pi Agent | Real-time on workspace transaction | None |
| OMP | On refresh (polled) | None |
| Muse | Real-time on prompt interaction | None |
| Prime Agent | Real-time on prompt interaction | None |

---

## Anthropic metering split (post-June-15) and routing options

From June 15, Anthropic bills programmatic access (`claude -p`/`--print` and the
Agent SDK) and third-party harnesses against a separate metered credit, distinct
from the interactive Pro/Max subscription window. The local quota adapters above
are unaffected — they read local artifacts and documented endpoints. The
**gateway** routing options that interact with this split live in
[`docs/ROUTED_CLIENT_GATEWAY.md`](ROUTED_CLIENT_GATEWAY.md); all gray-area paths
are off by default:

| Option | Default | Opt-in | Notes |
|---|---|---|---|
| Console API key route | On | Add `sk-ant-api…` in Accounts | Legit default; bills the Console plan, not the subscription window. |
| Interactive handoff (B1) | Manual | `openburnbar-cli claude-handoff …` | Human-driven real `claude` session; companion reconciles the subscription-window token delta. |
| Cross-vendor degrade (B3) | Off | Settings → Agents → Advanced → Experimental routing (or `OPENBURNBAR_CROSS_VENDOR_DEGRADE=1` + optional `…_VENDORS`) | Substitutes an allow-listed OpenAI-compatible vendor on the user's own key when the requested model cannot be served. |

### Relay and hosted chat gateway — both sealed end-to-end (honest label)

Two distinct transport paths share the "Hermes" name; both now seal every frame
end-to-end before it reaches Firestore:

- **End-to-end relay** (`hermes_relay_requests`/`pi_agent_relay_requests` + chunks):
  device-to-device frames are sealed with `HermesRelayCrypto`
  (`p256-hkdf-sha256-aesgcm`) before they reach Firestore. The relay routes
  ciphertext and **never sees plaintext** request/response bodies.
- **Hosted chat gateway** (`hermes_gateway_messages`/`_events`/`_attachments`):
  **Shipped — the gateway is sealed end-to-end.** Each link establishes a P-256
  pairing: the agent publishes its relay public key via `handleRuntimeStatus`,
  the phone publishes its own at `approveHermesGatewayDeviceGrant`, and both
  directions seal with `HermesRelayCrypto` (`p256-hkdf-sha256-aesgcm`). The
  phone seals each event `{text, senderDisplayName, threadId}` and wraps the
  per-event key to the agent (`hermes_gateway_events`); the agent seals each
  reply `{text}` and wraps to the phone (`hermes_gateway_messages`); attachment
  bytes are sealed with a per-attachment key and the manifest carries a sealed
  `{fileName, byteCount, contentType}` (`hermes_gateway_attachments`) — the
  plaintext file name and the file-name segment of the storage path are dropped.
  The server stores only `relayEnvelope` ciphertext + wrapped keys + routing
  metadata (id/sequence/kind/destination), and **never reads** message text,
  sender names, or attachment file names. The registry now lists these as
  `deviceOnly`; only typing/state/clients routing metadata stay `serverSees`.

## Conversation transcript parsers (Streams cockpit)

The quota adapters above answer *"how much is left?"*. A second, independent
family of **transcript parsers** answers *"what was said?"* — they index full
session transcripts (text, token totals, cost, project, working directory) into
the local `conversations` corpus, which then feeds the encrypted hosted backup
and the **Streams conversation cockpit** (`queryConversations`). Parsers conform
to `LogParser` and are registered in `ParserRegistry.defaultParsers()`.

| Provider | Parser | Source | Format | Test seam |
|----------|--------|--------|--------|-----------|
| **Goose** | `GooseParser.swift` | `~/.local/share/goose/sessions/sessions.db` (also `~/Library/Application Support/Block/goose/sessions`); legacy `*.jsonl` fallback | SQLite `sessions` + `messages` tables; `accumulated_*`/`total_tokens`; transcript turns flattened from `messages` | `init(sessionDirectoryOverride:)` |
| **Cursor Agent** | `CursorAgentParser.swift` | `~/.cursor-agent/sessions/` | One JSONL file or nested folder per session; inline precise token counts | reads `provider.logDirectory` |
| **OpenCode** | `OpenCodeParser` (`UsageAggregatorParsers.swift`) | `~/.local/share/opencode/opencode.db` (env: `OPENCODE_DB_PATH`, `OPENCODE_DATA_HOME`, `XDG_DATA_HOME`) | SQLite `session` / `message` / `part` rows with JSON `data` columns; `tokens.{input,output,cache.{read,write}}` | `init(databasePathOverride:)` |
| **Pi Agent** | `PiAgentParser` (`UsageAggregatorParsers.swift`) | `~/.pi/sessions/*.jsonl` | One JSONL file per session; inline `usage` or character-based fallback estimate | reads `provider.logDirectory` |
| **Goose / OpenCode hardening** | both | — | SQLite reads go through GRDB `DatabaseValue.storage`, so a column whose stored type differs from the expected one (e.g. a `TEXT` epoch) resolves instead of force-decode crashing | — |

All indexed transcripts (these plus the existing Codex/Claude/Grok/Hermes/… parsers)
route through `SessionLogSyncService` into the zero-knowledge hosted backup with
server-readable cockpit facets limited to aggregate metadata (tokens, cost, model,
provider, message counts, timing, and generic tool tags). Project and path text are
local-only inputs to keyed Cloud Vault search hashes; they are not stored as raw
manifest fields. Bodies are encrypted client-side with `CloudVaultCrypto`; the
`session_logs` manifest carries only sealed metadata. See
[`docs/OPENBURNBAR_SEARCH_ARCHITECTURE_SPINE.md`](OPENBURNBAR_SEARCH_ARCHITECTURE_SPINE.md)
for the cockpit query surface.

## CLI session restart and handoff

Mobile clients do not reconstruct provider state themselves. iOS, iPadOS, and
Android send `cliAgentSessionAction` over the paired Mac relay, and the physical
Mac executes the same daemon `run.resume` path used by the macOS session browser.

The daemon distinguishes three outcomes:

- `native_resume`: only for providers whose handle can be validated locally
  today (`codex`, `claude_code`).
- `handoff`: a Mac-local `0600` markdown package is written and the selected CLI
  receives a short prompt/file pointer (`droid`, `forge`, `antigravity`, `grok`,
  `cursorAgent`, `opencode`, `gemini`, plus Codex/Claude when native validation
  fails).
- `package_only`: the package is opened/written without claiming provider-native
  continuation.

The package includes full indexed transcript text when available, key files,
commands, tools, source IDs, working directory, and an explicit trust-boundary
warning. Unvalidated providers must not be shown as native continuation even if
their CLI exposes a `--resume` flag; they remain handoff until OpenBurnBar can
prove the local handle maps to the intended session.

---

## Prime Agent via OpenBurnBar Gateway

Prime Agent (Prime Intellect) can route every OpenBurnBar model through the
local BurnBar gateway at `http://127.0.0.1:8317` — the same proxy that already
serves Claude Code (`/v1/messages`), Codex (`/v1/responses`), Droid, Forge,
OpenCode, and Grok Build. Token usage still lands in
`~/.prime/agent/sessions/*.jsonl` and BurnBar's `PrimeAgentParser` reads it
as `.exact` (including `usage.cost.total` when the gateway records it).

### One-liner (recommended)

```bash
node scripts/prime-agent-openburnbar-proxy.mjs        # static catalog -> ~/.prime/agent/models.json
node scripts/prime-agent-openburnbar-proxy.mjs --live # live gateway /v1/models first, then catalog fallback
```

This merges an `openburnbar` provider into `~/.prime/agent/models.json`
(`baseUrl: http://127.0.0.1:8317/v1`, `api: openai-completions`, `apiKey`
resolved at request time from the daemon LaunchAgent plist → keychain →
`$OPENBURNBAR_GATEWAY_AUTH_TOKEN` → `openburnbar-local`). All 150+ BurnBar
catalog models appear as `openburnbar/<model-id>` in `prime-agent /model` and
`prime-agent model list openburnbar`:

```
openburnbar  claude-opus-4-8         200K  64K  yes  yes
openburnbar  claude-sonnet-4-6       200K  64K  yes  yes
openburnbar  gpt-5.6-luna            400K  16K  yes  yes
openburnbar  gemini-3.1-pro-preview  1.0M  16K  no   yes
```

Then:

```bash
prime-agent --provider openburnbar --model claude-sonnet-4-6 -p "hello via burnbar"
prime-agent --provider openburnbar --model gpt-5.6-luna -p "hello via burnbar"
# or interactively: /model -> openburnbar/claude-sonnet-4-6
```

### Manual `models.json` fragment

```json
{
  "providers": {
    "openburnbar": {
      "name": "OpenBurnBar Gateway",
      "baseUrl": "http://127.0.0.1:8317/v1",
      "api": "openai-completions",
      "apiKey": "!plutil -extract EnvironmentVariables.OPENBURNBAR_GATEWAY_AUTH_TOKEN raw ~/Library/LaunchAgents/com.openburnbar.daemon.plist 2>/dev/null || security find-generic-password -a $USER -s com.openburnbar.daemon.gatewayAuthToken -w 2>/dev/null || echo $OPENBURNBAR_GATEWAY_AUTH_TOKEN || echo openburnbar-local",
      "models": [
        { "id": "claude-sonnet-4-6", "name": "Claude Sonnet 4.6 (via OpenBurnBar)", "reasoning": true, "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 64000, "cost": { "input": 3, "output": 15, "cacheRead": 0.3, "cacheWrite": 3.75 } }
      ]
    }
  }
}
```

The script preserves other providers in `models.json` (e.g., `meta`) and is
idempotent. Use `--status` to inspect, `--print` to preview without writing,
`--remove` to detach, and `--gateway-host`/`--gateway-port` when the daemon
runs on a non-default interface. Re-run after updating BurnBar or rotating the
gateway token; `--live` reflects the gateway's currently advertised set.

Gateway execution source for these turns is `primeAgent`/`prime-agent`, so
BurnBar's ledger attributes spend correctly and the PrimeAgent parser's cost
fallback uses `ModelPricing.lookup(providerID:"prime-agent")` when `cost.total`
is absent.


## Advertising a model the catalog doesn't know (custom models)

The proxy's `/v1/models` list is built by `BurnBarLiveModelCatalog` from two
sources: each provider's static catalog seed (`OpenBurnBarCore/.../Resources/catalog.json`)
**plus** whatever the provider's live `/models` endpoint returns once it has a
usable credential. New models therefore appear automatically the moment a
provider is enabled with a working key — no catalog edit needed.

When that isn't enough (a model newer than the shipped catalog that a
no-credential provider's live discovery can't surface, or an upstream that
doesn't list the id), users can declare a **custom model**:

- **UI:** Settings → Agents → Models → **Add model** → pick the provider, type
  the id the provider serves (e.g. `minimax-m3`, `glm-5.1`, `kimi-k2.6:cloud`),
  optional display name. The same sheet lists and removes existing custom models.
- **Contract:** `BurnBarCustomModel` on `BurnBarProviderSettings.customModels`
  (`BurnBarProviderContracts.swift`). Daemon RPCs
  `daemon.provider.custom_model.upsert` / `.remove`
  (`BurnBarConfigStore.upsertCustomModel` / `removeCustomModel`).
- **Routing:** `resolvedConfigurations()` folds custom models into the provider's
  `preferredModels` as synthesized public catalog rows, so a custom id both
  advertises in `/v1/models` and routes verbatim to that provider. Like seeded
  models, a custom model is only route-eligible — and only appears on the public
  `/v1/models` — once its provider has a usable credential and eligible quota.
- Ids already known to the catalog (by id, alias, or matcher) are skipped, so a
  custom entry never duplicates or shadows a real model.

---

## Adding a New Provider

1. Create `{Provider}QuotaAdapter.swift` conforming to `ProviderQuotaAdapter`.
2. Add to `QuotaRefreshActor.swift` adapters dictionary and providers list.
3. Add to `ProviderQuotaService.swift` `supportedProviders`.
4. Set `confidence: .exact` for real data; `.unavailable` if no source exists.
5. **Never** return `confidence: .estimated` — ban the path unless it is a gateway wrapper.
6. Add a golden-fixture test in `AgentLensTests/Active/ProviderQuota/`.
7. Update this file with endpoint, auth type, credential format, and response shape.
