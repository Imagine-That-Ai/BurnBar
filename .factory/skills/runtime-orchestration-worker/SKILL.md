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
   - `swift test --package-path OpenBurnBarDaemon --filter BurnBarRunServiceTests`
   - `swift test --package-path OpenBurnBarDaemon --filter BurnBarMissionControlServiceTests`
   - `swift test --package-path OpenBurnBarDaemon --filter BurnBarProviderRouterTests`
   Each command must produce explicit evidence output (test case names, assertion results) captured in the handoff `verification.commandsRun` array with `observation` field detailing what passed.
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
        "command": "swift test --package-path OpenBurnBarDaemon --filter BurnBarRunServiceTests",
        "exitCode": 0,
        "observation": "Run recovery/retry/restart tests passed including VAL-EXEC-008 failover order assertions and VAL-EXEC-012 journal sequence tests. All 47 test cases executed successfully."
      },
      {
        "command": "swift test --package-path OpenBurnBarDaemon --filter BurnBarMissionControlServiceTests",
        "exitCode": 0,
        "observation": "Parallel scheduler and reconciliation tests passed. VAL-EXEC-009 dependency gating and VAL-EXEC-010 winner selection determinism verified."
      },
      {
        "command": "swift test --package-path OpenBurnBarDaemon --filter BurnBarProviderRouterTests",
        "exitCode": 0,
        "observation": "Router scorecard and VAL-EXEC-008 failover tests passed. Route ordering assertions confirmed deterministic composite scoring."
      }
    ],
    "interactiveChecks": []
  },
  "tests": {
    "added": [
      {
        "file": "OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/OpenBurnBarRunServiceTests.swift",
        "cases": [
          {
            "name": "test_VAL_EXEC_008_failoverAttemptsAreDeterministicallyOrdered",
            "verifies": "VAL-EXEC-008: Explicit deterministic attempted failover route slot/identity order"
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
