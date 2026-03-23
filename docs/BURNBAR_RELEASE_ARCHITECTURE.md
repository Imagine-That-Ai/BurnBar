# BurnBar Current Release Architecture

## What Ships Now

The current BurnBar Cursor release is a local-first extension shell around the BurnBar daemon.

Shipped extension surfaces:

- `Health` tree view
- `Runs` tree view
- `Run Detail` tree view
- `BurnBar: Reconnect`
- `BurnBar: Refresh`
- `BurnBar: Repair Daemon`

Shipped daemon RPCs used by the extension:

- `daemon.health`
- `daemon.catalog`

Shipped workspace RPCs:

- `workspace.capabilities`
- `workspace.read_file`
- `workspace.search_workspace`
- `workspace.apply_patch`
- `workspace.run_terminal`

Current limitation:

- the sidebar is still a projected shell for daemon, catalog, and workspace state
- it does not yet expose full run creation or approval response controls

## Boundary Summary

```text
Cursor UI host
  -> BurnBar extension views and commands
  -> local daemon JSON-RPC client
  -> workspace RPC client

Cursor workspace host
  -> BurnBar workspace companion
  -> capability detection
  -> read/search/edit/terminal adapters

Local macOS BurnBar daemon
  -> daemon health
  -> provider catalog
  -> repair target for launchd-managed runtime
```

## Provider Scope

Current routed Cursor provider scope:

- `Z.ai`
- `MiniMax`

Documented unsupported routed cases:

- `Kimi`
- `pony-alpha-2`
- hidden/internal catalog models
- browser tools

## Trust And Workspace Behavior

Current shipped restricted-mode behavior:

- Available: `read_file`, `search_workspace`, health, catalog state, projected run state.
- Gated: `apply_patch`, `run_terminal`.

Other workspace limits:

- no workspace open: no workspace tools
- read-only workspace: no edit application
- virtual workspace: no terminal execution
- remote workspace: companion runs on the workspace host when available

## Recovery Copy Coverage

The extension now carries user-facing recovery guidance for these common failures:

- daemon socket unavailable
- daemon timeout
- protocol mismatch
- daemon not installed
- local-only daemon repair constraints
- empty provider catalog
- no workspace open
- restricted workspace gating
- missing workspace companion

## Test Entrypoints

Most relevant extension tests:

- `cd extensions/burnbar && npm run test:unit`
- `cd extensions/burnbar && npm run test:replay`
- `cd extensions/burnbar && npm run test:extension-host`

Coverage notes:

- unit tests cover projections, daemon client behavior, workspace capability detection, workspace RPC gating, and activation wiring
- replay evals lock recovery and routing copy against golden fixtures
- extension-host tests cover local workspace execution plus remote and restricted workspace projection behavior
