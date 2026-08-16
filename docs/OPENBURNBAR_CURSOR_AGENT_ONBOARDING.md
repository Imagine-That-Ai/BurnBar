# OpenBurnBar + Cursor Agent Onboarding

## Plugin vs extension (read this first)

OpenBurnBar ships **three distinct Cursor surfaces** — the editor extension,
the personal/operator MCP tooling, and the marketplace Cursor Plugin. The
**marketplace Cursor Plugin** (`plugins/openburnbar/`, installable from the
Cursor Marketplace once published, or symlinked locally) is the new one: it
connects Cursor agents — including **Cloud Agents** — to hosted Remote MCP at
`https://mcp.burnbar.ai/mcp` over HTTP with the
`OPENBURNBAR_MCP_ACCESS_TOKEN` bearer variable, so agents can query spend,
past sessions, knowledge, and resume hints as grounded evidence. The **VS Code
/ Cursor editor extension** (`extensions/openburnbar/`) is a separate,
older surface: a daemon-backed activity-bar sidebar that is
**source-only / load-unpacked** (no VS Marketplace / Open VSX listing) — the
plugin is hosted HTTP + bearer and does not bundle or replace it. The
**personal / operator MCP** (the `openburnbar-mcp-remote` stdio shim or the
local SQLite MCP under `tools/openburnbar-mcp`) is adjacent operator tooling,
not the marketplace package. See
[`OPENBURNBAR_CURSOR_PLUGIN.md`](OPENBURNBAR_CURSOR_PLUGIN.md) for plugin
install and auth, and the extension section below for the sidebar.

## Current Scope

OpenBurnBar ships a local-first Cursor extension shell backed by the OpenBurnBar daemon.

What the current release shows in Cursor:

- daemon health
- projected daemon, catalog, and workspace status
- reconnect, refresh, and daemon repair actions
- workspace capability state across local, remote, read-only, virtual, and restricted modes

What is not in this shell yet:

- start, retry, or cancel run controls from the sidebar
- approval response UI
- browser tools
- routed providers beyond Z.ai, MiniMax, and Ollama Cloud

Factory and OpenCode routed-client sync is app-side configuration, not Cursor
extension UI. See [`ROUTED_CLIENT_GATEWAY.md`](ROUTED_CLIENT_GATEWAY.md).

## Setup

1. Open the OpenBurnBar macOS app on the same machine as Cursor.
2. Install or repair the OpenBurnBar daemon from the app.
3. Add provider keys in OpenBurnBar if you want routed Cursor models.
4. Install the OpenBurnBar extension in Cursor.
5. Open a folder or workspace in Cursor.
6. Open the OpenBurnBar activity bar item.

Expected first-load state:

- `Health` shows `Connected` when the local daemon responds.
- `Runs` shows projected rows for daemon handshake, catalog sync, and workspace state.
- `Run Detail` mirrors the selected row and includes recovery guidance when something is blocked.

## Supported Providers

Current routed Cursor support is limited to public models exposed by the bundled OpenBurnBar catalog:

- `Z.ai`
- `MiniMax`
- `Ollama Cloud`

Unsupported or intentionally excluded for routed Cursor use in this release:

- `Kimi`
- `pony-alpha-2`
- hidden or internal catalog models

## Workspace Modes

OpenBurnBar detects workspace mode from the extension host and explains the result in the sidebar.

- No workspace open: health stays available, but workspace tools stay disabled until you open a folder or workspace.
- Local trusted workspace: `read_file` and `search_workspace` are available immediately; `apply_patch` and `run_terminal` are available only after explicit approval, and all workspace tools stay bounded to the opened workspace roots.
- Remote trusted workspace: the companion runs on the workspace host and reports the same tool set when the remote host supports it.
- Read-only workspace: OpenBurnBar can read and search, but it cannot apply edits.
- Virtual workspace: OpenBurnBar can read and search, but terminal execution stays unavailable.

## Restricted Mode

Current shipped restricted-mode behavior:

- Available: `read_file`, `search_workspace`, health, catalog state, projected run state.
- Gated: `apply_patch`, `run_terminal`.

Recovery path:

1. Trust the workspace in Cursor.
2. Refresh OpenBurnBar if the workspace state does not update automatically.

## Common Recovery Paths

`Daemon unavailable`

- Open the OpenBurnBar app.
- Confirm the daemon is installed.
- Run `OpenBurnBar: Repair Daemon` from the sidebar if needed.

`Connected, waiting for provider catalog`

- Check provider settings in the OpenBurnBar app.
- Refresh the OpenBurnBar sidebar.

`No workspace open`

- Open a folder or workspace in Cursor.

`Workspace companion unavailable`

- Reload the Cursor window.
- Reopen the OpenBurnBar sidebar after the workspace host comes back.

`Protocol mismatch`

- Update OpenBurnBar so the app, daemon, and extension use the same protocol version.

## Remote Workspace Note

The workspace companion can run on a remote extension host, but the OpenBurnBar daemon repair action is still local macOS behavior. If repair is unavailable from a remote UI context, use the local OpenBurnBar app.
