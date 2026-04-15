# BurnBar Operator (openburnbar-mcp)

**For:** Hermes Agent — `~/.hermes/skills/software-development/burnbar-operator/SKILL.md`

This skill teaches Hermes to act as a full operator over OpenBurnBar data: spend analysis, session recall, workflow coaching, and debug investigations — all grounded in local SQLite evidence.

## MCP Tools Exposed

The `openburnbar-mcp` server (`tools/openburnbar-mcp/server.py`) exposes 7 read-only tools over the OpenBurnBar SQLite database:

| Tool | Purpose |
|------|---------|
| `burnbar_resolve_db_path` | Show which DB file is in use |
| `burnbar_list_providers` | Enumerate tracked AI providers |
| `burnbar_recent_usage` | Recent token_usage rows (cost, model, provider, session) |
| `burnbar_project_summary` | Pre-aggregated cost + session count per project over a rolling window |
| `burnbar_search_conversations` | FTS search over conversation titles and transcripts |
| `burnbar_get_conversation` | Full row + fullText for one conversation by ID |
| `burnbar_chat_messages` | In-app assistant chat_messages tail |

## Setup

```bash
cd tools/openburnbar-mcp
./setup.sh
```

Add to `~/.hermes/config.yaml`:

```yaml
mcp_servers:
  openburnbar_local:
    command: "/absolute/path/to/OpenBurnBar/tools/openburnbar-mcp/.venv/bin/python"
    args: ["/absolute/path/to/OpenBurnBar/tools/openburnbar-mcp/server.py"]
    timeout: 30
    connect_timeout: 20
```

## Evidence contract

- All tools are **read-only** — no writes to the BurnBar database.
- `burnbar_search_conversations` uses FTS5 with the same query builder as the OpenBurnBar app.
- `burnbar_project_summary` aggregates over `token_usage` — not a substitute for per-session transcripts.
- `burnbar_get_conversation.fullText` is truncated at 120 000 chars by default.

## Grounding

This skill is the BurnBar-side counterpart to the Hermes `burnbar-operator` skill and is indexed by OpenBurnBar's artifact discovery system so the in-app assistant can also retrieve it as context.
