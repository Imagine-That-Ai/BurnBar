# User Testing

## Validation Surface

### Surface MC-DAEMON: Daemon API mission-control runtime
- Scope: mission creation/approval/dispatch/result, planner input contracts, DAG/reconciliation, recovery/takeover, policy/connector governance.
- Primary tools:
  - `swift test --package-path OpenBurnBarDaemon --filter BurnBarMissionControlServiceTests`
  - `swift test --package-path OpenBurnBarDaemon --filter BurnBarRunServiceTests`
  - `swift test --package-path OpenBurnBarDaemon --filter BurnBarDaemonServerTests`
  - `swift test --package-path OpenBurnBarCore --filter BurnBarMissionControlContractsTests`
  - For assertion-targeted reruns, prefer assertion-ID filter names (for example `--filter VAL_DAEMON_003`) when a suite-level filter yields 0 tests.

### Surface MC-APP: macOS app operator surfaces
- Scope: mission authoring affordances, mission board, inbox triage, brief completeness, one-question top-level UX, re-entry controls, degraded runtime messaging.
- Primary tool:
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/OpenBurnBarOperatingComposerTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`

### Surface MC-EXT: Extension bridge/operator surface
- Scope: daemon connection lifecycle, arbitration/reconnect, mission parity, mission closure evidence, operator actions, extension-host integration.
- Primary tools:
  - `npm --prefix extensions/openburnbar run test:unit -- test/controller.test.ts test/projections.test.ts test/workspacePanel.test.ts test/extension.test.ts`
  - `./scripts/test-openburnbar-extension-host.sh`

### Surface MC-CROSS: End-to-end convergence and real-integration assertions
- Scope: one-line mission closure flow, done-or-one-question invariant, cross-surface parity mapping, scheduled reviews/notifications convergence, enterprise policy blocking.
- Primary tools:
  - Combined daemon/app/extension validators from `.factory/services.yaml`
  - `test_real_integration_smoke`

## Validation Artifact Requirements
For each validated assertion group, collect:
1. Command transcript (command + exit code)
2. Assertion-ID-tagged test/spec name(s)
3. State artifact(s) proving behavior (daemon snapshot, app snapshot, extension projection, or comparison artifact)

Cross-surface assertions require artifacts from each required surface participating in the assertion.

## Validation Concurrency
Resource classification from dry-run profiling:
- App surface validators (`xcodebuild`): **max 1 concurrent**
- Daemon surface validators (`swift test` mission/runtime): **max 5 concurrent**
- Extension surface validators (`npm/vitest`): **max 5 concurrent**

Rule: when assertions combine surfaces, overall concurrency is constrained by the tightest participating surface (usually app=1).

## Validation Readiness (latest)
- Daemon smoke: runnable
- App UI smoke: runnable
- Extension bridge smoke: runnable
- No blockers identified during dry-run readiness checks

## Accepted Constraints
- Real integrations only for mission-critical paths (dispatch/recovery/reconciliation/PR lifecycle).
- If an external integration is unavailable, validation must fail with explicit reason and return to orchestrator; do not silently substitute mocks.

## Flow Validator Guidance: MC-DAEMON
- Isolation boundary: test only daemon mission-control assertions assigned in your prompt.
- Allowed commands: `swift test --package-path OpenBurnBarDaemon --filter BurnBarMissionControlServiceTests` plus read-only artifact collection.
- Do not modify app/extension code, global system settings, or unrelated test fixtures.
- Keep evidence scoped to the assigned assertion IDs and write outputs only under the provided flow report/evidence directories.

## Flow Validator Guidance: MC-APP
- Isolation boundary: test only the assigned app-surface assertions against `OpenBurnBarOperatingComposerTests`.
- Allowed command family: `xcodebuild test ... -only-testing:"OpenBurnBarTests/OpenBurnBarOperatingComposerTests"` with optional narrowing to assertion-tagged test names.
- Run app validators serially (`max 1`) to avoid `xcodebuild` contention in shared DerivedData/SPM caches.
- If an initial run fails with a transient index-store write/rename error in DerivedData, retry the same command once before classifying as blocked.
- Do not mutate daemon fixtures, extension tests, or global machine settings; write only flow JSON and evidence files under the assigned milestone paths.
