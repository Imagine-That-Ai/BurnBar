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
  for models served by OpenAI-shaped upstream accounts and
  `generic-chat-completion-api` for other OpenAI-compatible chat models.

## Behavior

- `/v1/models` is derived from BurnBar's live provider/account configuration and only includes models that can route right now.
- For OpenAI-compatible providers that expose `/models`, BurnBar lists upstream-advertised models for eligible accounts and hides missing-credential, disabled, exhausted, and cooling-down rows.
- Each model row includes provider id, account id, account label, capabilities, quota state, enabled state, route eligibility, and last refresh fields.
- `/v1/chat/completions` and `/v1/responses` stop before contacting an upstream provider when the selected model has no eligible route.
- Same-provider account failover can happen only through eligible accounts that advertise the requested model.
- BurnBar does not silently substitute a stale default model.
- CLI wiring fails before editing a client when BurnBar has no route-eligible advertised models for that client family.

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

For iroh/Hermes E2E scripts, `--model auto` reads `http://127.0.0.1:8317/v1/models` and skips local/Ollama models by default. Use `--model <id>` to force a specific advertised model.
