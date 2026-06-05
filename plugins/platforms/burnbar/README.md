# BurnBar Cloud platform plugin

Connects Hermes Agent to BurnBar Cloud's Hermes Gateway so a BurnBar user can
message the agent and supervise it from the BurnBar iOS/macOS apps.

## What it does

- **Device-code setup** against the BurnBar Hermes Gateway (`hermes gateway
  setup` → BurnBar Cloud, then approve the code in the BurnBar app).
- **Event polling** of `/events` with a durable on-disk cursor; delivers user
  messages to the agent.
- **Replies** via `/messages` and **typing** state via `/typing`.
- **Attachments** via `/attachments/init` + signed upload + `/attachments/finalize`.
- **End-to-end relay encryption** (`p256-hkdf-sha256-aesgcm`, via
  `gateway.crypto.relay_e2ee`): once pairing enables E2E, the adapter uses the v2
  authenticated key-wrap, seals every outgoing reply body / attachment to the
  phone's pinned relay key, and opens phone-sealed inbound events only when the
  AES-GCM tag verifies against that pinned sender key. On an E2E-paired link it
  refuses plaintext. For E2E-paired links, message/event/attachment bodies,
  sender names, file names, and approval details are ciphertext to the relay;
  routing ids, timing, and approximate ciphertext sizes remain visible.
- **Safety-code comparison** after setup: when E2E is enabled, the CLI prints the
  same short code BurnBar shows in the Private messages sheet. The prompt defaults
  to **no** and only accepts valid X9.63 P-256 public keys. Matching codes prove
  the phone pinned this agent key at first pairing. If the user approves without
  comparing the code, there is no first-pairing MITM defense.
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
- `HERMES_BURNBAR_CURSOR_FILE` — overrides the event-cursor cache path.
- `HERMES_BURNBAR_REPLAY_FILE` — overrides the durable replay-ledger path.

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

This is a relay-only E2E design, not Signal-grade metadata privacy. The relay
cannot read sealed message text, sender names, approval detail, attachment
names, or file bytes, and cannot forge post-pairing v2 events without the
sender's static private key. It still sees routing ids, event/message ids,
timing, and approximate ciphertext sizes.

The v2 key wrap is HPKE-AuthEncap-shaped (`ECDH(ephemeral, recipient) ||
ECDH(senderStatic, recipient)` with domain-separated HKDF info), but it is not
RFC 9180 HPKE framing. The reason is cross-language wire compatibility with the
existing Swift/Kotlin `HermesRelayCrypto` vectors. A future standard-HPKE
migration should use a new `relayKeyVersion`; v2 must remain byte-stable.

KCI and static-key compromise are explicit non-goals. If the recipient static
private key is stolen, past messages wrapped to that key can be decrypted and an
attacker can forge as any sender. The static leg has no post-compromise forward
secrecy; key protection belongs in the OS keychain and re-pairing/key rotation
policy. Replay rejection is enforced by the adapter's persisted id ledger plus
sealed replay-counter high-water mark, not by AES-GCM alone.

Maintainer note: compare the safety code during setup; clicking through without
checking it gives the relay a first-pairing MITM opportunity.

## Tests

From the Hermes repo root:

```bash
# Plugin registration, event mapping, send/typing/attachments, oversight,
# runtime status + model switch, and the relay seal -> open round-trip.
scripts/run_tests.sh tests/gateway/test_burnbar_plugin.py tests/gateway/test_relay_e2ee.py tests/gateway/test_relay_e2ee_v2.py
```
