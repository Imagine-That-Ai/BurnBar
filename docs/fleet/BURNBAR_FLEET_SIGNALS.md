# OpenBurnBar Fleet Signals

Authoritative inventory for Live Agent Fleet probes and dashboard rendering.

## Roster

Exactly these ten wire IDs, in this order:

`claude-code`, `factory-droid`, `codex`, `hermes`, `grok-bot`, `grok-cli`,
`pi`, `cursor`, `kimi`, `gemini-cli`

`kimi` and `gemini-cli` are typed unsupported rows. They appear in every
snapshot. They are never omitted and never presented as live.

Every agent row carries one status (`running | idle | stale | unknown`) and
one confidence (`exactProcess | activeSessionFile | logHeartbeat |
estimated | unsupported`). Every `probeHealth` entry names its declared
root and a typed state (`ok | degraded(reason) | failed(reason)`).

Schema rule (encode-side): a `running` row may not carry `unsupported` or
`estimated`; an `unknown` row may not carry `exactProcess`.

## Freshness (pinned)

| Agent | Signal | Constant | Value |
|---|---|---|---|
| `claude-code` | session `updatedAt` | `claudeCodeFreshnessSeconds` | 120s |
| `hermes` | gateway heartbeat | `hermesHeartbeatFreshnessSeconds` | 120s |
| `grok-bot` | supervisor / recent log | `grokBotSupervisorFreshnessSeconds` | 120s |
| `factory-droid` | invocation / session mtime | `factoryDroidFreshnessSeconds` | 300s |
| `codex` | lock-file mtime | `codexLockFreshnessSeconds` | 300s |
| `pi` | newest transcript mtime | `piTranscriptFreshnessSeconds` | 300s |
| `cursor` | `ai-tracking/` mtime | `cursorTrackingFreshnessSeconds` | 300s |

Snapshot cadence: **15s** (`BURNBAR_FLEET_CADENCE_SECONDS`).
Event retention: **24h** (`BURNBAR_FLEET_EVENT_RETENTION_SECONDS`).

The dashboard treats a snapshot as stale when
`now - generatedAt > 2 * cadenceSeconds`.

## Probe contract

Probes are read-only. They may `stat`/read declared roots and check process
existence (`kill(pid, 0)` / `proc_pidinfo`). They must not send a nonzero
signal, write an agent root, or follow a symlink out of the declared root.
Claude `/tmp/cc-socks/*.sock` is undocumented internal IPC and is never a
delivery channel.

A tick emits at most one structured `fleet_probe_degraded` record per
affected roster agent. Logs carry wire id + state + tick + daemon pid —
never paths, reasons, or exception text. Typed reasons stay on
`probeHealth` for RPC/file consumers.

## Dashboard rendering

- Confidence and status are labeled in text. Color is secondary.
- Machine optional metrics render `—` / unavailable, never `0` or `NaN`.
- Token-burn rows are labeled **Proxy**. They are never formatted as exact
  per-pid numbers.
- Orchestrator designation changes only after daemon acknowledgement.
- Chat may share the dashboard `FleetService` but must not call `start()`.
  Context reads use `fetchSnapshotForContext()` so a miss cannot wipe a
  healthy board.

## Persistence

`fleet.sqlite` plus atomic `fleet-snapshot.json`. Corruption rebuilds the
store and surfaces `degraded(storeRebuilt)`. The daemon does not crash
over a corrupt fleet store.
