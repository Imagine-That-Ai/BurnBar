# BurnBar Cursor Agent Implementation Checklist

## Purpose

This document turns the reviewed architecture into an execution sequence that can actually ship.

Rules for this build:

- BurnBar is the product name in all new work.
- The daemon is the source of truth.
- The app is a client of the daemon, not a second control plane.
- Provider/model/pricing truth lives in one shared catalog.
- Tool schemas and approval policy live in one shared contract.
- BurnBar should stay local-first.
- Do not add a second search/index subsystem in v1.

Agent assignment matrix:

- [BURNBAR_AGENT_ASSIGNMENT_MATRIX.md](./BURNBAR_AGENT_ASSIGNMENT_MATRIX.md)
- [BURNBAR_SUBAGENT_PROMPTS.md](./BURNBAR_SUBAGENT_PROMPTS.md)

Current release docs:

- [BURNBAR_CURSOR_AGENT_ONBOARDING.md](./BURNBAR_CURSOR_AGENT_ONBOARDING.md)
- [BURNBAR_RELEASE_ARCHITECTURE.md](./BURNBAR_RELEASE_ARCHITECTURE.md)

## Target Repo Shape

The exact final paths can change, but the shape should look like this:

```text
docs/
  BURNBAR_CURSOR_AGENT_SPEC.md
  BURNBAR_IMPLEMENTATION_CHECKLIST.md

BurnBarApp/                  # existing macOS app target after rebrand
BurnBarCore/                 # shared Swift package
BurnBarDaemon/               # local daemon target/binary
extensions/burnbar/          # Cursor/VS Code extension package

legacy/                      # only if needed for migration helpers/scripts
```

Minimum expectation:

- one shared Swift package
- one daemon target
- one extension package
- no duplicate provider/tool contract definitions across app/daemon/extension

## Demo Definition

The first real BurnBar demo is complete when all of these are true:

- User opens BurnBar and pastes Z.ai or MiniMax keys.
- BurnBar daemon is installed and healthy.
- User opens Cursor and sees a BurnBar sidebar.
- User starts a run with a supported model.
- BurnBar can read files, search workspace, apply edits, and run a terminal command.
- Approval is required for approval-gated actions.
- Cancelling and retrying a run works.
- Closing and reopening Cursor reconnects to the same daemon-owned run state.
- BurnBar usage/accounting reflects the run.

## PR 1: Rebrand + Identity Migration

Goal: make BurnBar the visible product and avoid stranding legacy local data.

### Build

- [x] Rename user-visible strings from `AgentLens` to `BurnBar`.
- [x] Rename app/window titles, onboarding copy, settings copy, dashboard copy, connector copy, notifications, and accessibility labels.
- [x] Update build identity in `project.yml`:
- [x] project name
- [x] target names
- [x] `PRODUCT_NAME`
- [x] bundle IDs
- [x] entitlements references
- [x] Regenerate Xcode project from `project.yml`.
- [x] Add a migration layer for legacy app support paths and local database location.
- [x] Add a migration layer for legacy keychain service identifiers.
- [x] Add a migration layer for legacy `UserDefaults` domains and device identifiers.
- [x] Keep migration code explicit and idempotent.

### Acceptance

- [x] Fresh install shows BurnBar everywhere user-facing.
- [x] Existing local data from the old app identity is still visible after upgrade.
- [x] Existing secrets continue to resolve after upgrade.

### Tests

- [x] migration test for app support directory move or alias
- [x] migration test for keychain lookup fallback
- [x] smoke build after `project.yml` rename

## PR 2: Add BurnBarCore

Goal: create one shared contract layer before daemon and extension code diverge.

### Build

- [x] Add a local Swift package named `BurnBarCore`.
- [x] Move shared provider/model/pricing metadata contract into BurnBarCore.
- [x] Add shared RPC request/response/event types.
- [x] Add shared tool contract types.
- [x] Add shared approval contract types.
- [x] Add shared run-state machine types.
- [x] Add client/session identity types.
- [x] Add protocol version constant and version negotiation types.

### Catalog

- [x] Add one checked-in canonical catalog file.
- [x] Catalog must include:
- [x] provider IDs
- [x] display names
- [x] base URLs
- [x] supported models
- [x] visibility flags
- [x] pricing
- [x] capability flags if needed
- [x] Add Swift loader + validation for the catalog.

### Acceptance

- [x] App reads the shared catalog through BurnBarCore.
- [x] Daemon target reads the same catalog through BurnBarCore.
- [x] No second handwritten provider/model/pricing table exists in Swift.

### Tests

- [x] BurnBarCore schema decode tests
- [x] catalog validation tests
- [x] protocol version tests

## PR 3: Daemon Bootstrap + launchd

Goal: get a real local control plane online before building full agent behavior.

### Build

- [x] Add `BurnBarDaemon` target/binary.
- [x] Add Unix domain socket bootstrap.
- [x] Add daemon health endpoint/event.
- [x] Add structured daemon logging.
- [x] Add stale socket cleanup on boot.
- [x] Add per-user `launchd` LaunchAgent install path.
- [x] Add install / repair / uninstall commands callable from the app.
- [x] Add daemon version reporting.

### Acceptance

- [x] BurnBar app can install and start the daemon.
- [x] BurnBar app can detect daemon unhealthy state and repair it.
- [x] Daemon survives app closure.

### Tests

- [x] daemon boot/shutdown test
- [x] stale socket cleanup test
- [x] version mismatch test
- [x] app-to-daemon health smoke test

## PR 4: ConfigStore + Provider Router + Usage Recorder

Goal: move current provider routing/accounting behavior into daemon-owned services.

### Build

- [x] Add `ConfigStore` service in daemon.
- [x] Move provider config loading/saving behind the store.
- [x] Move secret lookup behind a dedicated secret provider abstraction.
- [x] Add `ProviderRouter` using the shared catalog.
- [x] Support Z.ai and MiniMax only.
- [x] Exclude Kimi and `pony-alpha-2`.
- [x] Add structured usage events emitted by the daemon.
- [x] Add `UsageRecorder` integration back into BurnBar’s local data store.
- [x] Remove inline provider/model logic duplication where possible.

### Migration from current code

- [x] Audit [CursorConnectorManager.swift](/Users/albertonunez/Developer/AgentLens/AgentLens/Services/CursorConnector/CursorConnectorManager.swift) and move reusable routing/accounting logic into daemon services.
- [x] Do not copy its singleton/god-object shape forward.

### Acceptance

- [x] Daemon can route supported model calls without the old quick-tunnel architecture.
- [x] Usage appears in BurnBar after daemon-routed model calls.

### Tests

- [x] router model-selection tests
- [x] accounting idempotency tests
- [x] provider auth/config tests

## PR 5: Cursor Extension Shell

Goal: get BurnBar visible and connected inside Cursor with no workspace tools yet.

### Build

- [x] Add `extensions/burnbar/` package.
- [x] Add local UI extension entrypoint.
- [x] Add BurnBar activity-bar container or equivalent view container.
- [x] Add daemon connection client over Unix socket.
- [x] Add health view.
- [x] Add reconnect / repair actions.
- [x] Add run list skeleton backed by daemon state.
- [x] Add run detail skeleton backed by daemon state.

### Acceptance

- [x] BurnBar sidebar opens inside Cursor.
- [x] Extension can show connected/disconnected daemon state.
- [x] Extension can reconnect after daemon restart.

### Tests

- [x] TS unit tests for daemon client
- [x] extension activation test
- [x] extension health UI test

## PR 6: Workspace Companion + Cross-Host Bridge

Goal: create the execution adapter that can operate where the workspace lives.

### Build

- [x] Add workspace companion activation path in the same extension package.
- [x] Add private command-based RPC between UI host and workspace host.
- [x] Add capability reporting:
- [x] local workspace
- [x] remote workspace
- [x] readonly workspace
- [x] virtual workspace
- [x] untrusted workspace
- [x] Add tool adapters for:
- [x] `read_file`
- [x] `search_workspace`
- [x] `apply_patch`
- [x] `run_terminal`

### Workspace Trust

- [x] Add explicit extension manifest trust declaration.
- [x] Disable trust-sensitive tools in restricted mode.
- [x] Show user-facing explanation for gated features.

### Acceptance

- [x] Local workspace tool calls succeed through the companion.
- [x] Restricted workspaces clearly gate unsafe tools.
- [x] Remote workspace path is structurally wired even if some features are still limited.

### Tests

- [x] cross-host command RPC tests
- [x] workspace capability tests
- [x] trust gating tests
- [x] local workspace integration test
- [x] remote/workspace-host integration test

## PR 7: Run Service + Approvals + Arbitration

Goal: make the daemon a real multi-client agent control plane.

### Build

- [x] Add `RunService`.
- [x] Implement the BurnBarCore run-state machine in the daemon.
- [x] Add approval requests/responses.
- [x] Add cancel/retry/resume behavior.
- [x] Add client registry.
- [x] Add client lease / ownership semantics.
- [x] Add observer vs controlling-client distinction.
- [x] Add explicit takeover behavior for conflicting clients.
- [x] Add reconnect logic for extension reloads and app restarts.

### Acceptance

- [x] Approval-required actions pause correctly.
- [x] Retry works after a tool or model failure.
- [x] Cancel works mid-run.
- [x] Reopening Cursor reconnects to the existing run.
- [x] Two clients cannot silently stomp the same run.

### Tests

- [x] table-driven run-state transition tests
- [x] approval-state tests
- [x] retry/cancel/resume tests
- [x] multi-client arbitration tests
- [x] reconnect tests

## PR 8: BurnBar App as Daemon Client

Goal: finish the app-side control surface on top of the daemon, not beside it.

### Build

- [x] Move relevant settings UI to daemon-backed state where needed.
- [x] Show daemon health in the app.
- [x] Show provider/model config from daemon-backed store.
- [x] Show recent routed usage and daemon events.
- [x] Add daemon repair actions in the app.
- [x] Remove or shrink app-side logic that duplicated daemon responsibilities.

### Acceptance

- [x] BurnBar app reflects live daemon state.
- [x] App can repair daemon issues without manual terminal work.
- [x] Provider/model settings remain local and usable.

### Tests

- [x] app integration tests for daemon-backed health/config
- [x] manual smoke test for app + extension + daemon together

## PR 9: Replay Evals + Extension-Host Integration Harness

Goal: make prompt/tool behavior regression-resistant.

### Build

- [x] Add replay eval suite for planner behavior.
- [x] Add replay eval suite for approval triggering.
- [x] Add replay eval suite for local vs remote routing.
- [x] Add replay eval suite for repair/recovery messaging.
- [x] Add extension-host integration harness using official VS Code extension test tooling.
- [x] Add CI entrypoints for:
- [x] Swift tests
- [x] TS tests
- [x] extension-host tests
- [x] replay evals

### Acceptance

- [x] Prompt/tool regressions fail CI.
- [x] Extension flows are not manual-test-only.

### Tests

- [x] golden replay tests
- [x] local workspace extension-host test
- [x] remote/workspace-host extension-host test

## PR 10: First Public BurnBar Agent Release

Goal: polish the first version into something demoable and publishable.

### Build

- [x] Add empty/error states for all major BurnBar extension panels.
- [x] Add repair/recovery copy for common daemon failures.
- [ ] Add telemetry or local diagnostics only if still consistent with local-first positioning.
- [x] Update docs and onboarding around BurnBar + Cursor agent flow.
- [x] Document supported providers and unsupported cases.
- [x] Document trust/restricted-mode behavior.
- [x] Add a concise release-facing doc for the current shipped architecture and test entrypoints.

### Acceptance

- [x] New user can install BurnBar, connect Cursor, and complete a real coding task.
- [x] Main failure cases have visible recovery paths.

### Tests

- [x] final smoke test matrix
- [x] install/upgrade test
- [x] migration regression test

## Cross-PR Rules

- [x] Do not introduce a second handwritten provider/model/pricing registry.
- [x] Do not keep authoritative run state in the extension.
- [x] Do not let the daemon directly patch workspace files.
- [x] Do not skip Workspace Trust behavior.
- [x] Do not leave multi-client ownership implicit.
- [x] Do not silently break legacy local data during rebrand.

## Release Gates

Before calling BurnBar agent v1 done:

- [x] BurnBar branding is user-visible everywhere that matters.
- [x] Legacy local data still migrates correctly.
- [x] Daemon survives app closure.
- [x] Extension reconnects after Cursor reload.
- [x] Approval flow works.
- [x] Cancel/retry works.
- [x] Local workspace tools work.
- [x] Restricted mode degrades safely.
- [x] Remote workspace path is tested.
- [x] Usage/accounting is recorded.
- [x] Replay evals are green.
- [x] Extension-host integration tests are green.

## Nice-to-Have After v1

- Browser tools
- More providers
- Multi-agent runs
- Cloud relay or hosted control plane
- Cross-platform daemon support
