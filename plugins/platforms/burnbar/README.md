# BurnBar Cloud Hermes Platform Plugin

This directory is the upstream contribution package for Hermes Agent.

Target path in the official Hermes repo:

```text
plugins/platforms/burnbar/
```

The plugin implements BurnBar Cloud as a Hermes messaging platform:

- device-code setup against BurnBar's Hermes Gateway API
- event polling with durable cursor persistence
- Hermes replies through `/messages`
- typing state through `/typing`
- native attachment delivery through `/attachments/init`
- standalone cron delivery with `deliver=burnbar`

## Deterministic Local Smoke

```bash
python tools/hermes-platform-burnbar/smoke_local.py smoke \
  --hermes-repo /path/to/local/hermes-agent
```

This copies the plugin into the local Hermes checkout and exercises:

- plugin registration
- `/destinations` connection check
- `/events` mapping to `MessageEvent`
- `/messages` send
- `/typing`
- `/attachments/init` plus signed upload
- standalone cron-style send
- Hermes `send_message` MEDIA routing for BurnBar

## Manual Full-Gateway Local Test

Terminal 1:

```bash
python tools/hermes-platform-burnbar/smoke_local.py serve --port 8765
```

Terminal 2:

```bash
cd /path/to/local/hermes-agent
cp -R /path/to/BurnBar/tools/hermes-platform-burnbar plugins/platforms/burnbar

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
