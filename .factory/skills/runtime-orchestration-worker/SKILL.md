---
name: runtime-orchestration-worker
description: Implement mission execution runtime behavior including dispatch, recovery, checkpoints, scheduler, and reconciliation.
---

# runtime-orchestration-worker

NOTE: Startup and cleanup are handled by worker-base. This skill defines the work procedure.

## When to Use This Skill
Use for mission execution runtime features. This skill covers two distinct surfaces — choose the branch that matches your feature's actual surface:

**Branch A — Daemon Runtime (primary):** packet dispatch lifecycle, run journal semantics, recovery/retry/takeover behavior, parallel scheduler, critical path tracking, and reconciliation winner logic.

**Branch B — OpenBurnBarCore CLI-Launch Reliability:** CLI launch pipe handling, NSFileHandle deterministic read loop, CLILaunchInvoker stability hardening, script-level validator sweeps. Features touching `OpenBurnBarCore/Sources/CLILaunchInvoker` or `CLILaunchInvokerTests` use this branch and the Branch B validator commands below.

### Skill Assignment Rules (preventing future mismatches)

Before accepting a feature assignment, verify the feature's primary surface matches this skill's scope:
- **runtime-orchestration-worker owns:** OpenBurnBarDaemon runtime, OpenBurnBarCore CLILaunchInvoker/pipe reliability
- **mission-core-worker owns:** OpenBurnBarCore contracts, DAG schema, planner/dispatch contracts, intent normalization
- **governance-worker owns:** question/followup lifecycle, approval cardinality, team rails, audit/replay
- **operator-ui-worker owns:** macOS app UI surfaces (authoring, inbox, brief, board)
- **extension-worker owns:** extension bridge, controller lifecycle, session parity

If a feature spans multiple surfaces, the skill is determined by the **primary/runtime surface** (where the core logic lives, not where tests live). If the feature is truly cross-cutting, return to orchestrator for skill clarification before starting work.

**Anti-pattern (do not assign to runtime-orchestration-worker):** A feature whose primary logic lives in OpenBurnBarCore contracts or OpenBurnBarDaemon service layer but whose only test surface happens to be a CLI launch path — use the skill matching the primary logic surface.

## Required Skills
None.

## Work Procedure
1. **Identify branch** — Determine whether this is Branch A (daemon runtime) or Branch B (OpenBurnBarCore CLI-launch reliability). Check `When to Use This Skill` above.
2. Map the assigned `fulfills` assertions to exact runtime behaviors and existing tests.
3. Add failing tests first for run lifecycle, replay/restart safety, and reconciliation determinism.
4. Implement runtime code with idempotency and append-only journal assumptions preserved.
5. Verify no duplicate terminal results, no duplicate usage accounting, and stable takeover semantics.
6. **Run focused validation commands — Branch A (daemon runtime):**
   - `swift test --package-path OpenBurnBarDaemon --filter BurnBarRunServiceTests`
   - `swift test --package-path OpenBurnBarDaemon --filter BurnBarMissionControlServiceTests`
   - `swift test --package-path OpenBurnBarDaemon --filter BurnBarProviderRouterTests`
   **Run focused validation commands — Branch B (CLI-launch reliability):**
   - `swift test --package-path OpenBurnBarCore --filter CLILaunchInvokerTests`
   - `./scripts/test-openburnbar-swift.sh`
   - `swift test --package-path OpenBurnBarDaemon --filter BurnBarRunServiceTests` (only if runtime integration exists)

   **⚠️ Handoff evidence requirement (enforced):** `followedProcedure=true` in the skillFeedback block of `EndFeatureRun` is only valid when **every required validator command for the applicable branch** has a corresponding entry in the handoff `verification.commandsRun` array. Each entry must include:
   - `command`: the exact command string executed
   - `exitCode`: the actual exit code (0 or non-zero)
   - `observation`: specific, non-generic text describing which test cases ran and what they verified (not just "tests passed")
   
   A handoff with `followedProcedure=true` but missing evidence for any required validator surface is invalid and must be treated as a procedure deviation. List any validator surfaces that were not exercised as empty/omitted in the handoff if they genuinely do not apply to the feature.

### Test Filter Guidance: Canonical vs. Assertion-Filter Commands

**Canonical test commands** run all tests in a test class and are used for baseline validation:
- `swift test --package-path OpenBurnBarDaemon --filter BurnBarRunServiceTests`
- `swift test --package-path OpenBurnBarDaemon --filter BurnBarMissionControlServiceTests`
- `swift test --package-path OpenBurnBarDaemon --filter BurnBarProviderRouterTests`

**Assertion-filter commands** run a specific subset of tests that verify a particular validation assertion (e.g., `VAL_EXEC_009`). These are supplemental and appropriate when:
- A feature's `verificationSteps` explicitly require assertion-filter verification (e.g., `swift test --filter VAL_EXEC_009`)
- A worker is adding regression lock-in tests for a specific assertion ID
- The feature scope is narrow and well-defined by a single assertion

**When to use which:**
- Use **canonical commands** for baseline validation and broad coverage
- Use **assertion-filter commands** when the feature's `verificationSteps` explicitly specify them or when adding targeted regression tests for a specific assertion
- Both are valid; the key is using the right tool for the task at hand

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
- The assigned feature's primary surface does not match Branch A or Branch B — return for skill clarification before starting work.
