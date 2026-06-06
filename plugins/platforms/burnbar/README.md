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
  `plugins.platforms.burnbar.relay_e2ee`): once pairing enables E2E, the adapter uses the v2
  authenticated key-wrap, seals every outgoing reply body / attachment to the
  phone's pinned relay key, and opens phone-sealed inbound events only when the
  AES-GCM tag verifies against that pinned sender key. On an E2E-paired link it
  refuses plaintext. The BurnBar Cloud gateway receives ciphertext for sealed
  message/event/attachment bodies, sender names, file names, and approval details.
- **Safety-code comparison** after setup: when E2E is enabled, the CLI prints the
  same short code BurnBar shows in the Private messages sheet. The prompt defaults
  to **no** and only accepts valid X9.63 P-256 public keys. Matching codes confirm
  the two apps are displaying the same agent/phone relay keys for this pairing. If
  the user approves without comparing the code, there is no first-pairing MITM defense.
- **Runtime status** to `/runtime` (on connect and every 30s): the agent's model
  catalog, current model/provider, and agent version. The gateway exposes this on
  `/state`, which is how BurnBar clients show whether the gateway is online and
  what model it is running.
- **Remote model switch**: a `model_switch` event is applied as `/model <id>`,
  after which runtime status is republished so the new model is reflected in
  `/state` within ~1s instead of waiting for the next heartbeat.
- **Human-in-the-loop oversight**: on an E2E-paired link, oversight mode is pinned at
  pairing (`BURNBAR_OVERSIGHT_MODE`); the relay-visible `/state` toggle is **not**
  authoritative. When oversight is *supervised*, Hermes' slash-confirm prompts arm a
  BurnBar approval gate (`/approvals`, control-plane only) and deliver the readable
  detail over the sealed message channel. On E2E links the agent **does not** trust
  `/approvals` poll status (a malicious relay could forge `approved`); it applies
  decisions only from phone-authenticated sealed `approval_decision` events (the
  BurnBar app enqueues one after the native callable succeeds). Authenticated
  `oversight_mode` events are the E2E path for changing the mode after pairing.
  Legacy plaintext links still mirror oversight from `/state` and poll `/approvals`
  as before.
- **Replay defense**: authenticated event ids are deduped in memory and persisted to
  `burnbar_replay_ledger.json` (beside the event cursor), keyed by `uid`,
  `clientId`, and the pinned phone key fingerprint. Every E2E sealed inbound event
  must carry an authenticated `replayCounter`/`eventCounter`; the adapter persists a
  high-water mark and drops counters at or below it before dispatch, so an old valid
  frame is still dropped after restart or bounded-cache saturation.
- **AAD routing identity**: E2E setup requires the authenticated device grant to
  include both `uid` and `clientId`. The adapter refuses to enable or process E2E
  without them, because learning the first AAD-routing ids from `/events` or
  `/state` would let an untrusted relay pin wrong values and cause persistent
  decrypt failure.

## Configuration

`hermes gateway setup` writes these; they can also be set in the environment:

- `BURNBAR_API_BASE_URL` — gateway base URL (default
  `https://api.burnbar.ai/v1/hermes-gateway`).
- `BURNBAR_ACCESS_TOKEN` — bearer token minted when the device code is approved.
- `BURNBAR_HOME_CHANNEL` — default destination id (default `burnbar:home`).

Optional:

- `HERMES_BURNBAR_AGENT_VERSION` — overrides the reported agent version.
- `HERMES_BURNBAR_CURSOR_FILE` — overrides the profile-aware event-cursor path.
- `HERMES_BURNBAR_REPLAY_FILE` — overrides the profile-aware durable replay-ledger path.
- `BURNBAR_OVERSIGHT_MODE` — E2E-paired oversight mode (`supervised` by default).
- `BURNBAR_ALLOW_PLAINTEXT=1` — explicit opt-in to the legacy plaintext path when
  this agent already has a relay identity but the BurnBar link is not E2E-paired.

E2EE requires the optional relay crypto extra:

```bash
pip install -e '.[gateway-e2ee]'
```

Without that extra, legacy plaintext setup still works, but an already E2E-paired
link (`BURNBAR_RELAY_E2E=1`) refuses to start rather than downgrading.

## Setup

```bash
hermes gateway setup        # choose "BurnBar Cloud", approve the code in the app
hermes gateway restart
hermes gateway status
```

After approval, compare the printed safety code with BurnBar's **Private
messages** screen before sending sensitive prompts. If the codes do not match,
revoke the gateway in BurnBar and pair again from a trusted network.

## Security notes

See [`SECURITY.md`](SECURITY.md) for the maintainer-facing threat model and
merge checklist.

This is relay-content confidentiality, not Signal-grade metadata privacy. On an
E2E-paired link, the relay does not receive plaintext message text, sender names,
approval detail, attachment names, or file bytes, and cannot forge post-pairing
v2 events under the relay-only threat model, absent sender or recipient static-key
compromise. It still sees routing ids, event/message ids, timing, and approximate
ciphertext sizes.

The v2 key wrap is HPKE-AuthEncap-shaped (`ECDH(ephemeral, recipient) ||
ECDH(senderStatic, recipient)` with domain-separated HKDF info), but it is not
RFC 9180 HPKE framing. This keeps compatibility with the existing BurnBar mobile
relay wire format. This repo verifies the Python side with vendored known-answer
vectors; mobile-client parity is maintained outside this repo. A future
standard-HPKE migration should use a new `relayKeyVersion`; v2 stays byte-stable.

KCI and static-key compromise are explicit non-goals. If the recipient static
private key is stolen, past messages wrapped to that key can be decrypted and an
attacker can forge as any sender. The static leg has no post-compromise forward
secrecy; key protection belongs in the OS keychain and re-pairing/key rotation
policy. Replay rejection is enforced by the adapter's persisted id ledger plus
sealed replay-counter high-water mark, not by AES-GCM alone.

Safety-code check: compare the safety code during setup; clicking through
without checking it gives the relay a first-pairing MITM opportunity.

## Tests

From the Hermes repo root:

```bash
# Plugin registration, event mapping, send/typing/attachments, oversight,
# runtime status + model switch, and the relay seal -> open round-trip.
scripts/run_tests.sh \
  tests/gateway/test_burnbar_plugin.py \
  tests/gateway/test_burnbar_e2ee.py \
  tests/gateway/test_relay_e2ee.py \
  tests/gateway/test_relay_e2ee_v2.py
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
