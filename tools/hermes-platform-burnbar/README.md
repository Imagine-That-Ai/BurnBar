# BurnBar Cloud platform plugin

Connects Hermes Agent to BurnBar Cloud's Hermes Gateway so a BurnBar user can
message the agent — and supervise it — from the BurnBar iOS/macOS apps.

## What it does

- **Device-code setup** against the BurnBar Hermes Gateway (`hermes gateway
  setup` → BurnBar Cloud, then approve the code in the BurnBar app).
- **Event polling** of `/events` with a durable on-disk cursor; delivers user
  messages to the agent.
- **Replies** via `/messages` and **typing** state via `/typing`.
- **Attachments** via `/attachments/init` + signed upload + `/attachments/finalize`.
- **Runtime status** to `/runtime` (on connect and every 30s): the agent's model
  catalog, current model/provider, and agent version. The gateway exposes this on
  `/state`, which is how BurnBar clients show whether the gateway is online and
  what model it is running.
- **Remote model switch**: a `model_switch` event is applied as `/model <id>`,
  after which runtime status is republished so the new model is reflected in
  `/state` within ~1s instead of waiting for the next heartbeat.
- **Human-in-the-loop oversight**: when oversight is *supervised* (set per client
  from the BurnBar app), Hermes' slash-confirm prompts are routed through a BurnBar
  approval gate (`/approvals`). The action waits until the user approves it on a
  trusted BurnBar device; an unanswered gate expires. In *autonomous* mode the
  agent runs without prompting. Decisions are applied through Hermes' own
  `tools.slash_confirm`, so this only gates actions Hermes already routes through
  the slash-confirm primitive.

## Configuration

`hermes gateway setup` writes these; they can also be set in the environment:

- `BURNBAR_API_BASE_URL` — gateway base URL (default
  `https://api.burnbar.ai/v1/hermes-gateway`).
- `BURNBAR_ACCESS_TOKEN` — bearer token minted when the device code is approved.
- `BURNBAR_HOME_CHANNEL` — default destination id (default `burnbar:home`).

Optional:

- `HERMES_BURNBAR_AGENT_VERSION` — overrides the reported agent version.
- `HERMES_BURNBAR_CURSOR_FILE` — overrides the event-cursor cache path.

## Setup

```bash
hermes gateway setup        # choose "BurnBar Cloud", approve the code in the app
hermes gateway restart
hermes gateway status
```

## Tests

From the Hermes repo root:

```bash
# Plugin registration, event mapping, send/typing/attachments.
scripts/run_tests.sh tests/gateway/test_burnbar_plugin.py

# Oversight + runtime-state + model-switch logic (no network, no live runtime).
plugins/platforms/burnbar/test_oversight_local.py     # run with the repo venv

# Deterministic smoke against a fake gateway (copies the plugin into a checkout).
python plugins/platforms/burnbar/smoke_local.py smoke --hermes-repo .
```

`test_oversight_local.py` finds the Hermes checkout via `HERMES_REPO` (defaults to
`~/.hermes/hermes-agent`); set it to the checkout you are testing.

## Manual full-gateway local test

Terminal 1 — fake gateway:

```bash
python plugins/platforms/burnbar/smoke_local.py serve --port 8765
```

Terminal 2 — Hermes against the fake gateway:

```bash
export BURNBAR_API_BASE_URL="http://127.0.0.1:8765/v1/hermes-gateway"
export BURNBAR_ACCESS_TOKEN="test-token"
export BURNBAR_HOME_CHANNEL="dest-home"
hermes gateway
```

Terminal 3 — enqueue a message and read the reply:

```bash
curl -s -X POST http://127.0.0.1:8765/__test/enqueue \
  -H 'Content-Type: application/json' \
  -d '{"text":"Reply with exactly: PONG"}'

curl -s http://127.0.0.1:8765/__test/messages | python3 -m json.tool
```
