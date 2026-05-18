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

## Codex CLI

Codex CLI's "plugin" surface is MCP itself. Configure each server as a
`[mcp_servers.<name>]` table in `~/.codex/config.toml` (user) or a
trusted project's `.codex/config.toml`. Three options, from highest to
lowest fidelity:

**A. Hosted MCP via the stdio shim (recommended).** Forwards JSON-RPC to
`https://mcp.burnbar.ai/mcp`, decrypts sealed search results locally,
and pins the protocol version. Reads the bearer from macOS Keychain or
`OPENBURNBAR_MCP_ACCESS_TOKEN`. Run `openburnbar mcp login <bearer>`
once first.

```toml
[mcp_servers.openburnbar]
command = "openburnbar-mcp-remote"
args = ["mcp", "serve"]
startup_timeout_sec = 15
tool_timeout_sec = 60
```

**B. Hosted MCP via native streamable HTTP (no subprocess).** Skips the
shim — Codex talks directly to `https://mcp.burnbar.ai/mcp`. Sealed
search/body fields arrive as ciphertext (no local decrypt). Only works
when your Codex build negotiates protocolVersion `2025-11-25`;
otherwise the server returns `400 unsupported_protocol_version`.

```toml
[mcp_servers.openburnbar-http]
url = "https://mcp.burnbar.ai/mcp"
bearer_token_env_var = "OPENBURNBAR_MCP_ACCESS_TOKEN"
startup_timeout_sec = 15
tool_timeout_sec = 60
```

**C. Local SQLite — no network, no auth.** Read-only access to
`~/Library/Application Support/OpenBurnBar/openburnbar.sqlite`.

```toml
[mcp_servers.openburnbar-local]
command = "/absolute/path/to/OpenBurnBar/tools/openburnbar-mcp/.venv/bin/python"
args = ["/absolute/path/to/OpenBurnBar/tools/openburnbar-mcp/server.py"]
```

Quick-add for Option A via CLI:

```bash
codex mcp add openburnbar -- openburnbar-mcp-remote mcp serve
```

Or print the full config block straight from the installer:

```bash
openburnbar mcp install codex >> ~/.codex/config.toml
```

Confirm with `/mcp` inside the Codex TUI. See
[`docs/CODEX_AGENT_ONBOARDING.md`](../../docs/CODEX_AGENT_ONBOARDING.md)
for scope, recovery paths, and security guidance.

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
| `burnbar_semantic_search_conversations` | Local deterministic semantic search over indexed conversation chunks; returns structured `unavailable` when semantic tables or compatible embeddings are absent |
| `burnbar_cloud_semantic_search_conversations` | Hosted encrypted semantic search over the user's cloud session-log index; derives opaque query hashes locally and decrypts snippets locally |
| `burnbar_cloud_get_conversation_body` | Download and decrypt a full hosted session body returned by cloud semantic search |
| `burnbar_get_conversation` | Full row + `fullText` for one id |
| `burnbar_recent_usage` | Recent `token_usage` rows |
| `burnbar_project_summary` | Per-project cost + session aggregation over a rolling window |
| `burnbar_chat_messages` | In-app `chat_messages` tail |
| `burnbar_record_hermes_usage` | **Write** an idempotent row to the OpenBurnBar daemon usage ledger |
| `burnbar_resolve_usage_ledger_path` | Show the ledger path the writer will use |

`burnbar_record_hermes_usage` is the single write tool. It never touches the
SQLite DB. The writer is daemon-first: when a local OpenBurnBar daemon is
reachable on its UNIX socket
(`~/Library/Application Support/OpenBurnBar/openburnbar-daemon.sock`) it sends
the row through the `daemon.usage.record` RPC so the daemon's in-memory
idempotency cache stays consistent. When the daemon is offline the writer
falls back to a file-locked append against
`~/Library/Application Support/OpenBurnBar/usage-events.jsonl`. Either way,
re-sending the same `idempotency_key` will not double-count the spend.

The cloud search tools are opt-in. Configure them only for agents you trust
with session-log recall:

```bash
export OPENBURNBAR_FIREBASE_PROJECT_ID=burnbar
export OPENBURNBAR_FIREBASE_ID_TOKEN="<Firebase Auth ID token>"
export OPENBURNBAR_CLOUD_VAULT_KEY_BASE64="<32-byte vault key, base64>"
```

The MCP process keeps the plaintext query and vault key local. Firebase
receives only keyed token/semantic hashes, returns encrypted result envelopes,
and this MCP process decrypts titles, snippets, and requested bodies on-device.

The `BurnBarUsageEvent` JSON shape matches Swift's default `JSONEncoder`
output exactly:

| Field | Type | Notes |
|---|---|---|
| `providerID` | string | lower-case daemon id (e.g. `"hermes"`) |
| `modelID` | string | provider-native model id |
| `inputTokens` / `outputTokens` | int | non-negative |
| `cacheCreationTokens` / `cacheReadTokens` | int | optional, defaults to `0` |
| `reasoningTokens` | int | optional, defaults to `0` |
| `cost` | float | USD; `0` when not yet known |
| `recordedAt` | float | Apple reference-date seconds (`unix_seconds - 978_307_200`) |
| `sessionID` | string? | optional Hermes/app session id |
| `projectName` | string? | shown in the OpenBurnBar dashboard |
| `confidence` | string | one of `exact`, `derived_exact`, `high_confidence_estimate`, `low_confidence_estimate`, `unknown` |

## Hermes proxy sidecar

A stdlib-only OpenAI-compatible proxy (`hermes_proxy.py`) sits in front of
`hermes gateway run` and writes usage rows to the same ledger automatically.

```bash
python3 tools/openburnbar-mcp/hermes_proxy.py \
    --listen 127.0.0.1:8643 \
    --upstream http://127.0.0.1:8642 \
    --provider-id hermes \
    --session-id $(date +%Y%m%d) \
    --project-name "Hermes (proxy)"
```

Now point OpenBurnBar mobile/desktop at `http://<your-mac-ip>:8643/v1` instead
of Hermes directly. SSE streams, tool calls, auth, models — all forwarded
verbatim. Each completed `chat/completions` response writes one ledger row
(idempotent on `id` if Hermes returns one, otherwise on a hash of the recorded
tuple).

Use `--no-estimate` to skip recording when the upstream response does not
include `usage`. The default behaviour records a `low_confidence_estimate`
row instead so OpenBurnBar can still show the session.

## Security

This exposes **local chat transcripts** to any process that can run the MCP server. Use only on your machine and keep MCP config out of shared repos if paths are sensitive.

## Support level

OpenBurnBar treats this as adjacent tooling:

- public and intentionally read-only
- useful for local developer workflows
- not required to build or run the macOS app, daemon, CLI, or editor extension
- best-effort support compared with the core OpenBurnBar surfaces
