---
name: governance-worker
description: Implement mission governance, policy controls, scheduling/notifications, team rails, and audit consistency.
---

# governance-worker

NOTE: Startup and cleanup are handled by worker-base. This skill defines the work procedure.

## When to Use This Skill
Use for governance/control-plane features: one-question closure invariant, PR lifecycle linkage contracts, scheduled reviews/notifications, team collaboration rails, enterprise policy controls, and audit/event consistency.

## Required Skills
None.

## Work Procedure
1. Start from `fulfills` IDs and identify daemon/core/app/extension contract touchpoints.
2. Add failing tests first in core/daemon and any necessary app/extension projection tests for parity.
3. Implement contract-safe mutations with strict invariants:
   - done-or-one-question closure
   - policy fail-closed behavior
   - audit event durability/replay safety
4. Ensure reason codes map consistently across daemon/app/extension surfaces.
5. Run validation commands:
   - `swift test --package-path OpenBurnBarCore --filter OpenBurnBarMissionControlContractsTests`
   - `swift test --package-path OpenBurnBarDaemon --filter OpenBurnBarMissionControlServiceTests`
   - `swift test --package-path OpenBurnBarDaemon --filter OpenBurnBarDaemonServerTests`
   - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/OpenBurnBarOperatingComposerTests"`
   - `npm --prefix extensions/openburnbar run test:unit -- test/projections.test.ts test/extension.test.ts`
6. Include explicit invariant checks in handoff evidence.

## Example Handoff
```json
{
  "salientSummary": "Implemented mission-scoped closure-question uniqueness and enterprise policy blocks with cross-surface reason-code parity.",
  "whatWasImplemented": "Added mission-scoped closure question dedupe/reject semantics, typed enterprise policy config with budget and approval modes, scheduled review generation metadata, and reason-code projection mapping used by app and extension parity views.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {
        "command": "swift test --package-path OpenBurnBarDaemon --filter OpenBurnBarMissionControlServiceTests",
        "exitCode": 0,
        "observation": "Governance invariants and scheduling tests passed."
      },
      {
        "command": "swift test --package-path OpenBurnBarDaemon --filter OpenBurnBarDaemonServerTests",
        "exitCode": 0,
        "observation": "Connector and server contract parity tests passed."
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
            "name": "testClosureQuestionUniquenessPerMission",
            "verifies": "Exactly one closure approval question invariant"
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator
- Governance rule conflicts require product/policy decision (for example precedence between budget cap and approval mode).
- Real connector integration required for validation is unavailable.
- Invariant enforcement requires migration strategy that could break existing persisted mission data.
