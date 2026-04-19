---
name: runtime-orchestration-worker
description: Implement mission execution runtime behavior including dispatch, recovery, checkpoints, scheduler, and reconciliation.
---

# runtime-orchestration-worker

NOTE: Startup and cleanup are handled by worker-base. This skill defines the work procedure.

## When to Use This Skill
Use for daemon runtime features: packet dispatch lifecycle, run journal semantics, recovery/retry/takeover behavior, parallel scheduler, critical path tracking, and reconciliation winner logic.

## Required Skills
None.

## Work Procedure
1. Map the assigned `fulfills` assertions to exact daemon runtime behaviors and existing tests.
2. Add failing tests first for run lifecycle, replay/restart safety, and reconciliation determinism.
3. Implement runtime code with idempotency and append-only journal assumptions preserved.
4. Verify no duplicate terminal results, no duplicate usage accounting, and stable takeover semantics.
5. Run focused validation commands:
   - `swift test --package-path OpenBurnBarDaemon --filter OpenBurnBarRunServiceTests`
   - `swift test --package-path OpenBurnBarDaemon --filter OpenBurnBarMissionControlServiceTests`
   - `swift test --package-path OpenBurnBarDaemon --filter OpenBurnBarProviderRouterTests`
6. If touching scheduling/reconciliation, include explicit before/after timeline evidence in handoff.

## Example Handoff
```json
{
  "salientSummary": "Implemented critical-path tracking and replay-stable winner reconciliation for parallel DAG execution.",
  "whatWasImplemented": "Added scheduler dependency gating checks, critical-path artifact emission, reconciler winner reason persistence, and replay tests ensuring same winner after rebuild. Updated run-journal events to capture transition timeline required for deterministic replay.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {
        "command": "swift test --package-path OpenBurnBarDaemon --filter OpenBurnBarRunServiceTests",
        "exitCode": 0,
        "observation": "Run recovery/retry/restart tests passed including new journal assertions."
      },
      {
        "command": "swift test --package-path OpenBurnBarDaemon --filter OpenBurnBarMissionControlServiceTests",
        "exitCode": 0,
        "observation": "Parallel scheduler and reconciliation tests passed."
      }
    ],
    "interactiveChecks": []
  },
  "tests": {
    "added": [
      {
        "file": "OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/OpenBurnBarMissionControlServiceTests.swift",
        "cases": [
          {
            "name": "testReconcilerWinnerIsReplayStable",
            "verifies": "Winner remains identical after replay"
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator
- Runtime behavior required by feature conflicts with mission invariants (done-or-one-question, idempotent replay).
- A dependency for real integration testing is unavailable and cannot be restored in-session.
- Parallel scheduling semantics require policy prioritization not specified in contracts.
