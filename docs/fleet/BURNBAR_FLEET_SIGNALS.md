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

## Threads (command center)

The atom is a **thread**, not a vendor card. Each probe emits a bounded
list (`threads[]`, cap 50 per CLI): live PID ∪ freshness window. Dead and
stale historical files are not emitted. `countsByAgent` is that CLI's
running thread count. The ten agent rows remain as a roll-up
(running > idle > stale > unknown).

Stable `id` / `sessionRef` is never a PID alone: Claude `sessionId` or
session-file stem, Codex lock stem, Pi transcript stem, Cursor worker
display name, Grok CLI `session_id`, Factory invocation/session/mission
slug, Hermes `gateway` plus `processes.json` cwd, Grok Bot `daemon`.
Kimi and Gemini emit **0** threads until a live signal exists.

## Inbox

Every roster CLI writes
`~/Library/Application Support/BurnBar/fleet-inbox/<agent>/<sessionRef>.jsonl`
mode `0600`. A successful write is `submitted`, never `delivered`.
Hermes HTTP may upgrade to `delivered` only when the response carries
`burnbar_delivery.directive_id`. An OpenAI-shaped 200 is `submitted`.
Claude `/tmp/cc-socks` is never used. CLI one-shot is a labeled **new
turn**, never live TUI inject.

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
