# BurnBar Cloud Hermes Platform Plugin

This directory is the upstream contribution package for Hermes Agent.

Target path in the official Hermes repo:

```text
plugins/platforms/burnbar/
```

The plugin implements BurnBar Cloud as a Hermes messaging platform:

- device-code setup against BurnBar's Hermes Gateway API
- end-to-end encrypted message bodies and attachments (see below)
- human-in-the-loop oversight (supervised / autonomous gating of slash-confirms)
- runtime status / model-catalog publication for the BurnBar model picker
- event polling with durable cursor persistence
- Hermes replies through `/messages`
- typing state through `/typing`
- native attachment delivery through `/attachments/init`
- standalone cron delivery with `deliver=burnbar`

## End-to-end encryption

Messages and files exchanged with the agent are end-to-end encrypted
(ECDH P-256 → HKDF-SHA256 → AES-256-GCM, algorithm `p256-hkdf-sha256-aesgcm`).
BurnBar Cloud stores only ciphertext and a wrapped key it cannot open; only your
paired phone and this agent hold the keys.

- At pairing (`hermes gateway setup`) the agent generates a relay keypair and
  publishes its **public** key in the `device/start` payload
  (`agentRelayPublicKey` / `relayKeyVersion` / `relayEncryption`). The **private**
  key is persisted to `~/.hermes/.env` as `BURNBAR_RELAY_PRIVATE_KEY` and never
  leaves the machine.
- Outgoing replies are sealed to the phone's relay public key — the adapter sends
  a `relayEnvelope` (`payloadCiphertext` + `wrappedKey`) and **omits** the
  plaintext `text`. Attachments seal both the bytes and the filename/manifest the
  same way; the storage object holds only ciphertext.
- Inbound events are sealed to the agent's relay public key; the adapter unwraps
  them with its private key before handing the plaintext to Hermes.
- Once a link is E2E-paired (`BURNBAR_RELAY_E2E=1`) the adapter **refuses** to
  send or accept plaintext. A legacy (pre-E2E) peer produces a clear
  `SendResult(success=False, error="… upgrade BurnBar to exchange messages")`,
  and unsealed inbound events are dropped rather than leaked.
- A legacy BurnBar server that does not negotiate E2E keeps the plaintext relay
  path so older clients still pair during rollout.

All AES/ECDH/HKDF lives in `gateway/crypto/relay_e2ee.py` (the byte-exact Python
mirror of the Swift `HermesRelayCrypto`); the adapter never invents crypto. Any
platform adopting the relay can reuse the same five lines:

```python
import os, json
from gateway.crypto import relay_e2ee

identity = relay_e2ee.AgentRelayIdentity.load_or_create()   # publish identity.public_key_base64
sym = relay_e2ee.generate_symmetric_key()
payload_ciphertext = relay_e2ee.seal_to_base64(json.dumps({"text": text}).encode(), sym, message_aad)
wrapped_key = relay_e2ee.wrap_symmetric_key(sym, peer_public_key_b64, message_aad)
```

The gateway AAD parts are `["gatewayEvent", uid, clientId, eventId]`,
`["gatewayMessage", uid, clientId, messageId]`,
`["gatewayAttachmentBody"|"gatewayAttachmentKey", uid, clientId, attachmentId]`,
each namespaced `"OpenBurnBar-HermesRelay-v1|" + "|".join(parts)`.

### Relay environment variables

| Variable | Managed by | Purpose |
| --- | --- | --- |
| `BURNBAR_RELAY_PRIVATE_KEY` | auto (setup) | the agent's persisted relay private key |
| `BURNBAR_RELAY_E2E` | auto (setup) | `1` once the link negotiated E2E |
| `BURNBAR_RELAY_PEER_PUBLIC_KEY` | auto (setup) | the paired phone's relay public key |
| `BURNBAR_RELAY_UID` / `BURNBAR_RELAY_CLIENT_ID` | auto (setup) | AAD identity binding |

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
- `/events` mapping to `MessageEvent` (plaintext + sealed) and `model_switch`
- `/messages` send happy path + error → `SendResult(success=False)`
- `/attachments/init` + signed upload (plaintext + sealed)
- cursor round-trip
- oversight (`/state`) refresh + autonomous auto-approve, runtime-status payload
- **E2E:** agent-seal → phone-open round-trips for messages, events, and
  attachments; refuse-plaintext-when-paired; locked-wire AAD bytes

The relay crypto interop gate (Swift⇄Python wire vector) lives in
`tests/gateway/test_relay_e2ee.py`.

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
