# RPC surface

`OpenBurnBarDaemon` exposes two communication surfaces: a **Unix-domain JSON-RPC socket** for the macOS app and CLI, and an **HTTP gateway** for the VS Code/Cursor extension and browser-based clients.

## Unix domain socket

| Property | Value |
|----------|-------|
| Path | `~/.burnbar.sock` |
| Permissions | `0o600` (owner-only) |
| Protocol | JSON-RPC 2.0, newline-delimited |
| Auth | Keychain-backed token sent as the first line after connect |

The daemon creates the socket on launch and removes it on clean shutdown. If the socket already exists, the daemon replaces it. The macOS app, CLI, and VS Code/Cursor extension all connect through this socket.

### Authentication

The client reads a short-lived token from the macOS Keychain (`service: com.openburnbar.daemon.token`) and sends it as the first line after connecting. The daemon rejects connections with invalid or missing tokens.

### Request envelope

```json
{"jsonrpc": "2.0", "method": "daemon.health", "params": {}, "id": 1}
```

Responses follow standard JSON-RPC 2.0: `result` on success, `error` with `code` and `message` on failure.

## JSON-RPC methods

Methods are defined in `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarRPCContracts.swift` as `BurnBarRPCMethod` and dispatched by category in `BurnBarDaemonServer`.

### Lifecycle

| Method | Key | Description |
|--------|-----|-------------|
| `health` | `daemon.health` | Returns daemon version, uptime, and connection status |
| `catalog` | `daemon.catalog` | Returns the full daemon configuration catalog |
| `authBootstrap` | `auth.bootstrap` | Bootstraps a new client connection with token exchange (must be called via `BurnBarDaemonAuthManager`, not direct socket) |

### Client registry

| Method | Key | Description |
|--------|-----|-------------|
| `clientAttach` | `client.attach` | Registers a new client (macOS app, CLI, or extension) |
| `clientDetach` | `client.detach` | Unregisters a client |
| `clientClaimControl` | `client.claimControl` | Claims exclusive control of the daemon session |

### Configuration

| Method | Key | Description |
|--------|-----|-------------|
| `configGet` | `daemon.config.get` | Returns the current daemon configuration snapshot |
| `configUpdate` | `daemon.config.update` | Replaces the full configuration snapshot |
| `providerCredentialSlotUpsert` | `daemon.provider.credential_slot.upsert` | Adds or updates a provider API key slot |
| `providerCredentialSlotRemove` | `daemon.provider.credential_slot.remove` | Removes a provider credential slot |
| `providerModelVariantUpsert` | `daemon.provider.model_variant.upsert` | Adds or updates a model variant |
| `providerModelVariantRemove` | `daemon.provider.model_variant.remove` | Removes a model variant |
| `providerModelAliasUpsert` | `daemon.provider.model_alias.upsert` | Adds or updates a model alias |
| `providerModelAliasRemove` | `daemon.provider.model_alias.remove` | Removes a model alias |
| `providerModelDisplayNameSet` | `daemon.provider.model_display_name.set` | Sets a display name override |
| `providerModelDisplayNameClear` | `daemon.provider.model_display_name.clear` | Clears a display name override |

### Search

| Method | Key | Description |
|--------|-----|-------------|
| `searchQuery` | `daemon.search.query` | Executes a full-text or semantic search against the local index |

### Usage

| Method | Key | Description |
|--------|-----|-------------|
| `usageRecent` | `daemon.usage.recent` | Returns recent usage events from local SQLite |
| `usageRecord` | `daemon.usage.record` | Records a new usage event with idempotency key |

### Tooling (Connectors & Browser)

| Method | Key | Description |
|--------|-----|-------------|
| `connectorPlaneGet` | `daemon.connector.plane.get` | Returns the current connector plane snapshot (Cursor, etc.) |
| `connectorConfigUpdate` | `daemon.connector.config.update` | Updates connector configuration |
| `connectorAction` | `daemon.connector.action` | Performs a connector action |
| `browserToolingGet` | `daemon.browser.tooling.get` | Returns Playwright/Chromium browser tooling state |
| `browserToolingUpdate` | `daemon.browser.tooling.update` | Updates browser tooling configuration |
| `browserAction` | `daemon.browser.action` | Executes a browser action (goto, click, fill, screenshot, etc.) |

### Run / Workspace / Approval

| Method | Key | Description |
|--------|-----|-------------|
| `runCreate` | `run.create` | Creates a new agent run |
| `runList` | `run.list` | Lists recent runs |
| `runGet` | `run.get` | Retrieves a single run by ID |
| `runPoll` | `run.poll` | Polls run status for live updates |
| `runCancel` | `run.cancel` | Cancels an active run |
| `runRetry` | `run.retry` | Retries a failed run |
| `runResume` | `run.resume` | Resumes a paused run from local SQLite state |
| `workspaceExecuteTool` | `workspace.executeTool` | Executes a workspace tool (bash, file ops, etc.) |
| `workspaceToolResult` | `workspace.toolResult` | Submits a tool result back to the run orchestrator |
| `approvalRespond` | `approval.respond` | Responds to a pending approval request |

### Mission Control

| Method | Key | Description |
|--------|-----|-------------|
| `controllerSummary` | `daemon.controller.summary` | Returns the active controller state summary |
| `controllerProjectsList` | `daemon.controller.project.list` | Lists controller projects |
| `controllerProjectGet` | `daemon.controller.project.get` | Retrieves a single project |
| `controllerProjectUpsert` | `daemon.controller.project.upsert` | Creates or updates a project |
| `reviewRunRecord` | `daemon.controller.review.record` | Records a run review |
| `questionCreate` | `daemon.question.create` | Creates a new operator question |
| `questionGet` | `daemon.question.get` | Retrieves a question by ID |
| `questionsList` | `daemon.question.list` | Lists all pending and answered questions |
| `questionAnswer` | `daemon.question.answer` | Submits an answer to a question |
| `followupCreate` | `daemon.followup.create` | Creates a follow-up prompt |
| `followupsList` | `daemon.followup.list` | Lists follow-ups |
| `followupDone` | `daemon.followup.done` | Marks a follow-up as resolved |
| `followupSnooze` | `daemon.followup.snooze` | Snoozes a follow-up |
| `followupCalendar` | `daemon.followup.calendar` | Schedules a follow-up on the calendar |
| `missionCreate` | `daemon.mission.create` | Creates a new mission |
| `missionsList` | `daemon.mission.list` | Lists missions (supports filtering by status) |
| `missionGet` | `daemon.mission.get` | Retrieves a mission by ID |
| `missionApprove` | `daemon.mission.approve` | Approves a pending mission or mission step |
| `missionCancel` | `daemon.mission.cancel` | Cancels a mission |
| `missionDispatchPacket` | `daemon.mission.packet.dispatch` | Dispatches a packet to a running mission |
| `missionRecordResult` | `daemon.mission.result.record` | Records a mission result |
| `simulatorRun` | `daemon.simulator.run` | Runs a simulator test |
| `simulatorList` | `daemon.simulator.list` | Lists recent simulator runs |
| `simulatorReplay` | `daemon.simulator.replay` | Replays a recorded simulator session |
| `projectionRebuild` | `daemon.projection.rebuild` | Rebuilds the local search projection index |
| `notificationConfigGet` | `daemon.notification.config.get` | Returns notification configuration |
| `notificationConfigUpdate` | `daemon.notification.config.update` | Updates notification configuration |
| `notificationHealth` | `daemon.notification.health` | Returns notification subsystem health |
| `notificationCommand` | `daemon.notification.command` | Sends a command to the notification subsystem |

### Computer Use

| Method | Key | Description |
|--------|-----|-------------|
| `computerUseSessionStart` | `daemon.computer_use.session.start` | Starts a Computer Use session |
| `computerUseInvoke` | `daemon.computer_use.invoke` | Invokes a Computer Use action |
| `computerUseApprovalPending` | `daemon.computer_use.approval.pending` | Lists pending approvals |
| `computerUseApprovalRespond` | `daemon.computer_use.approval.respond` | Responds to an approval request |
| `computerUsePanicHalt` | `daemon.computer_use.panic_halt` | Triggers the panic halt kill-switch |
| `computerUseAuditExport` | `daemon.computer_use.audit_export` | Exports the audit chain |

## Error codes

| Code | Meaning |
|------|---------|
| `-32700` | Parse error — malformed JSON |
| `-32600` | Invalid request — missing required fields |
| `-32601` | Method not found |
| `-32602` | Invalid params |
| `-32000` | Auth failure |
| `-32001` | Daemon internal error |

## Client wrappers

### `OpenBurnBarDaemonManager`

The macOS app and iOS app use `OpenBurnBarDaemonManager` (`AgentLens/Services/OpenBurnBarDaemon/`) as the high-level wrapper. It manages the socket connection, reconnection logic, client arbitration (which surface owns control), and exposes typed Swift APIs that serialize into JSON-RPC under the hood.

Key responsibilities:
- Maintains the persistent Unix socket connection to `~/.burnbar.sock`
- Handles daemon lifecycle (start, stop, restart)
- Exposes `providerConfigurations`, `routerMode`, and other live daemon state
- Used by `ProviderQuotaService`, `CLIAgentRelayChatExecutor`, and `OpenBurnBarOperatingLayer`

### VS Code / Cursor extension client

The extension (`extensions/openburnbar/src/daemon/client.ts`) connects to the same Unix socket and speaks the same JSON-RPC protocol. It implements `mission-approve` for in-editor approval flows and `questions` to surface agent questions in the sidebar panel.

## HTTP gateway

`BurnBarHTTPGatewayServer` (`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarHTTPGatewayServer.swift`) is an `actor` that implements a hand-rolled HTTP/1.1 parser on top of `Network.framework`.

| Property | Value |
|----------|-------|
| Default bind | Loopback only (`127.0.0.1`) |
| Auth | `Authorization: Bearer <token>` header |
| Use case | VS Code extension, Cursor extension, and external tool integrations |
| Security note | Non-loopback binds use plaintext TCP; TLS/mTLS is recommended for non-local usage |

The gateway exposes the same mission control, run, and approval surface over HTTP so browser-based and extension clients can participate without raw socket code.

## Quick test

```bash
# Requires the daemon to be running
echo '{"jsonrpc":"2.0","method":"daemon.health","params":{},"id":1}' | nc -U ~/.burnbar.sock
```

## Related pages

- [Configuration](configuration.md) — socket path, auth tokens, and feature flags that gate RPC methods
- [Data models](data-models.md) — request/response structs consumed by the RPC surface
- [Dependencies](dependencies.md) — `swift-protobuf`, `Network.framework`, and serialization libraries
