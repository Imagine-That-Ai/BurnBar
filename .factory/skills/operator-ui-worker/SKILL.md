---
name: operator-ui-worker
description: Build macOS operator UX for mission authoring, inbox, brief, closure, and re-entry with daemon parity.
---

# operator-ui-worker

NOTE: Startup and cleanup are handled by worker-base. This skill defines the work procedure.

## When to Use This Skill
Use for AgentLens/UI features in dashboard/popover/projects/session detail involving mission authoring, operator inbox, brief fields, one-question UX, and re-entry controls.

## Required Skills
None.

## Work Procedure
1. Read assertion IDs and verify which surfaces must change (Dashboard, Projects, Workbench, Session Detail, Popover).
2. Write/adjust failing app tests first (active test targets only).
3. Implement UI + operating layer changes with daemon-first behavior and explicit degraded-mode messaging.
4. Validate deterministic ordering (next action, queue items, tie-breaks) and singleton top-level question card behavior.
5. Run app and relevant daemon checks:
   - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/OpenBurnBarOperatingComposerTests"`
   - `swift test --package-path OpenBurnBarDaemon --filter BurnBarMissionControlServiceTests`
6. Verify handoff commitId before finalizing:
   - Run `git rev-parse --verify <commitId>` to confirm commit exists
   - Run `git show --name-only <commitId>` to confirm the diff contains relevant feature files
7. Include screenshots/state snapshots or equivalent test artifacts in handoff observations.

## Example Handoff
```json
{
  "salientSummary": "Delivered mission brief field expansion and deterministic next-action rendering across dashboard and projects surfaces.",
  "whatWasImplemented": "Updated operating models and views to include changed-files/risks/remaining-work in mission brief, enforced singleton top-level question card on dashboard, and aligned queue ordering tie-breaks with daemon summary mapping.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {
        "command": "xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination \"platform=macOS,arch=arm64\" -only-testing:\"OpenBurnBarTests/OpenBurnBarOperatingComposerTests\"",
        "exitCode": 0,
        "observation": "All updated operating composer scenarios passed."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Reviewed dashboard and projects snapshots for brief fields and top-level question card",
        "observed": "Brief fields rendered consistently and only one top-level question card is shown."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "AgentLensTests/Active/OpenBurnBarOperatingComposerTests.swift",
        "cases": [
          {
            "name": "testMissionBriefIncludesRisksAndRemainingWork",
            "verifies": "Brief contract completeness"
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator
- Required UI behavior depends on daemon contract fields not yet available.
- Surfaces need UX/policy decision (for example competing next-action priority rules) not defined in mission artifacts.
- Test target limitations prevent validating required user-visible behavior.
