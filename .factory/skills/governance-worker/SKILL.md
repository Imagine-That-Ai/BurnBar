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
   - `swift test --package-path OpenBurnBarCore --filter BurnBarMissionControlContractsTests`
   - `swift test --package-path OpenBurnBarDaemon --filter BurnBarMissionControlServiceTests`
   - `swift test --package-path OpenBurnBarDaemon --filter BurnBarDaemonServerTests`
   - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/OpenBurnBarOperatingComposerTests"`
   - `npm --prefix extensions/openburnbar run test:unit -- test/projections.test.ts test/extension.test.ts`

   **Mission-scoped validation-contract path:** Each mission's validation contract lives at `{missionDir}/validation-contract.md` (e.g., `~/.factory/missions/{missionId}/validation-contract.md`). The canonical test filter names (e.g., `BurnBarMissionControlContractsTests`) are defined in `.factory/services.yaml` and match the actual XCTest target class names.

   **CI fallback for app test execution:** When running the full app test suite, use `CI=true scripts/test-openburnbar-app.sh` to enable headless/CI-appropriate test execution. Without the `CI=true` prefix, the script may attempt GUI-interactive test modes unsuitable for CI environments.

6. **Evidence rigor for handoff finalization:**
   - **verificationStep coverage:** For every verificationStep in the feature definition, record the actual command output and observed result as evidence in `commandsRun`. Each verificationStep must have at least one corresponding command run with its exit code and observation.
   - **fulfilled assertion surface coverage:** For every assertion ID listed in `fulfills`, confirm the surface(s) it targets (daemon/core/app/extension) and include evidence from each surface. If an assertion spans multiple surfaces (e.g., VAL-CROSS- assertions), evidence from ALL surfaces is required before handoff.
   - **Daemon + extension host parity checks:** For cross-surface assertions, run `swift test --package-path OpenBurnBarDaemon --filter BurnBarDaemonServerTests` AND `./scripts/test-openburnbar-extension-host.sh` and include both outputs in handoff evidence.
   - **Explicit invariant checks:** In the handoff `verification.commandsRun`, explicitly note which assertions are verified by each command and confirm all `fulfills` IDs have corresponding evidence.

## Example Handoff
```json
{
  "salientSummary": "Implemented mission-scoped closure-question uniqueness and enterprise policy blocks with cross-surface reason-code parity.",
  "whatWasImplemented": "Added mission-scoped closure question dedupe/reject semantics, typed enterprise policy config with budget and approval modes, scheduled review generation metadata, and reason-code projection mapping used by app and extension parity views.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {
        "command": "swift test --package-path OpenBurnBarDaemon --filter BurnBarMissionControlServiceTests",
        "exitCode": 0,
        "observation": "Governance invariants and scheduling tests passed. Covers VAL-GOV-001, VAL-GOV-002, VAL-GOV-006, VAL-GOV-008, VAL-GOV-010."
      },
      {
        "command": "swift test --package-path OpenBurnBarDaemon --filter BurnBarDaemonServerTests",
        "exitCode": 0,
        "observation": "Connector and server contract parity tests passed. Covers VAL-GOV-003."
      },
      {
        "command": "xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination \"platform=macOS,arch=arm64\" -only-testing:\"OpenBurnBarTests/OpenBurnBarOperatingComposerTests\"",
        "exitCode": 0,
        "observation": "App surface governance UI tests passed."
      },
      {
        "command": "npm --prefix extensions/openburnbar run test:unit -- test/projections.test.ts test/extension.test.ts",
        "exitCode": 0,
        "observation": "Extension projection parity tests passed. Covers VAL-EXT-007, VAL-EXT-008."
      },
      {
        "command": "./scripts/test-openburnbar-extension-host.sh",
        "exitCode": 0,
        "observation": "Extension host integration smoke passed. Covers VAL-CROSS-010 parity between app and extension authoring."
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
            "verifies": "Exactly one closure approval question invariant (VAL-GOV-006)"
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

**Evidence rigor requirements for handoff:**
- Every `verificationStep` from the feature definition must appear in `verification.commandsRun` with exit code and concrete observation.
- Every `fulfills` assertion ID must be listed in at least one command's observation field.
- Cross-surface assertions (VAL-CROSS-*, VAL-EXT-*) require evidence from ALL listed surfaces (daemon + app + extension).
- For daemon + extension parity: run BOTH `swift test --package-path OpenBurnBarDaemon --filter BurnBarDaemonServerTests` AND `./scripts/test-openburnbar-extension-host.sh` and include both outputs.

## When to Return to Orchestrator
- Governance rule conflicts require product/policy decision (for example precedence between budget cap and approval mode).
- Real connector integration required for validation is unavailable.
- Invariant enforcement requires migration strategy that could break existing persisted mission data.

commands:
  install: ./.factory/init.sh
  typecheck: xcodebuild build-for-testing -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -clonedSourcePackagesDirPath .spm-cache -derivedDataPath .derived-data/ci-typecheck CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
  lint: npm --prefix extensions/openburnbar run lint
  test: scripts/test-openburnbar-swift.sh && CI=true scripts/test-openburnbar-app.sh && scripts/test-openburnbar-ts.sh
  test_daemon_mission: swift test --package-path OpenBurnBarDaemon --filter BurnBarMissionControlServiceTests
  test_daemon_runtime: swift test --package-path OpenBurnBarDaemon --filter BurnBarRunServiceTests
  test_daemon_rpc: swift test --package-path OpenBurnBarDaemon --filter BurnBarDaemonServerTests
  test_core_contracts: swift test --package-path OpenBurnBarCore --filter BurnBarMissionControlContractsTests
  test_router: swift test --package-path OpenBurnBarDaemon --filter BurnBarProviderRouterTests
  test_app_operating: xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/OpenBurnBarOperatingComposerTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''
  test_extension_unit: npm --prefix extensions/openburnbar run test:unit -- test/controller.test.ts test/projections.test.ts test/workspacePanel.test.ts test/extension.test.ts
  test_extension_host: ./scripts/test-openburnbar-extension-host.sh
  test_real_integration_smoke: ./scripts/test-openburnbar-extension-host.sh && swift test --package-path OpenBurnBarDaemon --filter BurnBarDaemonServerTests
  build: scripts/build.sh --build --configuration Debug --cache-dir .spm-cache --derived-data .derived-data/ci-build

services: {}
