# OpenBurnBar Fleet API

Local, agent-readable contract for the live fleet projection. Clients read
fleet state; they do not reconstruct it by walking agent roots.

1. `daemon.fleet.snapshot` — versioned one-shot JSON-RPC over the local Unix
   socket.
2. `fleet-snapshot.json` — atomically replaced file of the same snapshot
   payload (`tmp` + rename).

Fleet is local-only. It does not use Firebase, Firestore, a cloud relay, or
a multi-machine transport.

Per-agent signal paths and freshness windows live in
[`BURNBAR_FLEET_SIGNALS.md`](./BURNBAR_FLEET_SIGNALS.md).

## Socket

Default path:

```text
~/Library/Application Support/OpenBurnBar/openburnbar-daemon.sock
```

Resolution order:

1. Daemon `--socket-path PATH`.
2. `OPENBURNBAR_DAEMON_SOCKET_PATH` or `BURNBAR_DAEMON_SOCKET_PATH` when
   non-empty.
3. `<support-directory>/openburnbar-daemon.sock`.

Default support directory is
`~/Library/Application Support/OpenBurnBar`. Override with
`OPENBURNBAR_DAEMON_SUPPORT_DIR` or `BURNBAR_DAEMON_SUPPORT_DIR`. That
moves the socket, `fleet.sqlite`, and `fleet-snapshot.json` together.

Hermetic probe roots: `BURNBAR_FLEET_ROOTS_DIR` plus optional
`BURNBAR_FLEET_ROOT_<AGENT>`. Default cadence is 15 seconds
(`BURNBAR_FLEET_CADENCE_SECONDS`). Event retention is 24 hours
(`BURNBAR_FLEET_EVENT_RETENTION_SECONDS`).

Transport is one connection, one newline-terminated request, one
newline-terminated response, clean close. Socket mode is owner-only `0600`.

## Methods

| Method | Capability | Meaning |
|---|---|---|
| `daemon.fleet.snapshot` | observability | Latest completed snapshot |
| `daemon.fleet.orchestrator.get` | observability | Daemon-owned designation |
| `daemon.fleet.orchestrator.set` | config | Set designation (ack is authoritative) |
| `daemon.fleet.directive.record` | config | Idempotent approved-directive upsert |

## Honesty

- Pre-first-tick snapshot reads return typed RPC error `-32603` whose
  message contains `not ready`. They never return a fabricated empty
  snapshot.
- A healthy empty board is a completed snapshot with all ten declared
  roster rows present and `runningCount == 0`.
- The Mac header never renders "0 running" until a snapshot exists.
- The Control Deck fleet tile distinguishes preparing / 0-running /
  daemon-down. It does not collapse those into a silent success.
- The Mac fleet board and Control Deck fleet tile prefer
  `daemon.fleet.snapshot`. If that socket returns an empty body or an
  undecodable envelope, both read the well-known `fleet-snapshot.json`
  rather than blanking a live tick.

## App membership

AgentLens sources are a `project.yml` glob (`path: AgentLens`). Do not
hand-edit `OpenBurnBar.xcodeproj/project.pbxproj` to add Fleet files.
After adding Swift under `AgentLens/`, run:

```sh
xcodegen generate --spec project.yml
```

and commit the generated project.
