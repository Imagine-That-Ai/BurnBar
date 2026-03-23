# BurnBar Full Agent Execution Plan

## Goal

Turn BurnBar from a daemon-backed shell into a full coding agent while preserving:

- daemon as source of truth
- extension workspace companion as the only executor
- local-first provider/key ownership
- reconnect, approvals, arbitration, and usage accounting

## Architecture

```text
Cursor Extension
  -> daemon client
  -> run projections / approval UI / reconnect UI
  -> workspace companion
       -> read_file / search_workspace / apply_patch / run_terminal

BurnBar Daemon
  -> RunService                (coordinator only)
  -> PlannerService            (typed intent + plan outline)
  -> ContextSelector           (repo-aware next actions)
  -> PolicyEngine              (risk / approval / retry / progress)
  -> RecoveryEngine            (deterministic repair decisions)
  -> RunJournal                (events + checkpoints)
  -> WorkspaceBridgeBroker     (pending tool work)
  -> ProviderRouter / UsageRecorder / ClientRegistry
```

## Phase 1: Shared Contracts And Daemon Foundations

### Outcome

Introduce the typed language for the new agent stack and land daemon-native service scaffolds without changing the extension contract shape yet.

### Ownership

- Core contracts:
  [BurnBarAgentContracts.swift](/Users/albertonunez/Developer/AgentLens/BurnBarCore/Sources/BurnBarCore/BurnBarAgentContracts.swift)
- Daemon services:
  [BurnBarPlannerService.swift](/Users/albertonunez/Developer/AgentLens/BurnBarDaemon/Sources/BurnBarDaemon/BurnBarPlannerService.swift)
  [BurnBarContextSelector.swift](/Users/albertonunez/Developer/AgentLens/BurnBarDaemon/Sources/BurnBarDaemon/BurnBarContextSelector.swift)
  [BurnBarPolicyEngine.swift](/Users/albertonunez/Developer/AgentLens/BurnBarDaemon/Sources/BurnBarDaemon/BurnBarPolicyEngine.swift)
  [BurnBarRecoveryEngine.swift](/Users/albertonunez/Developer/AgentLens/BurnBarDaemon/Sources/BurnBarDaemon/BurnBarRecoveryEngine.swift)
  [BurnBarRunJournal.swift](/Users/albertonunez/Developer/AgentLens/BurnBarDaemon/Sources/BurnBarDaemon/BurnBarRunJournal.swift)

### Test Checklist

- Contract round-trip tests for typed intent, plan, recovery, and journal event/checkpoint types
- Unit tests for planner intent normalization
- Unit tests for context selector action sequencing
- Unit tests for policy risk/approval/retry classification
- Unit tests for recovery action mapping
- Unit tests for journal append/read/checkpoint behavior

## Phase 2: RunService Refactor

### Outcome

Make `RunService` a coordinator only and move logic into the new services without regressing the current `read_file` / `apply_patch` / `run_terminal` flows.

### Ownership

- Main coordinator:
  [BurnBarRunService.swift](/Users/albertonunez/Developer/AgentLens/BurnBarDaemon/Sources/BurnBarDaemon/BurnBarRunService.swift)
- Bridge and registry:
  [BurnBarWorkspaceBridgeBroker.swift](/Users/albertonunez/Developer/AgentLens/BurnBarDaemon/Sources/BurnBarDaemon/BurnBarWorkspaceBridgeBroker.swift)
  [BurnBarClientRegistry.swift](/Users/albertonunez/Developer/AgentLens/BurnBarDaemon/Sources/BurnBarDaemon/BurnBarClientRegistry.swift)

### Test Checklist

- Existing run-service tests stay green
- New tests for typed intent -> plan outline -> tool dispatch sequencing
- New tests for journal event emission on create, approval, tool dispatch/result, recovery, completion, failure, cancel
- New replay/checkpoint tests once journal replay is wired into startup/reconnect

## Phase 3: Repo-Aware Context And Recovery

### Outcome

Replace the demo-only workflow logic with daemon-owned context selection and deterministic repair behavior.

### Ownership

- Context and recovery:
  [BurnBarContextSelector.swift](/Users/albertonunez/Developer/AgentLens/BurnBarDaemon/Sources/BurnBarDaemon/BurnBarContextSelector.swift)
  [BurnBarRecoveryEngine.swift](/Users/albertonunez/Developer/AgentLens/BurnBarDaemon/Sources/BurnBarDaemon/BurnBarRecoveryEngine.swift)
  [BurnBarPolicyEngine.swift](/Users/albertonunez/Developer/AgentLens/BurnBarDaemon/Sources/BurnBarDaemon/BurnBarPolicyEngine.swift)

### Test Checklist

- Fixture repos for correct file targeting, ambiguity, expansion, and recomputation
- Recovery tests for malformed tool output, trust gates, terminal failure, and no-progress loop breaks
- Policy matrix tests covering trust state, tool risk, retryability, and approval requirements

## Phase 4: Extension UX And Resume

### Outcome

Expose the full agent loop in Cursor with reliable reconnect, control transfer, and richer run visibility.

### Ownership

- Daemon client/types:
  [client.ts](/Users/albertonunez/Developer/AgentLens/extensions/burnbar/src/daemon/client.ts)
  [types.ts](/Users/albertonunez/Developer/AgentLens/extensions/burnbar/src/types.ts)
- Controller and projections:
  [controller.ts](/Users/albertonunez/Developer/AgentLens/extensions/burnbar/src/state/controller.ts)
  [projections.ts](/Users/albertonunez/Developer/AgentLens/extensions/burnbar/src/state/projections.ts)
  [panelViewModel.ts](/Users/albertonunez/Developer/AgentLens/extensions/burnbar/src/state/panelViewModel.ts)
- Extension entry:
  [extension.ts](/Users/albertonunez/Developer/AgentLens/extensions/burnbar/src/extension.ts)

### Test Checklist

- Extension unit tests for start/retry/cancel/approve/reject
- Extension unit tests for controller transfer and pending tool UI state
- Extension-host tests for daemon-backed planning, approval display, reconnect resume, and restricted workspace gating
- Live Cursor smoke for start run -> file change -> completion

## Phase 5: Journal Replay And Richer Visibility

### Outcome

Use daemon checkpoints + event replay for restart-safe runs and prepare the data shape for richer run playback later.

### Ownership

- Journal replay:
  [BurnBarRunJournal.swift](/Users/albertonunez/Developer/AgentLens/BurnBarDaemon/Sources/BurnBarDaemon/BurnBarRunJournal.swift)
  [BurnBarRunService.swift](/Users/albertonunez/Developer/AgentLens/BurnBarDaemon/Sources/BurnBarDaemon/BurnBarRunService.swift)
  [BurnBarDaemonServer.swift](/Users/albertonunez/Developer/AgentLens/BurnBarDaemon/Sources/BurnBarDaemon/BurnBarDaemonServer.swift)

### Test Checklist

- Restart while planning
- Restart while awaiting approval
- Restart while waiting on companion
- Restart after recovery decision but before completion
- Observer attach + claim-control against replayed runs

## Done When

- BurnBar starts runs from Cursor
- Daemon normalizes typed intents and produces plan outlines
- Daemon picks context actions instead of relying on demo-only workflow metadata
- Recovery is deterministic and journaled
- Runs survive reconnect and daemon restart
- Extension and smoke tests prove the full flow
