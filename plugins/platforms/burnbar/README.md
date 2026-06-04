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
- **End-to-end relay encryption** (`p256-hkdf-sha256-aesgcm`, via
  `gateway.crypto.relay_e2ee`): once the paired phone publishes a relay public
  key, the adapter seals every outgoing reply body / attachment to the phone's key
  and opens phone-sealed inbound events with its own key; on an E2E-paired link it
  refuses to send plaintext. The BurnBar Cloud gateway is a blind relay — it never
  sees message/event/attachment bodies, sender names, or file names.
- **Safety-code comparison** after setup: when E2E is enabled, the CLI prints the
  same short code BurnBar shows in the Private messages sheet. Matching codes
  prove the phone pinned this agent key at first pairing.
- **Runtime status** to `/runtime` (on connect and every 30s): the agent's model
  catalog, current model/provider, and agent version. The gateway exposes this on
  `/state`, which is how BurnBar clients show whether the gateway is online and
  what model it is running.
- **Remote model switch**: a `model_switch` event is applied as `/model <id>`,
  after which runtime status is republished so the new model is reflected in
  `/state` within ~1s instead of waiting for the next heartbeat.
- **Human-in-the-loop oversight**: when oversight is *supervised* (set per client
  from the BurnBar app), Hermes' slash-confirm prompts are routed through a BurnBar
  approval gate (`/approvals`). The gate is **control-plane only** — it carries the
  action id and a coarse tool category, never the agent's free-text command; the
  human-readable detail is delivered over the end-to-end encrypted message channel,
  so the server never reads it. The action waits until the user approves it on a
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

After approval, compare the printed safety code with BurnBar's **Private
messages** screen before sending sensitive prompts. If the codes do not match,
revoke the gateway in BurnBar and pair again from a trusted network.

## Tests

From the Hermes repo root:

```bash
# Plugin registration, event mapping, send/typing/attachments, oversight,
# runtime status + model switch, and the relay seal -> open round-trip.
scripts/run_tests.sh tests/gateway/test_burnbar_plugin.py tests/gateway/test_relay_e2ee.py tests/gateway/test_relay_e2ee_v2.py

# Deterministic smoke against a fake gateway (copies the plugin into a checkout).
python plugins/platforms/burnbar/smoke_local.py smoke --hermes-repo .
```

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
