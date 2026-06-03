# BurnBar Cloud Hermes Platform Plugin

This directory is the upstream contribution package for Hermes Agent.

Target path in the official Hermes repo:

```text
plugins/platforms/burnbar/
```

The plugin implements BurnBar Cloud as a Hermes messaging platform:

- device-code setup against BurnBar's Hermes Gateway API
- human-in-the-loop oversight (supervised / autonomous gating of slash-confirms)
- runtime status / model-catalog publication for the BurnBar model picker
- event polling with durable cursor persistence
- Hermes replies through `/messages`
- typing state through `/typing`
- native attachment delivery through `/attachments/init`
- standalone cron delivery with `deliver=burnbar`

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

## Manual Full-Gateway Local Test

Run a fake gateway and point a local Hermes checkout at it. (The fake-gateway
harness `smoke_local.py` lives in the BurnBar repo under
`tools/hermes-platform-burnbar/`.)

```bash
cd /path/to/local/hermes-agent

export BURNBAR_API_BASE_URL="http://127.0.0.1:8765/v1/hermes-gateway"
export BURNBAR_ACCESS_TOKEN="test-token"
export BURNBAR_HOME_CHANNEL="dest-home"
export BURNBAR_ALLOW_ALL_USERS="true"

./hermes gateway
```

Terminal 3:

```bash
curl -s -X POST http://127.0.0.1:8765/__test/enqueue \
  -H 'Content-Type: application/json' \
  -d '{"text":"Reply with exactly: PONG"}'

curl -s http://127.0.0.1:8765/__test/messages | python3 -m json.tool
```

If the local Hermes checkout has a model provider configured, the fake gateway
will receive the Hermes reply under `/__test/messages`.

## Real BurnBar Cloud Setup

Once the BurnBar Hermes Gateway API is deployed:

```bash
cd /path/to/local/hermes-agent
cp -R /path/to/BurnBar/tools/hermes-platform-burnbar plugins/platforms/burnbar

./hermes gateway setup
```

Choose **BurnBar Cloud**, approve the displayed device code from BurnBar, then
restart the gateway and send a message from BurnBar.
