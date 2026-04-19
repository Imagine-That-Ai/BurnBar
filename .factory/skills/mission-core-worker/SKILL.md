---
name: mission-core-worker
description: Build and evolve daemon/core planning, DAG contracts, router scoring, and readiness gates for Mission Control Fleet.
---

# mission-core-worker

NOTE: Startup and cleanup are handled by worker-base. This skill defines the work procedure.

## When to Use This Skill
Use for Mission Control Fleet core-domain features in OpenBurnBarCore and OpenBurnBarDaemon involving mission creation contracts, planner inputs, DAG schemas/versioning, router scoring, and readiness checks.

## Required Skills
None.

## Work Procedure
1. Read mission requirements plus the feature description and `fulfills` assertion IDs before changing code.
2. Add/adjust failing tests first for the specific assertion IDs (contracts + daemon service tests).
3. Implement minimal core/daemon code changes to make tests pass while preserving deterministic behavior and typed contracts.
4. Validate schema/version compatibility and deterministic tie-break behavior for ordering/routing.
5. Run focused validators first, then broader mission checks:
   - `swift test --package-path OpenBurnBarCore --filter OpenBurnBarMissionControlContractsTests`
   - `swift test --package-path OpenBurnBarDaemon --filter OpenBurnBarMissionControlServiceTests`
   - `swift test --package-path OpenBurnBarDaemon --filter OpenBurnBarProviderRouterTests`
6. If this feature changes public contracts used by app/extension, add compatibility notes in handoff and include affected fields.

## Example Handoff
```json
{
  "salientSummary": "Implemented typed planner input validation and versioned DAG contract updates with deterministic node/edge ID behavior.",
  "whatWasImplemented": "Added schemaVersion-aware planner input decoding, required field validation for constraints/riskLevel/desiredOutputs, deterministic ID generation tests, and mission-service readiness rejection reason codes wired through dispatch preflight.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {
        "command": "swift test --package-path OpenBurnBarCore --filter OpenBurnBarMissionControlContractsTests",
        "exitCode": 0,
        "observation": "All contract round-trip and version compatibility cases passed."
      },
      {
        "command": "swift test --package-path OpenBurnBarDaemon --filter OpenBurnBarMissionControlServiceTests",
        "exitCode": 0,
        "observation": "Mission preflight/reason-code scenarios passed."
      }
    ],
    "interactiveChecks": []
  },
  "tests": {
    "added": [
      {
        "file": "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/OpenBurnBarMissionControlContractsTests.swift",
        "cases": [
          {
            "name": "testPlannerInputRequiresConstraintsRiskAndDesiredOutputs",
            "verifies": "Planner input required field contract"
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator
- Required field semantics conflict between mission contract and existing persisted schema.
- A new public contract change would break app/extension compatibility without coordinated follow-up features.
- Deterministic routing/tie-break behavior cannot be implemented without product-policy decision.
