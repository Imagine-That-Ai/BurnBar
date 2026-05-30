# Daemon

The OpenBurnBar daemon is the local background process that owns provider routing, mission control, run state, the connector plane, and the browser plane. It runs persistently on macOS and communicates with the native app over a Unix domain socket.

**Support tier:** Core (provider routing, run state); Experimental (mission control, connector plane, browser plane).

---

## Purpose

The daemon is the control plane for AI agent execution. It:

- Routes requests to the correct provider (Anthropic, OpenAI, Grok, Factory, etc.) and applies cost/routing policies
- Manages the full lifecycle of agent runs — queuing, execution, resume, and failure recovery
- Maintains a run journal and checkpoint files for durable state across restarts
- Hosts the connector plane for six external services (GitHub, Slack, Linear, PostHog, Sentry, Gmail)
- Hosts the browser plane for daemon-side fetch and system-browser launch
- Exposes the mission control runtime: project registry, question/followup workflows, mission dispatch, simulator/replay
- Bridges to the mobile app via iroh P2P transport

---

## Directory layout

The daemon package lives at `OpenBurnBarDaemon/` and is defined in `OpenBurnBarDaemon/Package.swift`.

```
OpenBurnBarDaemon/Sources/
├── OpenBurnBarDaemon/          # Library target — all daemon logic
│   ├── MissionControl/         # Mission control runtime (service, store, scheduler, etc.)
│   ├── ComputerUse/            # Computer Use coordinator (phase 8-13)
│   ├── OpenBurnBarDaemonServer.swift       # JSON-RPC server actor
│   ├── OpenBurnBarProviderRouter.swift     # Provider routing engine
│   ├── OpenBurnBarRunService.swift         # Run lifecycle state machine
│   ├── OpenBurnBarRunJournal.swift         # Durable run journal (JSONL)
│   ├── OpenBurnBarConnectorPlaneService.swift
│   ├── OpenBurnBarBrowserToolService.swift
│   ├── OpenBurnBarConfigStore.swift        # Provider config + routing config
│   └── ...
├── OpenBurnBarDaemonExecutable/  # Entry point — links OpenBurnBarDaemon
├── OpenBurnBarCLI/               # CLI binary — operator commands
├── OpenBurnBarRemoteAccessAgent/ # Remote-access agent executable
├── OpenBurnBarRemoteAccessAgentCore/ # Shared library for remote-access agent
└── OpenBurnBarVirtualHIDBridge/  # Virtual HID bridge for Computer Use
```

Six build targets:

| Target | Type | Role |
|---|---|---|
| `OpenBurnBarDaemon` | Library | All daemon logic and RPC handlers |
| `OpenBurnBarDaemonExecutable` | Executable | Entry point; links the library |
| `OpenBurnBarCLI` | Executable | CLI operator surface |
| `OpenBurnBarRemoteAccessAgentCore` | Library | Shared remote-access protocol types |
| `OpenBurnBarRemoteAccessAgent` | Executable | Remote access agent (ApplicationServices/IOKit) |
| `OpenBurnBarVirtualHIDBridge` | Executable | Virtual HID input bridge (CoreGraphics/IOKit) |

---

## JSON-RPC server

The daemon exposes a Unix domain socket RPC server implemented in `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift`.

**Socket path:** `~/Library/Application Support/OpenBurnBar/openburnbar-daemon.sock`  
(constant `BurnBarDaemonPaths.defaultSocketPath` in `OpenBurnBarDaemonConfiguration.swift`)

**Auth:** Every request must carry a Keychain-backed auth token. The daemon refuses to start without one — see `BurnBarDaemonConfiguration.validate()`. The macOS app generates and passes the token automatically.

**Rate limit:** 60 req/s sustained, 100 burst (configurable via `BurnBarRateLimitConfiguration`).

**launchd installation:** The macOS app installs the daemon as a launchd agent so it persists across logins. The support directory (`~/Library/Application Support/OpenBurnBar/`) is the canonical root for all daemon-owned state files.

---

## Key subsystems

### Provider routing

`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarProviderRouter.swift` (~79 KB) selects the provider and model for each request based on configured routing policy, per-model health scores, and budget enforcement. Provider executors (`OpenBurnBarProviderExecutor.swift`, `OpenBurnBarAnthropicProviderExecutor.swift`, `FactoryDroidProviderExecutor.swift`, etc.) translate the routed request into provider-specific wire calls.

### Run service and journal

`OpenBurnBarRunService.swift` drives the full run lifecycle — start, execute, stream, finish, and recover. Execution detail is in `BurnBarRunService+Execution.swift`; tool dispatch in `BurnBarRunService+ToolDispatch.swift`.

The run journal (`OpenBurnBarRunJournal.swift`) appends events to `~/Library/Application Support/OpenBurnBar/run-journal.jsonl`. Checkpoints and routing decision events land in the same support directory (`run-journal.jsonl`, `provider-routing-decisions.jsonl`).

### Connector plane

`OpenBurnBarConnectorPlaneService.swift` manages durable connections to:

- GitHub, Slack, Linear, PostHog, Sentry, Gmail

Credentials are stored in the local Keychain via `OpenBurnBarConnectorSecretStore.swift`. Current supported actions are `test_connection` and `sample_request` per connector. Broader actions will ship when the interaction model stabilises.

### Browser plane

`OpenBurnBarBrowserToolService.swift` provides daemon-side HTTP fetch, document extraction, link extraction, and system-browser launch. Playwright and Lightpanda are detected and surfaced as status/setup engines; full headless automation runs through the daemon fetcher path in this release.

### Mission control

See [`mission-control.md`](./mission-control.md) for the full breakdown. Entry point: `MissionControl/MissionControlService.swift`.

### Computer Use

`ComputerUse/` coordinates the Computer Use phases (8–13): Agent Watch (screen mirror), browser plane, trust modes, Mac system input, phone-as-controller, and audit chain. See `docs/HERMES_COMPUTER_USE.md` and `plans/2026-05-16-computer-use-master-plan.md`.

---

## Daemon support directory

`~/Library/Application Support/OpenBurnBar/` (overridable via `OPENBURNBAR_DAEMON_SUPPORT_DIR`):

| File | Owned by | Purpose |
|---|---|---|
| `openburnbar-daemon.sock` | Daemon | Unix socket |
| `provider-config.json` | Daemon | Provider routing config |
| `provider-secrets.continuity.json` | Daemon | Provider key continuity |
| `usage-events.jsonl` | Daemon | Usage ledger |
| `run-journal.jsonl` | Daemon | Run events |
| `provider-routing-decisions.jsonl` | Daemon | Routing audit log |
| `gateway-model-health.json` | Daemon | Per-model health state |

Local SQLite (owned by the app, not the daemon) is the canonical store for usage history, conversations, and retrieval. See [Local database](../local-database/index.md).

---

## CLI entrypoints

Build and run with:

```bash
swift run --package-path OpenBurnBarDaemon OpenBurnBarCLI -- help
```

Available commands (from `OpenBurnBarCLI.swift`):

| Command | Description |
|---|---|
| `health` | Daemon health and version |
| `controller [projectSlug]` | Controller summary for a project |
| `questions [projectSlug]` | Pending questions |
| `followups [projectSlug]` | Pending followups |
| `missions [projectSlug]` | Mission list |
| `mission-approve <missionID> [note]` | Approve a mission |
| `simulator-runs [projectSlug]` | List simulator run snapshots |
| `simulator-replay <runID>` | Replay a simulator run |

---

## Integration points

| Surface | Transport | Notes |
|---|---|---|
| macOS app | JSON-RPC over Unix socket | App is the RPC client; daemon is server |
| Cursor / VS Code extension | JSON-RPC over Unix socket | Extension reads health, run state, catalog |
| Mobile (iOS/Android) | iroh P2P (Ed25519) | Computer Use screen mirror; mercury media transport |
| Cloud Functions | Firestore (optional) | Replication plane only — not canonical |
