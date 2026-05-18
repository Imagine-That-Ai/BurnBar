# BurnBar as a VibeProxy Replacement

BurnBar exposes an OpenAI-compatible local gateway from the Mac daemon. Point clients at:

```text
http://127.0.0.1:8317/v1
```

## Setup

1. Open BurnBar on the Mac.
2. Go to Settings -> Connections.
3. Add or enable the provider accounts you want BurnBar to route through.
4. Confirm `/v1/models` advertises route-eligible models only:

```bash
curl -fsS http://127.0.0.1:8317/v1/models | jq '.data[] | {id, provider_id, account_id, quota_state, route_eligible}'
```

5. Configure external OpenAI-compatible clients with:

```text
Base URL: http://127.0.0.1:8317/v1
API key: any non-empty value unless you enabled a gateway auth token
Model: one of the live model ids from /v1/models
```

For supported local CLIs, use Settings -> Agents -> CLIs and press Connect.
BurnBar reads its own live `/v1/models` catalog and writes route-eligible
models into the client config automatically:

- Codex CLI: OpenBurnBar provider/profile in `~/.codex/config.toml`.
- OpenCode CLI: `provider.openburnbar` plus live model entries in `~/.config/opencode/opencode.json`.
- Forge CLI: OpenBurnBar provider with `models = http://127.0.0.1:8317/v1/models` in `~/forge/.forge.toml`.
- Droid / Factory CLI: press `Connect + Sync` the first time, then `Sync models`
  any time accounts/models change. BurnBar rewrites `customModels` /
  `custom_models` entries for the live advertised catalog in
  `~/.factory/settings.local.json`, `~/.factory/settings.json`, and
  `~/.factory/config.json`, using Factory's `openai` custom model provider
  for models served by OpenAI-owned upstream accounts, `anthropic` for
  Claude/Anthropic-family models bridged through BurnBar, and
  `generic-chat-completion-api` for the rest of the gateway-served chat
  catalog.

## Behavior

- `/v1/models` is derived from BurnBar's live provider/account configuration and only includes models that can route right now.
- For OpenAI-compatible providers that expose `/models`, BurnBar lists upstream-advertised models for eligible accounts and hides missing-credential, disabled, exhausted, and cooling-down rows.
- For Ollama Cloud, BurnBar reads the native `https://ollama.com/api/tags` catalog with the saved Ollama API key, advertises every route-eligible cloud model it returns, and proxies chat through `https://ollama.com/api/chat`.
- Anthropic/Claude models appear in `/v1/models` when an enabled Anthropic route exists. Their model rows include `format_family = anthropic` and `served_endpoints` so clients can tell whether BurnBar can serve `/v1/messages`, `/v1/chat/completions`, and `/v1/responses` for that model.
- If a real request proves that a specific provider/account/model route cannot serve the model, BurnBar records that model health failure and stops advertising that exact row until the block expires. This prevents external CLIs from repeatedly choosing a model that the gateway just proved is unavailable, without hiding healthy sibling models on the same account.
- Each model row includes provider id, account id, account label, capabilities, quota state, enabled state, route eligibility, and last refresh fields.
- `/v1/chat/completions` and `/v1/responses` stop before contacting an upstream provider when the selected model has no eligible route.
- `/v1/responses` first uses an upstream Responses endpoint when the provider has one. If an advertised OpenAI-compatible provider only exposes chat completions, BurnBar translates the request through `/v1/chat/completions` and returns a Responses-shaped JSON or SSE stream so Codex-style clients still work.
- For advertised Anthropic models, `/v1/chat/completions` and `/v1/responses` translate local OpenAI-style requests to Anthropic Messages and translate the response back. Basic function tool requests and Anthropic `tool_use` blocks are bridged to OpenAI-style tool calls.
- Factory Droid is both a client target and a routed upstream provider. As an
  upstream, BurnBar runs the official `droid exec` CLI in read-only
  non-interactive mode and labels rows as Factory-served. Standard Usage
  exhaustion is a same-model failover event; BurnBar does not accept Factory's
  native Standard-to-Droid-Core downgrade for requests that asked for a
  Standard model. See `docs/FACTORY_DROID_ROUTING.md`.
- Same-provider account failover can happen only through eligible accounts that advertise the requested model.
- BurnBar does not silently substitute a stale default model.
- CLI wiring fails before editing a client when BurnBar has no route-eligible advertised models for that client's local gateway endpoint.

## Troubleshooting

If a request fails with:

```text
No eligible route for <model>. Add or enable an account/provider that serves this model.
```

Check:

- The provider is enabled in Settings -> Connections.
- The account or plan row is enabled.
- The account has a credential.
- `/v1/models` includes the model.
- The quota state is not `exhausted`, `cooling_down`, `auth_failed`, `disabled`, or `missing_credential`.
- For Ollama Cloud, browser sign-in only proves account/quota visibility. Add an Ollama Cloud API key in Accounts/Connections before expecting the model to appear as route-ready.

If an Anthropic OAuth account returns an opaque `HTTP 429` for a Claude model
while Claude Code itself still works, BurnBar will report the exact
account/model route and temporarily remove that model row from `/v1/models`.
Use another advertised Claude model, add an Anthropic Console API key, or retry
after the health block expires.

## Claude Max subscription (Opus + Sonnet + Haiku via OAuth)

Anthropic's public `/v1/messages` API treats Console API keys
(`sk-ant-api…`) and Claude Code OAuth tokens (`sk-ant-oat…`) as two
distinct routes. The behavior matters because **Opus is gated on the
OAuth route behind a Claude Code identity check**:

| Model | Console API key (`sk-ant-api*`) | Claude Code OAuth bearer (`sk-ant-oat*`) |
|---|---|---|
| Haiku (4.5) | works | works |
| Sonnet (4.6) | works | works |
| Opus (4.7) | works **if** your Console org is entitled to Opus | works **only** when the caller presents the Claude Code identity (BurnBar handles this automatically) |

BurnBar detects the credential prefix per route and:

- On `sk-ant-oat*` (Claude Max subscription): forwards to
  `https://api.anthropic.com/v1/messages?beta=true` with
  `anthropic-beta: claude-code-20250219,oauth-2025-04-20,…`, the standard
  Claude Code CLI identity headers, and a `system` field that starts with
  the canonical Claude Code guard string. Caller-supplied `system` text is
  preserved — the guard is prepended, not substituted. This is the same
  identity the Claude Code CLI itself presents on the same machine.
- On `sk-ant-api*` (Console key): forwards to `https://api.anthropic.com/v1/messages`
  with `x-api-key` and **without** the Claude Code identity. We never lie
  about the request's origin — Console traffic stays Console traffic.

If you have both kinds of credentials configured, BurnBar advertises Opus
through both routes in `/v1/models`. The router picks the highest-scoring
healthy slot per request; failover stays inside the requested capability
class (no silent downgrade to Sonnet or Haiku when Opus was selected).

If the **only** Anthropic credential is a Console API key without Opus
entitlement, a request for `claude-opus-4-7` will surface the Anthropic
upstream error directly and remove Opus from `/v1/models` for the cooldown
window. Add a Claude Max subscription (`claude auth login --claudeai` and
let BurnBar discover the `sk-ant-oat…` token via the Anthropic
credential probe) to actually serve Opus locally.

The Claude Code identity is applied per request inside the executor and is
covered by:

- `testGatewayPresentsClaudeCodeIdentityOnOAuthOpusRoute`
- `testGatewayDoesNotPresentClaudeCodeIdentityOnConsoleAPIKeyRoute`
- `testGatewayPreservesCallerSystemPromptWhenInjectingClaudeCodeGuard`
- `testGatewayDoesNotDowngradeOpusToHaikuOnOAuthFailure`

For iroh/Hermes E2E scripts, `--model auto` reads `http://127.0.0.1:8317/v1/models` and skips local-only Ollama/LM Studio runtimes by default. Route-ready Ollama Cloud rows are allowed because they run through the cloud gateway, not local RAM. Use `--model <id>` to force a specific advertised model.
