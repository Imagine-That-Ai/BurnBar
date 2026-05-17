# Routed Client Gateway — the Fire Hydrant

OpenBurnBar exposes selected routed models through the local daemon's gateway
so supported clients can share the same provider rotation policy. The gateway
runs on `127.0.0.1:8317` and is the named "Fire Hydrant" in user-facing copy.

## Router modes

OpenBurnBar now has a persisted router mode. Existing installs default to
**Provider-Family Failover**.

| Mode | What it does | What it will not do |
|---|---|---|
| **Provider-Family Failover** | Extends capacity across multiple accounts or subscriptions for the selected provider family. A Codex route stays with Codex accounts, a Claude route stays with Claude accounts, and a Z.ai route stays with Z.ai accounts. The exact selected account/model stays active while it is healthy. | It does not treat unrelated providers as one generic coding quota pool. It will not send Codex traffic to Claude, or Claude traffic to Z.ai, just because another provider has quota or looks cheaper. |
| **Intelligent Model Router** | Ranks compatible routes using task intent, model capability, quota/account health, local availability, cost, latency, context-window, reliability, and benchmark freshness signals. User pinning, provider-family constraints, auth, quota exhaustion, safety, and availability still win. | It is advisory, not absolute. In v1 it stays within the request wire-format pool; it does not translate OpenAI Chat Completions traffic into Anthropic Messages traffic or vice versa. |

The routing cockpit in Settings -> Routing pools exposes the mode toggle and
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

## Two routing pools (wire-format boundary)

The gateway exposes two independent pools. **A request hitting one endpoint
can only be served by accounts in that pool — format families never cross.**
This is the "two highways" model: pass-through routing within a single
wire-format family, no cross-format translation.

| Pool | Endpoint | Format | Upstream providers that participate |
|---|---|---|---|
| **OpenAI-family** | `POST /v1/chat/completions` | OpenAI Chat Completions | OpenAI, Z.ai, MiniMax, Kimi, Ollama Cloud, Ollama Local |
| **Anthropic-family** | `POST /v1/messages` | Anthropic Messages | Anthropic Console (API key), Anthropic Pro/Team (OAuth bearer) |

A request to `/v1/chat/completions` with only Anthropic-family accounts
configured returns `503` with a structured error pointing the caller at the
right pool, and vice versa. Within a pool, the existing in-flight failover
loop applies — on `429` / `quota_exceeded` / `auth_failed` the gateway marks
the slot, parks it in a five-minute cool-down, and retries against the next
healthy candidate in the same pool.

## What routes today

- **OpenAI-family client targets:** Cursor (BYOK tunnel), Droid/Factory,
  Forge, OpenCode, Codex CLI in `OPENAI_BASE_URL` mode, any
  OpenAI-compatible IDE.
- **OpenAI-family upstream providers:** OpenAI, Z.ai, MiniMax, Kimi,
  Ollama Cloud, Ollama Local.
- **Anthropic-family client targets:** Claude Code via
  `ANTHROPIC_BASE_URL=http://127.0.0.1:8317` + `ANTHROPIC_AUTH_TOKEN=<gateway-token-or-openburnbar-local>`.
- **Anthropic-family upstream providers:** Anthropic Console (`sk-ant-…`
  routed via the `x-api-key` header), Anthropic Pro/Team (OAuth bearer via
  the `Authorization: Bearer` header).
- **Endpoint shape:** OpenAI-compatible `/v1/models`, `/v1/chat/completions`,
  plus Anthropic-compatible `/v1/messages`.
- **Usage attribution:** proxied local-client calls record as `OpenBurnBar Gateway`.

Droid/Factory, Forge, OpenCode and Codex are client targets, not new upstream
providers. Their requests still route through the same upstream accounts and
credential slots configured in OpenBurnBar.

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
- `testClaudeCodeAnthropicRequestFailsOverWhenPrimaryQuotaExhausted` —
  Claude Code-shaped `/v1/messages` request fails over from primary to backup.
- `testGatewayMessagesReturns503WhenOnlyOpenAICompatProvidersConfigured` —
  Anthropic request with no Anthropic accounts → structured 503.
- `testGatewayChatCompletionsReturns503WhenOnlyAnthropicProvidersConfigured` —
  OpenAI-shape request with no OpenAI-shape accounts → structured 503.

## Setup

1. Open OpenBurnBar on the Mac that will run the client.
2. Open Settings -> Routing pools and use **Use local defaults** if the
   gateway is not already on. This enables the loopback gateway at
   `127.0.0.1:8317`.
3. Add at least one provider account in the matching pool. Add a second
   account or key in that pool if you want failover to have somewhere to go.
4. In Settings -> Routing pools -> Client apps:
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
| Droid/Factory | `~/.factory/settings.local.json` | `customModels` entries with provider `generic-chat-completion-api`, `id = custom:OpenBurnBar-<model>-<index>`, and display names prefixed `OpenBurnBar` |
| Droid/Factory | `~/.factory/settings.json` | `customModels` entries with provider `generic-chat-completion-api`, `id = custom:OpenBurnBar-<model>-<index>`, and display names prefixed `OpenBurnBar` |
| Droid/Factory | `~/.factory/config.json` | `custom_models` entries with provider `generic-chat-completion-api` and display names prefixed `OpenBurnBar` |
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

`Settings → Routing pools` exposes a setup checklist and OpenBurnBar-owned client
rows for each pool. Two modes:

1. **Config-file mode (toggle)** — writes the env / TOML block listed above,
   then runs a 1-token probe (`POST /v1/messages` for Claude Code, `POST
   /v1/responses` for Codex, and `POST /v1/chat/completions` for Forge) to confirm the gateway actually
   serves the wired client before reporting success. Toggle off to remove the
   OpenBurnBar block.
2. **Shell-snippet mode (button)** — opens a copy/pasteable
   `export ANTHROPIC_BASE_URL=…` / `export OPENAI_BASE_URL=…` block for
   users on managed dotfiles or non-standard shells. No file writes.

Droid/Factory uses a sync button instead of a toggle because Factory consumes
custom model arrays, not a sentinel block. OpenBurnBar writes `provider:
`generic-chat-completion-api` custom models pointed at the local Hydrant
gateway, removes stale local VibeProxy entries on that gateway port, and then
uses the shared OpenAI-family probe to prove the pool responds.

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
