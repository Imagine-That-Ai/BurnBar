---
name: switcher-integration-worker
description: Complete cross-surface synchronization, navigation flows, and security/log hardening for the account switcher.
---

# Switcher Integration Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the work procedure.

## When to Use This Skill

Use for cross-surface flows, relaunch persistence, race handling, log redaction, and end-to-end integration contracts spanning Settings, Dashboard, Popover, Browser, and CLI actions.

## Required Skills

None.

## Work Procedure

1. Read mission artifacts and all relevant assertion IDs in `fulfills`.
2. Write failing integration tests first for cross-surface flows and security guarantees.
3. Implement minimal changes to pass:
   - Shared active-state propagation
   - Navigation/recovery flows
   - Launch chaining consistency
   - Logging redaction
4. Verify race safety with deterministic tests.
5. Run validation stack:
   - `swift test --package-path OpenBurnBarCore`
   - scoped `xcodebuild test -only-testing:...`
   - `scripts/test-openburnbar-app.sh`
   - browser/CLI smoke commands when relevant
6. Collect evidence across UI traces, state snapshots, launch traces, and logs.
7. Return detailed handoff and flag any unresolved infra blockers.

## Example Handoff

```json
{
  "salientSummary": "Completed cross-surface switcher integration: state consistency, relaunch restoration, recovery navigation, and secret-safe logging.",
  "whatWasImplemented": "Wired global active profile synchronization across Settings/Dashboard/Popover, added end-to-end create->switch->launch flows, enforced deterministic launch chaining after rapid switches, and redacted switcher launch logs.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {
        "command": "swift test --package-path OpenBurnBarCore",
        "exitCode": 0,
        "observation": "Cross-flow and redaction tests passed."
      },
      {
        "command": "xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination \"platform=macOS,arch=arm64\" -only-testing:\"OpenBurnBarTests/SwitcherCrossFlowTests\"",
        "exitCode": 0,
        "observation": "Cross-surface integration tests passed."
      },
      {
        "command": "open -Ra \"Safari\" && open -Ra \"Google Chrome\"",
        "exitCode": 0,
        "observation": "Browser targets are resolvable for launch flows."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Manual: empty-state recovery from popover/dashboard to settings create flow then return",
        "observed": "Profile available immediately across surfaces and switching worked without relaunch."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "AgentLensTests/Active/SwitcherCrossFlowTests.swift",
        "cases": [
          {
            "name": "test_switchInPopoverLaunchInDashboardUsesSameActiveProfile",
            "verifies": "Cross-surface chaining uses current active profile."
          },
          {
            "name": "test_relaunchRestoresActiveProfileAcrossAllSurfaces",
            "verifies": "Active state persists and rehydrates consistently."
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

- Cross-surface assertions require feature reprioritization across milestones.
- Validation cannot proceed due to environment-level issues outside repository control.
- Security assertions fail due to unresolved legacy logging behavior requiring wider policy decisions.
