# OpenBurnBar local MCP (Codex, Claude, Cursor, Hermes)

Read-only access to your **OpenBurnBar SQLite** database (`conversations`, `token_usage`, `chat_messages`) so MCP-capable clients can search transcripts and usage without the in-app assistant’s trimmed system prompt.

## Setup

```bash
cd tools/openburnbar-mcp
./setup.sh
```

This creates the Python venv, installs deps, and symlinks the `burnbar-operator` Hermes skill into `~/.hermes/skills/` (if `~/.hermes` exists).

Optional: `export BURNBAR_DB_PATH="/path/to/openburnbar.sqlite"` if the DB is not under `~/Library/Application Support/OpenBurnBar/`.

## Cursor

1. Open **Cursor Settings → MCP** (or edit your MCP config JSON).
2. Add a server (adjust the absolute paths for wherever you cloned OpenBurnBar):

```json
{
  "mcpServers": {
    "openburnbar-local": {
      "command": "/absolute/path/to/OpenBurnBar/tools/openburnbar-mcp/.venv/bin/python",
      "args": ["/absolute/path/to/OpenBurnBar/tools/openburnbar-mcp/server.py"]
    }
  }
}
```

Restart Cursor. Enable **openburnbar-local** for the chat that should use it.

## Hermes Agent

`setup.sh` automatically symlinks the `burnbar-operator` skill into `~/.hermes/skills/software-development/burnbar-operator/SKILL.md`. Add the MCP server to `~/.hermes/config.yaml`:

```yaml
mcp_servers:
  openburnbar_local:
    command: "/absolute/path/to/OpenBurnBar/tools/openburnbar-mcp/.venv/bin/python"
    args: ["/absolute/path/to/OpenBurnBar/tools/openburnbar-mcp/server.py"]
    timeout: 30
    connect_timeout: 20
```

Restart Hermes. The skill activates on questions about spend, sessions, or workflow. If you used the OpenBurnBar setup wizard, this is configured automatically.

## Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` and add the same `mcpServers.openburnbar-local` block under `mcpServers`, then restart Claude Desktop.

## Tools

| Tool | Purpose |
|------|--------|
| `burnbar_resolve_db_path` | Show which DB file is used |
| `burnbar_list_providers` | Distinct `provider` values (e.g. `"Codex"`, `"Claude Code"`) |
| `burnbar_search_conversations` | FTS search over titles + transcripts |
| `burnbar_get_conversation` | Full row + `fullText` for one id |
| `burnbar_recent_usage` | Recent `token_usage` rows |
| `burnbar_project_summary` | Per-project cost + session aggregation over a rolling window |
| `burnbar_chat_messages` | In-app `chat_messages` tail |

## Security

This exposes **local chat transcripts** to any process that can run the MCP server. Use only on your machine and keep MCP config out of shared repos if paths are sensitive.

## Support level

OpenBurnBar treats this as adjacent tooling:

- public and intentionally read-only
- useful for local developer workflows
- not required to build or run the macOS app, daemon, CLI, or editor extension
- best-effort support compared with the core OpenBurnBar surfaces
