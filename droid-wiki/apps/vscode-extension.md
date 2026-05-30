# VS Code / Cursor extension

TypeScript sidebar extension for VS Code and Cursor. Backed by the OpenBurnBar daemon running locally on the same machine.

**Location:** `extensions/openburnbar/`  
**Entry point:** `src/` (TypeScript, compiled to `dist/`)  
**Package manifest:** `extensions/openburnbar/package.json`

## What it shows

| Panel | Content |
|---|---|
| Health | Daemon connection state — `Connected`, `Unavailable`, `Protocol mismatch` |
| Runs | Projected rows for daemon handshake, catalog sync, and workspace state |
| Run Detail | Selected row with recovery guidance when something is blocked |

## What it does NOT yet have

- Start, retry, or cancel run controls from the sidebar
- Approval response UI for Computer Use actions
- Browser tools
- Routed providers beyond Z.ai, MiniMax, and Ollama Cloud

Factory and OpenCode routed-client sync is handled in the macOS app, not the extension.

## Supported routed providers

Current release exposes only three providers for Cursor routing:

- **Z.ai**
- **MiniMax**
- **Ollama Cloud**

Excluded from this release: Kimi, pony-alpha-2, internal catalog models.

## Workspace capability modes

The extension detects workspace mode from the VS Code extension host and surfaces the result in the sidebar.

| Mode | read_file / search_workspace | apply_patch | run_terminal |
|---|---|---|---|
| Local trusted | ✓ available | After explicit approval | After explicit approval |
| Remote trusted | ✓ (when remote host supports it) | After explicit approval | After explicit approval |
| Read-only | ✓ | ✗ | ✗ |
| Virtual | ✓ | ✗ | ✗ |
| Restricted | ✓ | ✗ (gated until workspace trusted) | ✗ |
| No workspace | Health only | — | — |

All workspace tools are bounded to the opened workspace roots.

## Setup

1. Open the OpenBurnBar macOS app on the same machine.
2. Install or repair the daemon from within the app.
3. Add provider API keys in the app if you want routed models.
4. Install the OpenBurnBar extension in Cursor / VS Code.
5. Open a folder or workspace.
6. Open the OpenBurnBar activity bar panel.

Expected first-load: `Health` shows `Connected`, `Runs` shows projected rows.

## Common recovery paths

| Symptom | Recovery |
|---|---|
| Daemon unavailable | Open OpenBurnBar app → confirm daemon installed → run **OpenBurnBar: Repair Daemon** from sidebar |
| Connected, waiting for catalog | Check provider settings in app → refresh sidebar |
| No workspace open | Open a folder or workspace in Cursor |
| Workspace companion unavailable | Reload Cursor window → reopen sidebar after host comes back |
| Protocol mismatch | Update OpenBurnBar so app, daemon, and extension share the same protocol version |

## Remote workspace note

The workspace companion can run on a remote extension host. The daemon repair action is still local macOS behavior — if repair is unavailable from a remote context, use the local OpenBurnBar app directly.

## Key files

| Path | Purpose |
|---|---|
| `extensions/openburnbar/src/` | TypeScript source |
| `extensions/openburnbar/dist/` | Compiled output |
| `extensions/openburnbar/package.json` | Extension manifest, commands, activation events |
| `extensions/openburnbar/test/` | Extension test suite |
| `extensions/openburnbar/scripts/` | Build and packaging scripts |
| `docs/OPENBURNBAR_CURSOR_AGENT_ONBOARDING.md` | Full onboarding guide |
