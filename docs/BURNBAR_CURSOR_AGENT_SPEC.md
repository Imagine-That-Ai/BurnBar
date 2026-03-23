# BurnBar Cursor Agent Spec

## Summary

BurnBar should ship its own Cursor-native agent experience instead of trying to force custom providers through Cursor's native Agent mode.

The product shape is:

```text
Cursor Extension (local UI, standard VS Code/Cursor APIs)
    |
    | Unix socket JSON-RPC
    v
BurnBar Daemon (launchd-managed, local control plane)
    |-- provider secrets
    |-- model routing
    |-- run graph / approvals / retries / cancel
    |-- client arbitration
    `-- usage accounting
    ^
    | private command RPC
    |
Workspace Companion (local or remote extension host)
    |-- read/search/edit adapters
    `-- terminal/workspace adapters
```

This is a local-first architecture. BurnBar owns the agent UX, the daemon owns execution/state, and the extension owns the editor-facing experience inside Cursor.

Implementation checklist:

- [BURNBAR_IMPLEMENTATION_CHECKLIST.md](./BURNBAR_IMPLEMENTATION_CHECKLIST.md)

## Product Goals

- Let users run Z.ai and MiniMax models inside Cursor in a way that is useful for real coding work, not just plain chat.
- Keep provider keys local and out of the extension.
- Support local workspaces first, while preserving a path for remote SSH/devcontainer workspaces.
- Reuse as much of the existing local BurnBar app infrastructure as possible.
- Make BurnBar the visible product name everywhere user-facing.

## Core Decisions

### Architecture

- BurnBar uses a separate local daemon, not an app-hosted runtime.
- The daemon is managed by `launchd` as a per-user LaunchAgent.
- The daemon speaks versioned JSON-RPC over a Unix domain socket.
- The Cursor integration is a standard extension UI, not a dependency on Cursor's AI-specific extension APIs.
- The extension ships as one package with:
  - a local UI extension host
  - a workspace companion that can run in local or remote/workspace hosts
- The daemon is the single source of truth for run state.

### Tool execution

- The daemon owns:
  - planning
  - run lifecycle
  - approvals
  - provider secrets
  - policy
  - accounting
- The workspace companion owns:
  - file reads
  - workspace search
  - edit application
  - terminal execution
  - workspace capability detection

### Shared contracts

- Provider/model/pricing metadata comes from one canonical catalog file.
- Tool schemas and approval policy come from one shared typed contract.
- BurnBarCore is the only shared Swift package required by both app and daemon.

### Performance

- Event flow is coarse-grained by default.
- Fine-grained token streaming is only for daemon-to-UI UX where it materially improves the experience.
- The existing local GRDB + FTS store remains the source for search/context in v1.

## BurnBar Components

## 1. BurnBarCore

BurnBarCore should be a small shared Swift package containing:

- catalog schema and loaders
- tool contracts
- approval contracts
- run-state types
- client/session IDs
- daemon RPC request/response/event types
- run-state machine

BurnBarCore should not contain:

- SwiftUI views
- keychain IO
- `launchd` installation logic
- Cursor/VS Code editor integration code
- network/provider client implementations

## 2. BurnBar Daemon

The daemon is the control plane.

Responsibilities:

- load provider config and secrets
- own the run graph
- select models and call upstream providers
- request tool execution from the workspace companion
- persist/replay run history
- enforce approval policy
- arbitrate between multiple connected clients
- emit accounting/usage events

Suggested internal services:

- `ConfigStore`
- `RunService`
- `ProviderRouter`
- `ClientRegistry`
- `WorkspaceBridgeClient`
- `UsageRecorder`

The daemon should not directly patch workspace files or shell into project folders. That belongs to the workspace companion.

## 3. BurnBar macOS App

The app is the local control surface.

Responsibilities:

- install/repair/remove the daemon LaunchAgent
- manage secrets in Keychain
- edit provider/model settings
- display daemon health
- display routed usage
- handle BurnBar branding and onboarding

The app should become a client of the daemon, not a second home for daemon logic.

## 4. Cursor Extension

The extension is a standard Cursor/VS Code extension, not a hook into Cursor Agent internals.

Main surfaces:

- BurnBar activity bar entry or view container
- health view
- run list/history view
- run detail panel

Current shipped shell:

- projected daemon handshake, catalog, and workspace state
- reconnect command
- refresh command
- repair daemon command

Planned after the shell release:

- start run
- retry
- cancel
- reveal approval request

The extension should declare explicit Workspace Trust behavior and degrade safely in restricted workspaces.

## 5. Workspace Companion

The workspace companion adapts BurnBar to whichever extension host actually owns the workspace.

Responsibilities:

- execute file reads with VS Code APIs
- execute search using workspace/editor APIs
- apply edits through `WorkspaceEdit`
- execute terminal commands through terminal APIs
- report capability limits:
  - readonly
  - untrusted
  - virtual workspace
  - remote workspace

The UI extension and companion communicate through private command-based RPC inside the extension package.

## RPC Boundaries

## Daemon socket protocol

Transport:

- Unix domain socket
- versioned JSON-RPC

Principles:

- typed request/response envelopes
- explicit protocol version
- no hidden side-channel state
- structured events rather than raw token/log spam

Example logical RPCs:

- `daemon.health`
- `daemon.catalog`
- `run.create`
- `run.subscribe`
- `run.cancel`
- `run.retry`
- `approval.respond`
- `client.attach`
- `client.detach`

## Extension cross-host protocol

Transport:

- private command RPC between UI host and workspace host

Principles:

- coarse-grained request/response only
- no streaming token bus between hosts
- arguments must be JSON-safe
- capability checks happen before execution

Example logical calls:

- `workspace.read`
- `workspace.search`
- `workspace.applyEdit`
- `workspace.execTerminal`
- `workspace.capabilities`

## Run-State Model

The run lifecycle should be an explicit state machine in BurnBarCore.

```text
idle
  -> planning
  -> awaiting_approval
  -> executing_tool
  -> waiting_on_companion
  -> model_streaming
  -> completed
  -> failed
  -> cancelled

awaiting_approval
  -> planning
  -> cancelled

failed
  -> planning        (retry)
  -> cancelled
```

Requirements:

- durable run IDs
- durable approval IDs
- retry semantics
- reconnect semantics
- deterministic state transitions

## Multi-Client Arbitration

Because the daemon is a shared local control plane, multi-client behavior must be explicit in v1.

Required rules:

- every client gets a stable client ID
- every run has an owning client lease
- observers can subscribe without taking control
- destructive control changes require explicit takeover
- if the owner disconnects, the daemon must define whether:
  - the run continues unattended
  - the first reconnecting client can reclaim it
  - a competing client must explicitly take control

This must be part of the RPC and state model, not an afterthought.

## Workspace Trust

BurnBar must declare and enforce trust-sensitive behavior.

Current shipped policy:

- available in restricted mode:
  - health UI
  - projected run history
  - catalog/config display
  - `read_file`
  - `search_workspace`
- gated in restricted mode:
  - `apply_patch`
  - `run_terminal`

BurnBar should provide clear user-facing explanations for why features are disabled until the workspace is trusted. If trust behavior changes later, update the extension copy, tests, and docs together.

## Shared Catalog

BurnBar should move provider/model metadata into one versioned checked-in catalog file.

The catalog should own:

- provider IDs
- display names
- base URLs
- supported models
- visibility flags
- pricing metadata
- feature flags
- tool-policy defaults if needed

Swift and TypeScript should both load this file through thin typed adapters.

Minimum rule: no second handwritten copy of provider/model/pricing truth.

## Shared Tool + Approval Contract

BurnBar should define one shared tool registry and one shared approval contract.

Example tool families for v1:

- `read_file`
- `search_workspace`
- `apply_patch`
- `run_terminal`

Every tool contract should define:

- tool name
- args schema
- result schema
- approval requirement
- trust requirement
- remote-workspace support

The approval contract should define:

- approval reason
- approval scope
- allowed action
- timeout/expiry
- audit event shape

## Search and Context

BurnBar should reuse the existing local GRDB + FTS store in v1.

Why:

- it already exists
- it already supports conversation search and snippets
- it avoids a second search/index subsystem before there is evidence one is needed

Implementation rule:

- put search/context behind a repository boundary so the backing implementation can change later without rewriting the daemon.

## Testing Strategy

BurnBar needs a boundary-aware test pyramid from day one.

### Swift tests

- catalog schema decode
- daemon RPC contract tests
- run-state machine transition tests
- client arbitration tests
- stale socket cleanup tests
- accounting/idempotency tests

### TypeScript tests

- catalog schema decode
- command RPC contract tests
- workspace capability tests
- trust gating tests
- UI projection tests

### Extension-host integration tests

Use the official VS Code extension-host test path.

Required scenarios:

- local workspace run
- approval flow
- cancel/retry flow
- daemon unavailable and reconnect
- remote/workspace companion execution
- restricted workspace degradation

### Replay evals

BurnBar also needs replay-based agent evals for:

- planner behavior
- approval triggering
- local vs remote routing
- repair/recovery messaging

These should compare against golden baselines in CI.

## Failure Modes

Critical production failures to design for:

- daemon not running
- stale socket path
- protocol version mismatch
- extension host reload mid-run
- workspace companion unavailable
- readonly or untrusted workspace
- duplicate clients acting on one run
- duplicated usage events
- remote workspace command succeeds locally but not remotely

Any failure path that has:

- no test
- no error handling
- and no user-visible message

should be treated as a critical gap.

## Rebrand + Migration

BurnBar should become the visible product name immediately, but legacy storage and identity migration needs to be handled explicitly.

Build now:

- BurnBar naming in docs, UI copy, settings, onboarding, notifications, app/product identity
- build identity updates from project config
- migration plan for legacy app support directory, database filename, keychain service IDs, `UserDefaults` domains, and related identifiers

Do not silently strand old local data.

## Suggested Build Order

### Phase 1

- rebrand visible product/build identity to BurnBar
- add explicit migration scaffolding for legacy local identifiers
- create `BurnBarCore`
- define catalog schema
- define tool/approval contracts
- define run-state machine

### Phase 2

- build daemon
- install/repair via `launchd`
- socket transport
- run service
- client arbitration

### Phase 3

- build Cursor extension UI
- build workspace companion
- add private cross-host command bridge
- add Workspace Trust gating

### Phase 4

- integrate usage/accounting back into BurnBar app
- add extension-host integration tests
- add replay evals

## Not In Scope

- providers beyond Z.ai and MiniMax for routed Cursor use
- native Cursor Agent compatibility through BYOK override
- Kimi support
- `pony-alpha-2`
- browser tools in v1
- multi-agent orchestration
- hosted relay/cloud control plane
- cross-platform daemon support
- second search/index subsystem

## References

- VS Code Remote Extensions:
  - https://code.visualstudio.com/api/advanced-topics/remote-extensions
- VS Code Workspace Trust:
  - https://code.visualstudio.com/api/extension-guides/workspace-trust
- VS Code Webviews:
  - https://code.visualstudio.com/api/ux-guidelines/webviews
- VS Code Extension CI/Testing:
  - https://code.visualstudio.com/api/working-with-extensions/continuous-integration
- Cursor Security:
  - https://cursor.com/security
