# BurnBar local MCP (Codex, Claude, Cursor)

Read-only access to your **BurnBar SQLite** database (`conversations`, `token_usage`, `chat_messages`) so MCP-capable clients can search transcripts and usage without the in-app assistant’s trimmed system prompt.

## Setup

```bash
cd tools/burnbar-mcp
./setup.sh
```

Optional: `export BURNBAR_DB_PATH="/path/to/burnbar.sqlite"` if the DB is not under `~/Library/Application Support/BurnBar/`.

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

## Tools

| Tool | Purpose |
|------|--------|
| `burnbar_resolve_db_path` | Show which DB file is used |
| `burnbar_list_providers` | Distinct `provider` values (e.g. `"Codex"`, `"Claude Code"`) |
| `burnbar_search_conversations` | FTS search over titles + transcripts |
| `burnbar_get_conversation` | Full row + `fullText` for one id |
| `burnbar_recent_usage` | Recent `token_usage` rows |
| `burnbar_chat_messages` | In-app `chat_messages` tail |

## Security

This exposes **local chat transcripts** to any process that can run the MCP server. Use only on your machine and keep MCP config out of shared repos if paths are sensitive.
