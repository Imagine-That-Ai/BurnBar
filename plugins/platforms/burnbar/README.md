# BurnBar Cloud platform plugin

This plugin adds BurnBar Cloud as a Hermes messaging platform. It is a
gateway adapter only: messages, attachments, approvals, and runtime state flow
through the BurnBar Hermes Gateway API; this first platform-plugin layer does
not add end-to-end encryption.

- device-code setup against BurnBar's Hermes Gateway API
- human-in-the-loop oversight (supervised / autonomous gating of slash-confirms)
- runtime status / model-catalog publication for the BurnBar model picker
- event polling with durable cursor persistence
- Hermes replies through `/messages`
- typing state through `/typing`
- native attachment delivery through `/attachments/init`
- standalone cron delivery with `deliver=burnbar`

## Configuration

`hermes gateway setup` writes these values after the device-code flow:

- `BURNBAR_API_BASE_URL` - gateway base URL.
- `BURNBAR_ACCESS_TOKEN` - scoped bearer token from the approved device grant.
- `BURNBAR_HOME_CHANNEL` - default BurnBar destination for cron and notification delivery.
- `BURNBAR_ALLOW_ALL_USERS` / `BURNBAR_ALLOWED_USERS` - sender allowlist controls.

## Setup

```bash
hermes gateway setup
hermes gateway restart
hermes gateway status
```

Choose `BurnBar Cloud`, approve the displayed device code in BurnBar, then
restart the gateway and send a message from BurnBar. To point the adapter at a
non-default gateway, set `BURNBAR_API_BASE_URL` before running setup.

## Tests

The plugin ships a deterministic, dependency-light test suite that loads the
adapter via `tests/gateway/_plugin_adapter_loader.load_plugin_adapter("burnbar")`
(no `sys.path` tricks — the `tests/gateway/conftest.py` guard enforces this):

```bash
python -m pytest tests/gateway/test_burnbar_plugin.py -q
```

It exercises:

- plugin registration + `Platform("burnbar")` dynamic resolution
- config / env-enablement / yaml-precedence
- `/events` mapping to `MessageEvent` and `model_switch`
- `/messages` send happy path + error → `SendResult(success=False)`
- `/attachments/init` + signed upload
- cursor round-trip
- oversight (`/state`) refresh + autonomous auto-approve, runtime-status payload

## Optional local smoke test

If you have a local fake BurnBar gateway, point a Hermes checkout at it:

```bash
cd /path/to/local/hermes-agent

export BURNBAR_API_BASE_URL="http://127.0.0.1:8765/v1/hermes-gateway"
export BURNBAR_ACCESS_TOKEN="test-token"
export BURNBAR_HOME_CHANNEL="dest-home"
export BURNBAR_ALLOW_ALL_USERS="true"

./hermes gateway
```

In another terminal:

```bash
curl -s -X POST http://127.0.0.1:8765/__test/enqueue \
  -H 'Content-Type: application/json' \
  -d '{"text":"Reply with exactly: PONG"}'

curl -s http://127.0.0.1:8765/__test/messages | python3 -m json.tool
```

If the local Hermes checkout has a model provider configured, the fake gateway
will receive the Hermes reply under `/__test/messages`.
