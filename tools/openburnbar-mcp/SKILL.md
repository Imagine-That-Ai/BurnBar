# BurnBar Operator (openburnbar-mcp)

**For:** Hermes Agent — `~/.hermes/skills/software-development/burnbar-operator/SKILL.md`

This skill teaches Hermes to act as a full operator over OpenBurnBar data: spend analysis, session recall, workflow coaching, and debug investigations — all grounded in local SQLite evidence.

## MCP Tools Exposed

The `openburnbar-mcp` server (`tools/openburnbar-mcp/server.py`) exposes local
SQLite tools, hosted encrypted cloud-search tools, and 2 ledger tools:

| Tool | Purpose |
|------|---------|
| `burnbar_resolve_db_path` | Show which DB file is in use |
| `burnbar_list_providers` | Enumerate tracked AI providers |
| `burnbar_recent_usage` | Recent token_usage rows (cost, model, provider, session) |
| `burnbar_project_summary` | Pre-aggregated cost + session count per project over a rolling window |
| `burnbar_search_conversations` | FTS search over conversation titles and transcripts |
| `burnbar_semantic_search_conversations` | Local deterministic semantic search over indexed conversation chunks; returns structured `unavailable` when semantic tables or compatible embeddings are absent |
| `burnbar_cloud_semantic_search_conversations` | Hosted encrypted semantic search; query hashes are derived locally and snippets decrypt locally |
| `burnbar_cloud_get_conversation_body` | Decrypt the full hosted session body for a cloud search hit |
| `burnbar_get_conversation` | Full row + fullText for one conversation by ID |
| `burnbar_chat_messages` | In-app assistant chat_messages tail |
| `burnbar_record_hermes_usage` | **Write** an idempotent row to the daemon usage ledger |
| `burnbar_resolve_usage_ledger_path` | Show the ledger path the writer will use |

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

- Read tools are **read-only** — no writes to the BurnBar SQLite database.
- `burnbar_record_hermes_usage` is the single write tool: it appends an
  idempotent record to the daemon usage ledger
  (`~/Library/Application Support/OpenBurnBar/usage-events.jsonl`). The macOS
  app picks the row up on its next refresh.
- `burnbar_search_conversations` uses FTS5 with the same query builder as the
  OpenBurnBar app.
- `burnbar_semantic_search_conversations` only scores local deterministic
  OpenBurnBar embeddings from `chunk_embeddings`; it does not call network
  embedding providers or fake semantic results when the local semantic index is
  absent.
- `burnbar_cloud_semantic_search_conversations` is the hosted encrypted path.
  It requires `OPENBURNBAR_FIREBASE_ID_TOKEN` and
  `OPENBURNBAR_CLOUD_VAULT_KEY_BASE64`; plaintext and vault key stay on the MCP
  host while Firebase receives only opaque search hashes.
- `burnbar_project_summary` aggregates over `token_usage` — not a substitute
  for per-session transcripts.
- `burnbar_get_conversation.fullText` is truncated at 120 000 chars by default.

## Grounding

This skill is the BurnBar-side counterpart to the Hermes `burnbar-operator` skill and is indexed by OpenBurnBar's artifact discovery system so the in-app assistant can also retrieve it as context.
