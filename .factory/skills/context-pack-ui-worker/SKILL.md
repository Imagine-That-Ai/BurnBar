---
name: context-pack-ui-worker
description: Implement Context Pack sheet UI and Dashboard/Session Detail entry integrations with polished interactions.
---

# Context Pack UI Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the WORK PROCEDURE.

## When to Use This Skill

Use for Context Pack UI/integration work:
- `ContextPackSheet` UI and state management
- Dashboard and Session Detail entry points
- copy confirmation, target pill behavior, budget indicator, empty-state UI
- cross-entrypoint behavior coherence

## Required Skills

- `frontend-design`: Invoke before final UI implementation pass to ensure polish, spacing, and visual consistency with existing design system.

## Work Procedure

1. Read mission artifacts and target assertion IDs from `fulfills`.
2. Add failing UI/state tests first for Dashboard, Session Detail, and cross-flow assertions.
   - Keep validation-contract test method names verbatim when the contract references explicit `-only-testing` selectors.
   - Do not replace entry-surface tests with service-only tests; assertions for Session Detail and CrossFlow must exercise real Dashboard/Session Detail/ContextPackSheet wiring.
3. Implement UI with existing app primitives (`GlassCard`, design tokens, existing copy-confirm patterns); avoid introducing unrelated design systems.
4. Invoke `frontend-design` skill and apply improvements that align with mission scope and current app style.
5. Re-run scoped tests (`ContextPackDashboardSurfaceTests`, `ContextPackSessionDetailSurfaceTests`, `ContextPackCrossFlowTests`) until green.
6. Run required repo validators from `.factory/services.yaml`.
7. Verify no unrelated UI regressions in touched views via test coverage and deterministic state assertions.

## Example Handoff

```json
{
  "salientSummary": "Implemented ContextPackSheet and integrated Dashboard + Session Detail entry points with polished interactions. Added/updated UI tests for entry behavior, copy state, budget warnings, and cross-entrypoint consistency; validators passed.",
  "whatWasImplemented": "Added ContextPackSheet with target pills, copy action, confirmation lifecycle, char-budget indicator, and empty state. Wired Dashboard overview card and Session Detail contextual action to present sheet with correct launch context. Ensured selection/default policies and anchored-vs-unanchored behavior align with contract assertions.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {
        "command": "xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination \"platform=macOS,arch=arm64\" -only-testing:\"OpenBurnBarTests/ContextPackDashboardSurfaceTests\" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO",
        "exitCode": 0,
        "observation": "Dashboard surface tests passed."
      },
      {
        "command": "xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination \"platform=macOS,arch=arm64\" -only-testing:\"OpenBurnBarTests/ContextPackSessionDetailSurfaceTests\" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO",
        "exitCode": 0,
        "observation": "Session detail surface tests passed."
      },
      {
        "command": "xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination \"platform=macOS,arch=arm64\" -only-testing:\"OpenBurnBarTests/ContextPackCrossFlowTests\" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO",
        "exitCode": 0,
        "observation": "Cross-flow tests passed."
      }
    ],
    "interactiveChecks": []
  },
  "tests": {
    "added": [
      {
        "file": "AgentLensTests/Active/ContextPackDashboardSurfaceTests.swift",
        "cases": [
          {
            "name": "test_dashboardContextPackCTA_presentsContextPackSheet",
            "verifies": "dashboard entry point opens Context Pack sheet"
          },
          {
            "name": "test_charBudgetIndicator_warningAboveThreshold",
            "verifies": "warning state appears above 16k UI threshold"
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

- Required UI assertions cannot be implemented without changing out-of-scope navigation architecture.
- Existing shared components force contract-breaking behavior and require broader design decision.
- Test harness gaps prevent validating required UI assertions.
