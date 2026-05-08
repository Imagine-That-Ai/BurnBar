# Routed Client Gateway

OpenBurnBar exposes selected routed models through the local daemon's
OpenAI-compatible gateway so supported clients can share the same provider
rotation policy. The first practical targets are Cursor, Factory, and OpenCode.

## What Routes

- Client targets: Cursor, Factory, OpenCode.
- Upstream routed providers: Z.ai, MiniMax, and Ollama Cloud.
- Endpoint shape: OpenAI-compatible `/v1/models` and `/v1/chat/completions`.
- Usage attribution: proxied local-client calls record as `OpenBurnBar Gateway`.

Factory and OpenCode are client targets, not new upstream providers. Their
requests still route through the same Z.ai / MiniMax / Ollama Cloud provider
accounts and credential slots configured in OpenBurnBar.

## Setup

1. Open OpenBurnBar on the Mac that will run the client.
2. Confirm the daemon is installed and the gateway is enabled.
3. Add Z.ai, MiniMax, and/or Ollama Cloud provider keys in Settings.
4. Pick the exposed routed models in the Cursor connector settings.
5. In Settings -> Providers -> Quota Reporting -> Cursor:
   - use `Connect` for Cursor;
   - use `Sync Factory` for Factory;
   - use `Sync OpenCode` for OpenCode.

Cursor still needs the Cloudflare quick tunnel path because Cursor BYOK rejects
local/private network URLs. Factory and OpenCode use the local gateway URL
directly, usually `http://127.0.0.1:8317/v1`.

## Config Files Written

OpenBurnBar preserves unrelated client config and writes a timestamped backup
before replacing prior OpenBurnBar entries.

| Client | File | OpenBurnBar-owned keys |
|---|---|---|
| Factory | `~/.factory/settings.json` | `customModels` entries with provider `openburnbar` |
| Factory | `~/.factory/config.json` | `custom_models` entries with provider `openburnbar` |
| OpenCode | `~/.config/opencode/opencode.json` | `provider.openburnbar`; default `model` only when no model is set |

The client config receives the local gateway URL and gateway auth token. Raw
upstream provider API keys stay in OpenBurnBar's Keychain-backed provider store.

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
  gateway auth token in OpenBurnBar settings.
- Client cannot connect: confirm OpenBurnBar and `OpenBurnBarDaemon` are
  running on the same Mac and that the gateway host/port match the client config.
- Cursor works but Factory/OpenCode do not: Cursor may be going through the
  tunnel while local clients use the direct gateway URL; check the local
  `http://127.0.0.1:8317/v1/models` path.
- Ollama Cloud model returns a model-name error: verify the direct model list at
  `https://ollama.com/api/tags`; local `:cloud` and `-cloud` aliases are only
  gateway-facing conveniences.
