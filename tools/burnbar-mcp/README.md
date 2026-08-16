# BurnBar local MCP (Codex, Claude, Cursor, Grok, Pi)

Read-only access to your **BurnBar SQLite** database (`conversations`, `token_usage`, `chat_messages`) plus the **Live Agent Fleet** board (`fleet-snapshot.json`, sidecar presence, go/wait/no advice). MCP never writes the daemon and never kills processes.

## Setup

```bash
cd tools/burnbar-mcp
./setup.sh
```

Optional env:

| Variable | Purpose |
|----------|---------|
| `BURNBAR_DB_PATH` | Override `burnbar.sqlite` |
| `BURNBAR_DAEMON_SUPPORT_DIR` | Application Support dir (default `~/Library/Application Support/BurnBar`) |
| `BURNBAR_FLEET_SNAPSHOT_PATH` | Override `fleet-snapshot.json` |
| `BURNBAR_FLEET_PRESENCE_PATH` | Override sidecar `fleet-presence.json` |
| `BURNBAR_DAEMON_SOCKET` | Override `burnbar-daemon.sock` |
| `BURNBAR_FLEET_PEER_DIR` | Directory of extra snapshot JSON files (local overlay until CloudSync) |

Do not point fleet tools at `burnbar.sqlite` (~5 GiB). Fleet state is the snapshot file (fallback: `daemon.fleet.snapshot` JSON-RPC).

## Cursor

1. Open **Cursor Settings → MCP** (or edit your MCP config JSON).
2. Add a server (adjust paths if your clone is not at `~/Developer/AgentLens`):

```json
{
  "mcpServers": {
    "burnbar-local": {
      "command": "/Users/YOU/Developer/AgentLens/tools/burnbar-mcp/.venv/bin/python",
      "args": ["/Users/YOU/Developer/AgentLens/tools/burnbar-mcp/server.py"]
    }
  }
}
```

Restart Cursor. Enable **burnbar-local** for the chat that should use it.

## Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` and add the same `mcpServers.burnbar-local` block under `mcpServers`, then restart Claude Desktop.

## Claude Code

Add the same stdio server under `mcpServers` in `~/.claude.json` (or project `.mcp.json`), then restart Claude Code.

## Codex

In `~/.codex/config.toml`:

```toml
[mcp_servers.burnbar-local]
command = "/Users/YOU/Developer/AgentLens/tools/burnbar-mcp/.venv/bin/python"
args = ["/Users/YOU/Developer/AgentLens/tools/burnbar-mcp/server.py"]
```

## Grok / Pi / other stdio clients

Same command + args as Cursor. Point the client's MCP/stdio config at `.venv/bin/python` and `server.py`. No extra protocol.

## Tools

| Tool | Purpose |
|------|--------|
| `burnbar_resolve_db_path` | Show which DB file is used |
| `burnbar_list_providers` | Distinct `provider` values (e.g. `"Codex"`, `"Claude Code"`) |
| `burnbar_search_conversations` | FTS search over titles + transcripts |
| `burnbar_get_conversation` | Full row + `fullText` for one id |
| `burnbar_recent_usage` | Recent `token_usage` rows |
| `burnbar_chat_messages` | In-app `chat_messages` tail |
| `burnbar_fleet_snapshot` | Who is running, which repo, CPU/mem/disk |
| `burnbar_fleet_can_launch` | Advice only: `go` / `wait` / `no` for a proposed job |
| `burnbar_fleet_presence_record` | Sidecar intent row (`fleet-presence.json`, TTL). Not daemon RPC |

Jobs `can_launch` understands: `xcodebuild`, `app-ui`, `swift-app-test`, `npm-test-full`, `full-ci`, `vitest`, `npm-test`, `swift-package-test`, `daemon-socket`.

Before a heavy test on this Mac, call `burnbar_fleet_snapshot` then `burnbar_fleet_can_launch`. If the verdict is `wait` or `no`, pick a lighter job or another machine. Never kill or renice other agents.

## Tests

```bash
cd tools/burnbar-mcp
python3 test_fleet.py
```

Hermetic: tmp fixtures only. Does not open `burnbar.sqlite` or run `xcodebuild`.

## Team sync

See [TEAM_SYNC.md](./TEAM_SYNC.md). CloudSync of per-machine snapshots is **after Droid M6**. Until then, drop extra host JSON files in `BURNBAR_FLEET_PEER_DIR`. Do not add CloudSync/Firebase to the daemon serving path.

## Security

This exposes **local chat transcripts** and **local fleet occupancy** to any process that can run the MCP server. Use only on your machine and keep MCP config out of shared repos if paths are sensitive.
