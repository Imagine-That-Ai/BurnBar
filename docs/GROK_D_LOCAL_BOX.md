# Local D box (Mac, Developer ID)

Settings → Agents → **Local D box** talks to this Mac’s Grok Bot D live box over loopback HTTP. It is not the Grok Build CLI, not xAI API quota, and not the official Grok Bot fleet.

Default **off**. Mac App Store builds do not show the pane (no `~/.grok` without bookmarks, no auto-start).

## What it does

1. Lists live agents from `POST http://127.0.0.1:1337/api/listAgents`.
2. Sends **one UUID** a prompt with `awaitTurn: false`.
3. Polls `listAgents` until that agent’s `lastMessagePreview` moves past the prompt. An exact/truncated prompt is the user line; a different later preview (including an echo such as `"<token> pong"`) is a completed turn. Never writes `store.db`.

## Ports (always `127.0.0.1`, never `localhost`)

| Port | Process | If down |
|---|---|---|
| 1337 | gateway-shim | cannot list |
| 1338 | host-main | list may still 200 from disk; **send is refused** |
| 8787 | proxy2 inference | send refused (“inference proxy is down”) |

The shim can return `{ok:true, scheduled:true}` while `:1338` is dead. BurnBar ignores that and probes TCP first.

## Auth

`Authorization: Bearer <SAND_HOST_GATEWAY_TOKEN>` from `~/.grok/grokbot-d/active-env.json`.

- Local profile with a blank token → error (do not silently guess).
- Cursor seat with a blank token → loopback shim bearer `fake-gateway-token` (what `profile-store.js` writes for the local box). The pane still talks to the box, not the Cursor GUI.

Tokens are redacted from `description` / `debugDescription`.

## Auto-start

Optional, default off. Unsandboxed only. Runs `~/.grok/grokbot-d/ensure-local-box.sh` once from app launch (when both flags are on) and from the pane refresh. Never launches `grokd-local`, D.app, or Seat4.

## Feature flags

UserDefaults keys, both default false:

- `localD.box.enabled`
- `localD.box.autoStart`

## Out of v1

Mobile, Iroh, `AgentProvider` / Hermes cases, SQLite writes, broadcast, `createAgent`, seat failover, Core HTTP (iOS loopback).
