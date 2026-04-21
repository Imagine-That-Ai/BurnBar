---
name: extension-worker
description: Implement extension bridge mission parity, lifecycle visibility, operator actions, and reconnect safety.
---

# extension-worker

NOTE: Startup and cleanup are handled by worker-base. This skill defines the work procedure.

## When to Use This Skill
Use for `extensions/openburnbar` work: daemon bridge types/client/controller logic, projection/view-model updates, extension host integration, and mission parity in extension surfaces.

## Required Skills
None.

## Work Procedure
1. Confirm target assertion IDs and map required extension contract/state/view changes.
2. Add failing Vitest/extension-host tests first for bridge parity and reconnect behavior.
3. Implement bridge/client/state updates, preserving controller arbitration and session mismatch recovery semantics.
4. Validate mission parity fields (mission lifecycle, closure evidence, PR linkage, closure question state) when required.
5. Run extension checks:
   - `npm --prefix extensions/openburnbar run test:unit -- test/controller.test.ts test/projections.test.ts test/workspacePanel.test.ts test/extension.test.ts`
   - `./scripts/test-openburnbar-extension-host.sh`
6. Include evidence showing daemon→extension projection convergence after mutating actions.

## Example Handoff
```json
{
  "salientSummary": "Added mission RPC/type parity to extension bridge and surfaced mission closure evidence in workspace panel projections.",
  "whatWasImplemented": "Extended extension RPC method/type unions for mission/question/followup reads and mission operator actions, wired controller refresh to hydrate mission lifecycle state, and rendered closure evidence fields (PR linkage + closure question status) in extension view model.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {
        "command": "npm --prefix extensions/openburnbar run test:unit -- test/controller.test.ts test/projections.test.ts test/workspacePanel.test.ts test/extension.test.ts",
        "exitCode": 0,
        "observation": "All mission parity and reconnect tests passed."
      },
      {
        "command": "./scripts/test-openburnbar-extension-host.sh",
        "exitCode": 0,
        "observation": "Extension-host integration validated daemon bridge behavior."
      }
    ],
    "interactiveChecks": []
  },
  "tests": {
    "added": [
      {
        "file": "extensions/openburnbar/test/projections.test.ts",
        "cases": [
          {
            "name": "projectsMissionClosureEvidenceParity",
            "verifies": "Extension mission closure projection matches daemon fixture"
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator
- Needed daemon mission contracts are unavailable or unstable for extension parity implementation.
- Extension-host environment cannot validate required integration behavior.
- Arbitration/session ownership semantics conflict with required mission operator actions.
