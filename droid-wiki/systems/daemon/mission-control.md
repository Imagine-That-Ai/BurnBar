# Mission control

Mission control is the daemon-backed runtime for project tracking, agent mission dispatch, question/followup workflows, and scheduled review automation.

**Support tier:** Experimental — fully functional and tested, but the data model and CLI surface are still evolving. Disabled by default; requires explicit opt-in.

---

## Purpose

Mission control turns the daemon into an autonomous project manager. It:

- Maintains a durable project registry with per-project metadata and review schedules
- Ingests OpenBurnBar activity to derive controller state for each project
- Surfaces pending questions and followups with notification dispatch and deep links
- Dispatches mission packets to daemon-managed runs and tracks result provenance
- Records auto-takeover state for failed or stalled work
- Supports simulator/replay so past run sequences can be replayed for testing

---

## Key concepts

### Project registry

Each registered project has a slug, display name, repository path, and an optional review schedule. Projects are the top-level unit of aggregation for all mission control activity.

### Controller runtime

The controller ingests parsed OpenBurnBar activity and builds a per-project summary — current run state, recent sessions, pending work, and health indicators. The `controllerSummary` CLI command and RPC method surface this as `BurnBarControllerSummary`.

### Questions and followups

During or after a run the daemon may surface **questions** (open items requiring human input) and **followups** (actions derived from run outcomes). Both are notification-driven and support deep links from macOS notifications back to the controller workbench in the app.

### Mission dispatch

A mission is a discrete unit of agent work with a defined goal, scope, and approval requirement. The flow is:

1. Mission packet is created and surfaces in the `missions` CLI list.
2. A human (or the CLI) calls `mission-approve <missionID>` (optionally with a note).
3. The daemon dispatches the mission to a provider run via the run service.
4. Result provenance is recorded against the run journal and usage ledger.

### Scheduled reviews

Each project can carry a review schedule. The controller runtime fires review events on schedule and enqueues any follow-on questions or missions.

### Simulator / replay

The simulator records run sequences that can be replayed deterministically. `simulator-runs` lists available snapshots; `simulator-replay <runID>` re-executes a run from its recorded inputs.

---

## Source files

All mission control logic lives in `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/MissionControl/`:

| File | Role |
|---|---|
| `MissionControlService.swift` (~60 KB) | Top-level service actor; orchestrates all subsystems |
| `MissionControlStore.swift` (~53 KB) | Persistence layer for projects, missions, questions, followups |
| `BurnBarParallelDAGScheduler.swift` (~39 KB) | DAG-based parallel scheduler for mission steps |
| `MissionControlMissionStateMerger.swift` (~19 KB) | Merges incoming run state into mission records |
| `MissionControlSummaryEnricher.swift` (~15 KB) | Enriches controller summary with project context |
| `MissionControlNotificationEvaluator.swift` (~6 KB) | Decides when to fire notifications |
| `MissionControlHelpers.swift` (~11 KB) | Shared utilities |
| `MissionControlJournalRepository.swift` (~3 KB) | Appends mission events to the run journal |
| `MissionControlProjectionReducer.swift` (~5 KB) | Reduces events into projection snapshots |
| `MissionControlProjectionFile.swift` (~3 KB) | Reads/writes projection files on disk |
| `MissionControlTransport.swift` (~3 KB) | Wire types for RPC serialisation |
| `MissionControlError.swift` | Error enum |
| `Bridges/` | Bridge adapters to the main run service |

The service is exposed to the RPC server through the `BurnBarMissionControlServing` protocol, injected into `BurnBarDaemonServer` at init time (`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift`).

---

## Data flow

```
CLI / app RPC call
    ↓
BurnBarDaemonServer  (JSON-RPC over Unix socket)
    ↓
MissionControlService.dispatch()
    ↓
BurnBarParallelDAGScheduler  ← mission step DAG
    ↓
BurnBarRunService.start()    ← daemon run lifecycle
    ↓
Provider executor            ← actual API call
    ↓
run-journal.jsonl            ← durable provenance
    ↓
MissionControlMissionStateMerger  ← state update
    ↓
MissionControlStore          ← persisted mission record
```

---

## State storage

Mission control state is split across two locations:

**Daemon support directory** (`~/Library/Application Support/OpenBurnBar/`):

- `run-journal.jsonl` — run events written by `OpenBurnBarRunJournal`
- Projection files — per-project snapshots written by `MissionControlProjectionFile`
- Controller event records

**App SQLite (mirrored, read-only for graceful degradation):**

- A mirrored controller runtime cache is written to the app's local SQLite so the app can display controller state even when the daemon is temporarily unavailable. The SQLite table is populated via `ControlPlaneStore` (see `AgentLens/Services/DataStore/DataStore.swift`).

---

## CLI reference

```bash
# Controller summary
OpenBurnBarCLI controller [projectSlug]

# Pending questions
OpenBurnBarCLI questions [projectSlug]

# Pending followups
OpenBurnBarCLI followups [projectSlug]

# Mission list
OpenBurnBarCLI missions [projectSlug]

# Approve a mission
OpenBurnBarCLI mission-approve <missionID> [note]

# Simulator
OpenBurnBarCLI simulator-runs [projectSlug]
OpenBurnBarCLI simulator-replay <runID>
```

---

## Related pages

- [Daemon overview](./index.md)
- [Local database](../local-database/index.md) — ControlPlaneStore for mirror cache
