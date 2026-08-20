# Local D box (Mac, Developer ID)

Settings → Agents → **Local D box** talks to this Mac’s Grok Bot D live box over loopback HTTP. It is not the Grok Build CLI, not xAI API quota, and not the official Grok Bot fleet.

Default **off**. Mac App Store builds do not show the pane (no `~/.grok` without bookmarks, no auto-start).

## What it does

1. Lists live agents from `POST http://127.0.0.1:1337/api/listAgents`.
2. Sends **one UUID** a prompt with `awaitTurn: false`.
3. Follows the turn by polling `listAgents` and, when the roster includes a `path` to that agent’s `store.db`, a **read-only** sqlite window:

   `SELECT entry FROM transcript_entries WHERE rowid > :watermark ORDER BY rowid DESC LIMIT n` with a short `busy_timeout` (well under the 1s poll). The watermark is `MAX(rowid)` taken immediately before `sendPrompt`. If that snapshot fails, sqlite follow is skipped and preview follow is used instead.

   Success is the newest user line whose content equals (or is a truncation of) this prompt **and** a strictly newer **assistant** / `send-message` line, using only rows after the send-time `MAX(rowid)` watermark. Non-JSON sqlite stdout (PRAGMA `80`) is ignored. `SQLITE_BUSY` skips that poll. A missing or locked db falls back to `lastMessagePreview` follow. Never INSERT / UPDATE / DELETE. An exact/truncated preview of the prompt is the user line; a different later preview (including an echo such as `"<token> pong"`) is a completed turn.

   The pane waits up to ~90 one-second polls (Probe Bot pongs have been measured at 42–52s; a 45s cap returned `promptLandedNoReply` while the assistant line was still in flight). If that window ends without a later reply, a background watch keeps polling until sqlite/preview shows this turn completed or the agent goes idle.

## Ports (always `127.0.0.1`, never `localhost`)

| Port | Process | If down |
|---|---|---|
| 1337 | gateway-shim | cannot list |
| 1338 | host-main | list may still 200 from disk; **send is refused** |
| 8787 | proxy2 inference | send refused (“inference proxy is down”) |

The shim must not return `{ok:true, scheduled:true}` when forwarding `sendPrompt` or `broadcastToAgents` fails because `:1338` is down. Those paths are an honest non-2xx (`{ok:false, error: "local box host is down"}`). Inbound `/api/*` requires `Authorization` matching the shim bearer. BurnBar still probes TCP first and refuses send unless health is `.ok`. Disk `listAgents` fallback may still 200 when the host is down.

## Auth

`Authorization: Bearer <SAND_HOST_GATEWAY_TOKEN>` from `~/.grok/grokbot-d/active-env.json`.

- Local profile with a blank token → error (do not silently guess).
- Cursor seat with a blank token → loopback shim bearer `fake-gateway-token` (what `profile-store.js` writes for the local box). The pane still talks to the box, not the Cursor GUI.

Tokens are redacted from `description` / `debugDescription`.

## Auto-start

Optional, default off. Unsandboxed only. Runs `~/.grok/grokbot-d/ensure-local-box.sh` at most once per process when both flags are on (app launch and later auto-start refreshes share that once-guard). Never launches `grokd-local`, D.app, or Seat4.

## Feature flags

UserDefaults keys, both default false:

- `localD.box.enabled`
- `localD.box.autoStart`

## Out of v1

Mobile, Iroh, `AgentProvider` / Hermes cases, SQLite writes, broadcast, `createAgent`, seat failover, Core HTTP (iOS loopback).
