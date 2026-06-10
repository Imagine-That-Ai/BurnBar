# BurnBar Cloud Hermes Gateway Platform

BurnBar Cloud can act as a Hermes messaging platform. A Hermes gateway process
connects with a short device-code flow, then sends and receives messages through
BurnBar the same way it would through Telegram, Signal, Slack, or LINE.

## User Flow

1. In Hermes, run `hermes gateway setup` and choose **BurnBar Cloud**.
2. Hermes calls `POST /v1/hermes-gateway/device/start`.
3. The user opens `/hermes/connect?code=...`, signs in with Google or Apple,
   and approves the code.
4. Hermes polls `POST /v1/hermes-gateway/device/poll` until it receives a
   scoped bearer token.
5. Hermes reads BurnBar messages from `/events` and posts responses to
   `/messages`.
6. Hermes publishes its current model and gateway-visible model catalog to
   `/runtime`, so OpenBurnBar can switch models even when the phone is not on
   the same LAN as the Mac.

## Where the Pairing Code Comes From

The pairing code is printed by Hermes, not generated manually in BurnBar:

1. On the computer where Hermes is installed, run `hermes gateway setup`.
2. Choose **BurnBar Cloud** in the Hermes setup prompt.
3. When Hermes asks for `BurnBar Hermes Gateway API base URL`, press **Return**
   to accept the default `https://api.burnbar.ai/v1/hermes-gateway` unless you
   are intentionally testing staging or an emulator.
4. Hermes calls the BurnBar Gateway API, prints an 8-character `userCode`
   such as `AB12-CD34`, prints the matching approval URL, and waits.
5. Open OpenBurnBar on iPhone, go to **Hermes -> BurnBar Cloud Gateway**,
   paste that code, and tap **Connect Hermes**.
6. Return to the Hermes computer and run `hermes gateway run` to keep a
   foreground gateway online. If the background service is installed, use
   `hermes gateway start` or `hermes gateway restart`. This restart matters:
   a service that was already running before setup will not see the new
   BurnBar token until it is restarted.
7. Back on iPhone, the connected client should move from **Paired** to
   **Ready/Online** once Hermes touches the API.

For this pre-upstream local checkout, run the same setup command from the
Hermes source tree with `./hermes gateway setup`; after approval, run
`./hermes gateway run`, or `./hermes gateway start`/`restart` if the local
service is installed.

The token is shown once, stored by Hermes, hashed server-side, and revocable
from BurnBar. The root token index stores only the token hash, UID, and client
ID so message endpoints can authenticate without scanning user collections.

OpenBurnBar desktop is not required for the hosted gateway to work. Delivery
requires at least one paired gateway client to be online: official Hermes,
OpenBurnBar, or another compatible BurnBar Gateway client. BurnBar Cloud stores
queued events durably. When multiple gateway clients are paired, OpenBurnBar
iPhone/iPad keeps a selected target client and writes `targetClientId` on queued
events. `/events` still delivers older broadcast events to every active client,
but targeted events are returned only to the selected client, so a Mac mini and
MacBook Pro can both stay connected without consuming each other's messages.

Gateway model switching uses the same queue as normal messages. OpenBurnBar
creates an `enqueueHermesGatewayEvent` event with `eventKind: "model_switch"`
and `modelId` for the selected `targetClientId`; Hermes consumes it as
`/model <modelId>`, applies the switch, and replies through `/messages`. If the
selected gateway has published
`runtimeModelOptions`, the iPhone shows those models in the picker. If not, the
user can still enter an exact Hermes model ID.

The mobile settings UI intentionally separates these states:

- **Paired**: BurnBar has issued a scoped token for a gateway client.
- **Online**: the client has touched the API recently enough to refresh
  `lastSeenAt`.
- **Queued**: BurnBar accepted an event, but no matching reply has arrived yet.
- **Replied**: a message with the matching `replyToEventId` or gateway thread
  was written to `hermes_gateway_messages`; the phone shows both an in-app
  banner and a local reply notification.

## Public HTTP API

Base path: `https://api.burnbar.ai/v1/hermes-gateway`

| Endpoint                 | Auth                          | Purpose                                             |
| ------------------------ | ----------------------------- | --------------------------------------------------- |
| `POST /device/start`     | Public                        | Start a device-code link session                    |
| `POST /device/poll`      | Device secret                 | Poll for approval and receive the bearer token once |
| `GET /destinations`      | Bearer `hermes.gateway.read`  | List BurnBar destinations                           |
| `GET /events?cursor=0`   | Bearer `hermes.gateway.read`  | Read inbound BurnBar events as JSON or one-shot SSE |
| `POST /messages`         | Bearer `hermes.gateway.write` | Deliver a Hermes reply into BurnBar                 |
| `POST /typing`           | Bearer `hermes.gateway.write` | Publish transient typing state                      |
| `POST /runtime`          | Bearer `hermes.gateway.write` | Publish current model and selectable model catalog  |
| `POST /attachments/init` | Bearer `hermes.gateway.write` | Mint a signed upload URL for file/image delivery    |

## BurnBar Callables

| Callable                          | Purpose                                                      |
| --------------------------------- | ------------------------------------------------------------ |
| `approveHermesGatewayDeviceGrant` | Approve a pending device-code session after Firebase sign-in |
| `listHermesGatewayClients`        | Show connected Hermes gateway clients                        |
| `revokeHermesGatewayClient`       | Revoke a client and delete its token-index entry             |
| `enqueueHermesGatewayEvent`       | Queue a BurnBar-originated message or model switch for Hermes |

## Firestore Ownership

Server-owned collections:

- `users/{uid}/hermes_gateway_clients`
- `users/{uid}/hermes_gateway_events`
- `users/{uid}/hermes_gateway_messages`
- `users/{uid}/hermes_gateway_typing`
- `users/{uid}/hermes_gateway_attachments`
- `users/{uid}/hermes_gateway_state`
- root `hermes_gateway_device_sessions`
- root `hermes_gateway_token_index`

Client-readable, server-written collection:

- `users/{uid}/hermes_gateway_destinations` — owner can **read**; **writes are
  server-only** (`allow write: if false` in `firestore.rules`). Destinations are
  created/maintained by Cloud Functions (`ensureDefaultDestination`), not by
  direct client writes. (Earlier docs described this as a user-writable
  non-secret-metadata collection; the rules are stricter than that and this was
  corrected to match.)

## Upstream Hermes Plugin

The contribution-ready plugin lives in
[`tools/hermes-platform-burnbar/`](../tools/hermes-platform-burnbar/). Copy it
to `plugins/platforms/burnbar/` in the official Hermes repo for the upstream PR.
The local upstream checkout used for validation is
`~/.hermes/hermes-agent` (`origin`:
`https://github.com/NousResearch/hermes-agent.git`). Do not push from this
checkout until the branch is owned by `Ajnunezg`/their fork remote.

Required env vars for Hermes:

- `BURNBAR_ACCESS_TOKEN`

Optional env vars:

- `BURNBAR_API_BASE_URL` defaults to `https://api.burnbar.ai/v1/hermes-gateway`
- `BURNBAR_HOME_CHANNEL` defaults to `burnbar:home`
- `BURNBAR_HOME_CHANNEL_NAME`
- `BURNBAR_ALLOWED_USERS`
- `BURNBAR_ALLOW_ALL_USERS`

## Verification

Run:

```bash
npm run test:hermes-gateway --prefix functions
```

Hermes-side deterministic smoke:

```bash
python tools/hermes-platform-burnbar/smoke_local.py smoke \
  --hermes-repo /path/to/local/hermes-agent
```

Official Hermes repo focused checks after copying to `plugins/platforms/burnbar/`:

```bash
uv run --extra dev pytest \
  tests/gateway/test_burnbar_plugin.py \
  tests/tools/test_send_message_tool.py::TestSendViaAdapterStandaloneFallback -q
uv run --extra dev ruff check \
  plugins/platforms/burnbar \
  tests/gateway/test_burnbar_plugin.py \
  tools/send_message_tool.py \
  tests/tools/test_send_message_tool.py
```

Manual full-gateway smoke with a fake local BurnBar Gateway:

```bash
python tools/hermes-platform-burnbar/smoke_local.py serve --port 8765
```

Then run the local Hermes checkout with:

```bash
export BURNBAR_API_BASE_URL="http://127.0.0.1:8765/v1/hermes-gateway"
export BURNBAR_ACCESS_TOKEN="test-token"
export BURNBAR_HOME_CHANNEL="dest-home"
export BURNBAR_ALLOW_ALL_USERS="true"
./hermes gateway
```

For a live staging smoke:

1. Start the BurnBar Functions emulator or deploy to staging.
2. Configure the Hermes plugin with `BURNBAR_API_BASE_URL` pointed at that host.
3. Run the device-code setup and approve from a signed-in BurnBar account.
4. Call `enqueueHermesGatewayEvent` and confirm Hermes consumes it from
   `/events`.
5. Send a Hermes reply and confirm the message appears under
   `hermes_gateway_messages`.
