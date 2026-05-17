# Routed Client Gateway

OpenBurnBar exposes selected routed models through the local daemon's gateway
so supported clients can share the same provider rotation policy. The gateway
runs on `127.0.0.1:8317` by default and appears in the app as the local
OpenBurnBar gateway.

## Router modes

OpenBurnBar now has a persisted router mode. Existing installs default to
**Provider-Family Failover**.

| Mode | What it does | What it will not do |
|---|---|---|
| **Provider-Family Failover** | Extends capacity across multiple accounts or subscriptions for the selected provider family. A Codex route stays with Codex accounts, a Claude route stays with Claude accounts, and a Z.ai route stays with Z.ai accounts. The exact selected account/model stays active while it is healthy. | It does not treat unrelated providers as one generic coding quota pool. It will not send Codex traffic to Claude, or Claude traffic to Z.ai, just because another provider has quota or looks cheaper. |
| **Intelligent Model Router** | Ranks compatible routes using task intent, model capability, quota/account health, local availability, cost, latency, context-window, reliability, and benchmark freshness signals. User pinning, provider-family constraints, auth, quota exhaustion, safety, and availability still win. | It is advisory, not absolute. It only uses routes that the live catalog advertises for the requested local endpoint; it never silently swaps to another model or provider family. |

The routing cockpit in Settings -> Agents -> CLIs exposes the mode toggle and
shows the current mode, selected route, active route, next fallback, blocked
routes, latest sanitized routing reason, and benchmark freshness status when
Intelligent Model Router is enabled.

## Benchmark source job

The daily `refreshModelLandscapeBenchmarks` Cloud Function normalizes public or
fixture-backed model-landscape data into `model_benchmark_snapshots` and writes
source health into `model_benchmark_source_status`. After those writes, the
same job builds the public model-board rundown at `router_rundowns/<date>` and
`router_rundowns/latest`.

That public rundown is deliberately more stable than a raw leaderboard. A
board of language models runs daily research and analysis tasks over the
source feed, then deterministic code applies the favorite policy: GPT-5.5
xhigh first, Claude Opus 4.7 second, GLM 5.1 third, until a challenger clears
freshness/routability gates plus repeated dethroning margins. Runtime routing
still evaluates user pins, auth, quota, safety, and availability before any
benchmark-derived recommendation can matter.

Current adapters:

- Artificial Analysis API when `ARTIFICIAL_ANALYSIS_API_KEY` is configured.
- Terminal-Bench via Hugging Face leaderboard data where available.
- Design Arena via its documented `/api/v1/models` endpoint when
  `DESIGN_ARENA_API_KEY` is configured, with `DESIGN_ARENA_FIXTURE_JSON` as
  the cached/manual fallback; no private dashboard scraping.
- Manual cached fixtures through `MODEL_LANDSCAPE_MANUAL_FIXTURES_JSON`.

If a source has no configured key, stable public endpoint, or fixture, the job
writes an `unavailable` source status instead of scraping brittle pages.
Attribution is stored with each normalized source. No raw provider keys, cookies,
bearer tokens, or auth material are written to benchmark snapshots or routing
decision events.

Production deploys bind `ARTIFICIAL_ANALYSIS_API_KEY` through Firebase Secret
Manager on the scheduled function. Operators can set optional non-bound source
inputs such as `DESIGN_ARENA_API_KEY`, `DESIGN_ARENA_FIXTURE_JSON`, and
`MODEL_LANDSCAPE_MANUAL_FIXTURES_JSON` through the normal Cloud Functions
runtime environment when those sources are approved for the project.

## Wire-format pools and advertised bridge endpoints

The gateway still keeps native upstream routing by provider format family.
OpenAI-compatible upstream accounts speak OpenAI-shaped APIs, and Anthropic
accounts speak Anthropic Messages upstream. `/v1/models` is the contract that
tells clients which local endpoints BurnBar can serve for each advertised
model. A Claude model can appear in `/v1/models` for `/v1/chat/completions` or
`/v1/responses` only because BurnBar has an explicit Anthropic bridge for
those local endpoints.

| Pool | Endpoint | Format | Upstream providers that participate |
|---|---|---|---|
| **OpenAI-family** | `POST /v1/chat/completions` | OpenAI Chat Completions | OpenAI, Z.ai, MiniMax, Kimi, Ollama Cloud, Ollama Local |
| **Anthropic-family** | `POST /v1/messages` | Anthropic Messages | Anthropic Console (API key), Anthropic Pro/Team (OAuth bearer) |
| **Anthropic bridge** | `POST /v1/chat/completions`, `POST /v1/responses` | Local OpenAI-style request/response translated to upstream Anthropic Messages | Anthropic Console (API key), Anthropic Pro/Team (OAuth bearer) |

A request for a model not advertised for that local endpoint returns `503`
with `No eligible route for <model>. Add or enable an account/provider that
serves this model.` Within a compatible pool, the existing in-flight failover
loop applies — on `429` / `quota_exceeded` / `auth_failed` the gateway marks
the slot, parks it in a five-minute cool-down, and retries against the next
healthy candidate in the same pool.

## What routes today

- **OpenAI-style local endpoint targets:** Cursor (BYOK tunnel), Droid/Factory,
  Forge, OpenCode, Codex CLI in `OPENAI_BASE_URL` mode, any
  OpenAI-compatible IDE.
- **OpenAI-family upstream providers:** OpenAI, Z.ai, MiniMax, Kimi,
  Ollama Cloud, Ollama Local.
- **Anthropic-family client targets:** Claude Code via
  `ANTHROPIC_BASE_URL=http://127.0.0.1:8317` + `ANTHROPIC_AUTH_TOKEN=<gateway-token-or-openburnbar-local>`.
- **Anthropic-family upstream providers:** Anthropic Console (`sk-ant-…`
  routed via the `x-api-key` header), Anthropic Pro/Team (OAuth bearer via
  the `Authorization: Bearer` header).
- **Anthropic bridge targets:** any OpenAI-style client that chooses an
  Anthropic model from `/v1/models`; BurnBar translates Chat Completions or
  Responses requests to Anthropic Messages, then translates the answer back.
- **Endpoint shape:** OpenAI-compatible `/v1/models`, `/v1/chat/completions`,
  `/v1/responses`, plus Anthropic-compatible `/v1/messages`.
- **Usage attribution:** proxied local-client calls record as `OpenBurnBar Gateway`.

Droid/Factory, Forge, OpenCode and Codex are client targets. Their requests
still route through the same upstream accounts and credential slots configured
in OpenBurnBar. OpenCode Go can also be added as an upstream provider: paste an
`opencode-go` auth JSON/key in Accounts, and BurnBar routes through
`https://opencode.ai/zen/go/v1` like any other OpenAI-compatible provider.

## Format-family enforcement

The router policy receives a `requestedFormatFamily` argument from the gateway
that names the pool the request belongs to. `ProviderRoutingPolicy.decide`
filters every candidate by family before ranking, so a Claude Code request
can never be served by an OpenAI account and vice versa. End-to-end coverage
lives in `OpenBurnBarHTTPGatewayServerTests.swift`:

- `testGatewayProxiesAnthropicMessagesHappyPath` — `/v1/messages` 200 path.
- `testGatewayFailsOverAnthropicAccountOnQuotaExhausted` — `429` on primary
  Anthropic slot, traffic shifts to backup in the same request.
- `testCodexOpenAICompatRequestFailsOverWhenPrimaryQuotaExhausted` —
  Codex-shaped `/v1/chat/completions` request fails over from primary to backup.
- `testDroidOpenAICompatRequestFailsOverWhenPrimaryQuotaExhausted` —
  Droid/Factory-shaped `/v1/chat/completions` request fails over from primary
  to backup.
- `testForgeOpenAICompatRequestFailsOverWhenPrimaryQuotaExhausted` —
  Forge-shaped `/v1/chat/completions` request fails over from primary to backup.
- `testGatewayResponsesFallsBackToChatCompletionsWhenProviderDoesNotExposeResponses` —
  Codex-style `/v1/responses` works when the advertised provider only exposes
  chat completions.
- `testGatewayResponsesStreamingFallbackEmitsResponsesEvents` —
  streaming `/v1/responses` fallback emits Responses API SSE events, not raw
  chat-completion chunks.
- `testGatewayModelsAdvertisesAnthropicRoutesWithRealBridgeEndpoints` —
  Claude appears in `/v1/models` with `/v1/messages`, `/v1/chat/completions`,
  and `/v1/responses` only when an Anthropic route exists.
- `testGatewayChatCompletionsRoutesAdvertisedClaudeThroughAnthropicBridge` —
  OpenAI-style chat completions route an advertised Claude model through the
  Anthropic bridge.
- `testGatewayResponsesRoutesAdvertisedClaudeThroughAnthropicBridge` —
  Responses API clients can call an advertised Claude model through the same
  bridge.
- `testClaudeCodeAnthropicRequestFailsOverWhenPrimaryQuotaExhausted` —
  Claude Code-shaped `/v1/messages` request fails over from primary to backup.
- `testGatewayMessagesReturns503WhenOnlyOpenAICompatProvidersConfigured` —
  Anthropic request with no Anthropic accounts → structured 503.
- `testGatewayChatCompletionsReturns503WhenOnlyAnthropicProvidersConfigured` —
  OpenAI-shape request with no model advertised for the local endpoint →
  structured 503.

## Setup

1. Open OpenBurnBar on the Mac that will run the client.
2. Open Settings -> Agents -> CLIs and use **Use local defaults** if the
   gateway is not already on. This enables the loopback gateway at
   `127.0.0.1:8317`.
3. Add at least one provider account in the matching pool. Add a second
   account or key in that pool if you want failover to have somewhere to go.
4. In Settings -> Agents -> CLIs:
   - wire Codex CLI through `~/.codex/config.toml`;
   - sync Droid/Factory through `~/.factory/settings.local.json`,
     `~/.factory/settings.json`, and `~/.factory/config.json`;
   - wire Forge through `~/forge/.forge.toml`;
   - wire Claude Code through `~/.claude/settings.json`.
5. Use **Probe** / **Probe pool** to send a one-token request through the
   gateway before trusting the client setup.

Cursor still needs the Cloudflare quick tunnel path because Cursor BYOK rejects
local/private network URLs. Droid/Factory, Forge, Codex, Claude Code, and
OpenCode use the local gateway URL directly.

## Config Files Written

OpenBurnBar preserves unrelated client config and writes a timestamped backup
before replacing prior OpenBurnBar entries.

| Client | File | OpenBurnBar-owned keys |
|---|---|---|
| Droid/Factory | `~/.factory/settings.local.json` | `customModels` entries with `provider = openai` for models served by OpenAI-owned upstream accounts and `generic-chat-completion-api` for other gateway-served chat models, including bridged Claude models; `id = custom:OpenBurnBar-<model>-<index>`; display names prefixed `OpenBurnBar` |
| Droid/Factory | `~/.factory/settings.json` | Same `customModels` entries as `settings.local.json`, kept in sync because Factory/Droid has used both files across versions |
| Droid/Factory | `~/.factory/config.json` | `custom_models` entries with the same provider adapter choice and display names prefixed `OpenBurnBar` |
| OpenCode | `~/.config/opencode/opencode.json` | `provider.openburnbar`; default `model` only when no model is set |
| Claude Code | `~/.claude/settings.json` | `env.ANTHROPIC_BASE_URL`, `env.ANTHROPIC_AUTH_TOKEN`, plus a marker key `env.OPENBURNBAR_WIRED` so the helper can detect its own previous wiring |
| Codex CLI | `~/.codex/config.toml` | Sentinel-fenced `[model_providers.openburnbar]` block bounded by `# openburnbar:routing — start` / `# openburnbar:routing — end`, with `wire_api = "responses"`. Activate by setting `model_provider = "openburnbar"` in the Codex profile you want routed. |
| Forge CLI | `~/forge/.forge.toml` | Sentinel-fenced OpenBurnBar-owned `[[providers]]` block named `openburnbar` with `url = http://127.0.0.1:8317/v1/chat/completions`, `models = http://127.0.0.1:8317/v1/models`, `api_key_var = OPENBURNBAR_GATEWAY_TOKEN`, and `response_type = OpenAI` |

The client config receives the local gateway URL and either the gateway auth
token or the harmless `openburnbar-local` placeholder when the loopback gateway
is intentionally authless. Raw upstream provider API keys stay in OpenBurnBar's
Keychain-backed provider store.
Every write snapshots the prior file as
`<filename>.openburnbar-backup-<UTC-YYYYMMDD-HHMMSS>` so the change is
reversible by hand if the helper is ever uninstalled.

## Wiring routed CLI clients from the Mac app

`Settings -> Agents -> CLIs` exposes OpenBurnBar-owned client rows for each
supported CLI. For Droid, the button is intentionally direct: `Connect + Sync`
on first setup, then `Sync models` after the row is connected.

Two modes:

1. **Config-file mode (button)** — writes the env / TOML block listed above,
   then runs a 1-token probe (`POST /v1/messages` for Claude Code, `POST
   /v1/responses` for Codex, and `POST /v1/chat/completions` for Forge) to confirm the gateway actually
   serves the wired client before reporting success. Disconnect to remove the
   OpenBurnBar block.
2. **Shell-snippet mode (button)** — opens a copy/pasteable
   `export ANTHROPIC_BASE_URL=…` / `export OPENAI_BASE_URL=…` block for
   users on managed dotfiles or non-standard shells. No file writes.

Droid/Factory consumes custom model arrays, not a sentinel block. Pressing
`Connect + Sync` or `Sync models` asks the local gateway for live `/v1/models`,
filters to route-eligible models served by `/v1/chat/completions` or
`/v1/responses`, and rewrites OpenBurnBar's entries in
`~/.factory/settings.local.json`, `~/.factory/settings.json`, and
`~/.factory/config.json`. Stale OpenBurnBar or local VibeProxy entries on the
gateway port are removed during each sync, so Droid only sees the current
BurnBar catalog. The shared OpenAI-style probe runs after the write.

Codex's ChatGPT-auth mode (browser session cookies) cannot be routed through
a generic proxy; only the API-key path participates in the OpenAI-family pool
today, and the helper card says so explicitly.

Anthropic credentials added through `Add account → Anthropic` are validated
by `AnthropicCredentialProbe` before they show up as routable accounts.
`sk-ant-…` keys get sent as `x-api-key` headers; anything else (Pro/Team
OAuth bearers) is sent as `Authorization: Bearer …`. The probe issues a
real `max_tokens: 1` request against `/v1/messages` so the credential is
charged at most one output token for the verification.

## Ollama Cloud Routing

Ollama Cloud is an upstream routed provider. OpenBurnBar stores the Ollama API
key as a normal provider-plan slot, then proxies gateway chat requests to
`https://ollama.com/api/chat` with `Authorization: Bearer ...`.

Direct Ollama Cloud model IDs omit the local `-cloud` suffix. The catalog still
accepts common client-facing aliases such as `deepseek-v4-flash:cloud`,
`deepseek-v4-flash-cloud`, and `gpt-oss:120b-cloud`, then rewrites them to the
direct cloud names before sending the upstream request.

For less common cloud models, OpenBurnBar accepts `:cloud` and `-cloud` aliases
as routed-client conveniences and strips only that suffix before proxying to the
direct cloud API. Example: `some-model:cloud` is sent upstream as `some-model`.

Local Ollama remains supported through `/v1` or localhost endpoints when you
configure that base URL, but the bundled routed-provider default is the direct
cloud API because that is what can participate in API-key slot rotation.

## Exhausted-Plan Behavior

The daemon gateway does real proxy execution, not a dry route preview. For each
chat completion request it:

1. ranks eligible routes for the requested model;
2. attempts the highest-ranked provider account or slot;
3. records the selected slot;
4. fails over on quota, rate-limit, auth, or exhausted-plan style upstream
   failures when another route is available;
5. records usage from upstream response usage fields when present, or a
   low-confidence estimate when the response is parseable but usage is missing.

Pinned preferred slots stay first while they are healthy. When no preferred
slot is pinned, healthy slots with equivalent scores rotate by least-recently
selected order. Disabled, missing-secret, cooling-down, and exhausted slots are
skipped before route attempts.

This is the same quota-aware path used to avoid a depleted plan while another
configured plan can still serve the model.

## Troubleshooting

- `Choose at least one routed model`: select at least one exposed model before
  syncing Factory or OpenCode.
- `401` from the gateway: confirm the client's written API key matches the
  gateway auth token in OpenBurnBar settings. If the gateway is loopback-only
  and auth is off, `openburnbar-local` is expected.
- Client cannot connect: confirm OpenBurnBar and `OpenBurnBarDaemon` are
  running on the same Mac and that the gateway host/port match the client config.
- Cursor works but Droid/Factory/Forge/OpenCode do not: Cursor may be going
  through the tunnel while local clients use the direct gateway URL; check the
  local `http://127.0.0.1:8317/v1/models` path.
- Ollama Cloud model returns a model-name error: verify the direct model list at
  `https://ollama.com/api/tags`; local `:cloud` and `-cloud` aliases are only
  gateway-facing conveniences.
