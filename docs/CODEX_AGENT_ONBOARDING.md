# OpenBurnBar + Codex CLI Onboarding

## Current Scope

Codex CLI does not have a "plugin" surface distinct from MCP — its plugin
surface *is* MCP. OpenBurnBar ships two MCP servers that Codex can use
side-by-side: the **hosted streamable-HTTP server** at
`https://mcp.burnbar.ai/mcp` (sealed search, encrypted body retrieval,
usage metadata) and the **local Python stdio server** that reads
`~/Library/Application Support/OpenBurnBar/openburnbar.sqlite` directly
(FTS5, local semantic search, write tool for the daemon usage ledger).

What you get in Codex sessions after onboarding:

- `tools/list` returns the OpenBurnBar tools under whichever
  `[mcp_servers.*]` tables you enabled.
- Sealed search results are decrypted locally when you go through the
  stdio shim (Option A below); the direct HTTP path (Option B) leaves
  sealed fields as ciphertext on purpose.
- Read-only by default for the hosted MCP. The local MCP exposes one
  write tool (`burnbar_record_hermes_usage`) that routes through the
  daemon's idempotent ledger — it never writes to SQLite directly.

What is not in this onboarding:

- `codex mcp login openburnbar` OAuth — the hosted server already
  exposes `/.well-known/oauth-*`, but the dynamic client registration
  handshake is not yet wired. Use the static bearer below.
- IDE-side surfacing of OpenBurnBar state inside Codex's editor
  extension (separate work, parallel to the Cursor extension at
  `extensions/openburnbar/`).

## Setup

1. Install the `openburnbar-mcp-remote` CLI (ships in this repo at
   `tools/openburnbar-mcp-remote/`; build with `npm run build` and link
   with `npm link` to expose `openburnbar` and `openburnbar-mcp-remote`
   on `PATH`).
2. Run `./tools/openburnbar-mcp/setup.sh` once to create the local
   Python venv (needed only for Option C).
3. Mint a hosted bearer from the OpenBurnBar macOS app
   (**Settings → Remote MCP → Generate token**), then run
   `openburnbar mcp login <token>` once. The token is stored in the
   macOS Keychain under `com.openburnbar.mcp-remote/default`, with a
   `~/.openburnbar/mcp-remote-token` fallback for non-Keychain hosts.
4. Print the Codex config block and append it to your Codex config:

   ```bash
   openburnbar mcp install codex >> ~/.codex/config.toml
   ```

   Or edit `~/.codex/config.toml` (user) or a trusted project's
   `.codex/config.toml` directly — see the three options below.
5. Restart Codex (`codex` for TUI; quit and re-launch). Run `/mcp`
   inside the TUI to confirm the OpenBurnBar servers are listed and
   their tool count matches what's documented at
   [`tools/openburnbar-mcp/README.md`](../tools/openburnbar-mcp/README.md).

## Three Configuration Options

### Option A — Stdio shim over the hosted MCP (recommended)

```toml
[mcp_servers.openburnbar]
command = "openburnbar-mcp-remote"
args = ["mcp", "serve"]
startup_timeout_sec = 15
tool_timeout_sec = 60
```

Why this is the default:

- The shim sends `MCP-Protocol-Version: 2025-11-25` explicitly,
  matching what the hosted server enforces at
  `services/hosted-mcp/src/server.ts` (`validateProtocol`).
- The shim decrypts sealed search-result content locally using
  `OPENBURNBAR_CLOUD_VAULT_KEY_BASE64` when present. Without the shim,
  sealed titles/snippets in `burnbar_search_conversations` and
  `burnbar_get_conversation_body` stay as ciphertext.
- The shim picks up the bearer transparently from Keychain (or the
  fallback file, or `OPENBURNBAR_MCP_ACCESS_TOKEN`) — Codex does not
  need to know about the token.

### Option B — Native streamable HTTP

```toml
[mcp_servers.openburnbar-http]
url = "https://mcp.burnbar.ai/mcp"
bearer_token_env_var = "OPENBURNBAR_MCP_ACCESS_TOKEN"
startup_timeout_sec = 15
tool_timeout_sec = 60
```

When to use:

- You don't care about local decryption of sealed search/body content
  (metadata tools — `burnbar_recent_usage`,
  `burnbar_list_search_facets`, `burnbar_list_search_index_status`,
  `burnbar_resolve_capabilities` — work normally).
- You want to remove the shim subprocess from the loop.
- Your Codex build's MCP client negotiates protocolVersion
  `2025-11-25`. If it negotiates anything else, the server returns
  `400 unsupported_protocol_version` and the session fails to
  initialize. The validation is at
  `services/hosted-mcp/src/server.ts:36`.

Export `OPENBURNBAR_MCP_ACCESS_TOKEN` in the shell where you launch
Codex before relying on this path.

### Option C — Local SQLite stdio

```toml
[mcp_servers.openburnbar-local]
command = "/absolute/path/to/OpenBurnBar/tools/openburnbar-mcp/.venv/bin/python"
args = ["/absolute/path/to/OpenBurnBar/tools/openburnbar-mcp/server.py"]
```

When to use:

- Offline — no Firebase, no hosted MCP. Reads SQLite directly.
- Higher-fidelity local tools: FTS5 search, deterministic semantic
  search, full-row reads, the write tool for the daemon usage ledger.
- The local server exposes 12 tools — see the table in
  [`tools/openburnbar-mcp/README.md`](../tools/openburnbar-mcp/README.md).

Override the SQLite path with `BURNBAR_DB_PATH=/absolute/path.sqlite`
in the Codex `env` table:

```toml
[mcp_servers.openburnbar-local.env]
BURNBAR_DB_PATH = "/Users/you/exports/openburnbar.sqlite"
```

## Bearer Token Sourcing

`openburnbar mcp login <token>` stores the bearer in this order
(see `tools/openburnbar-mcp-remote/src/oauth.ts`):

1. macOS Keychain — `service=com.openburnbar.mcp-remote`,
   `account=default`.
2. Local fallback — `~/.openburnbar/mcp-remote-token` (file mode `0600`).
3. Process env — `OPENBURNBAR_MCP_ACCESS_TOKEN` always wins over the
   stored values when set.

Option A (stdio shim) reads any of these automatically. Option B
(native HTTP) reads only `OPENBURNBAR_MCP_ACCESS_TOKEN` because that's
the env var named in `bearer_token_env_var`. If you want Option B to
pick up a Keychain-stored token, export it at shell startup:

```bash
# ~/.zshrc
export OPENBURNBAR_MCP_ACCESS_TOKEN="$(security find-generic-password \
  -s com.openburnbar.mcp-remote -a default -w 2>/dev/null)"
```

## Verification

After editing `~/.codex/config.toml`:

1. `codex` — launch the TUI.
2. `/mcp` — list active MCP servers. Expect `openburnbar` (and/or
   `openburnbar-http`, `openburnbar-local`) with green status and the
   tool count from
   [`tools/openburnbar-mcp/README.md`](../tools/openburnbar-mcp/README.md).
3. Smoke prompt — "list openburnbar tools." Codex should call
   `tools/list` on each configured server and surface them.
4. Search smoke — "search openburnbar for conversations about
   <topic>." Should hit `burnbar_search_conversations` and return
   results.

## Common Recovery Paths

`400 unsupported_protocol_version` from `mcp.burnbar.ai`

- Your Codex build's MCP client negotiated a protocolVersion the
  server does not accept. Switch to Option A (the stdio shim pins the
  version that works).

`401 from mcp.burnbar.ai`

- Token missing or expired. Run `openburnbar mcp login <new-bearer>`.
  If using Option B, also re-export
  `OPENBURNBAR_MCP_ACCESS_TOKEN` in your shell.

`Server openburnbar-local failed to start`

- The Python venv is missing. Run `./tools/openburnbar-mcp/setup.sh`.
- The paths in your `[mcp_servers.openburnbar-local]` block are
  placeholders. Replace `/absolute/path/to/OpenBurnBar/...` with your
  actual clone location.

`burnbar_resolve_db_path returns a path you do not expect`

- The local MCP looks under `~/Library/Application Support/OpenBurnBar/`
  by default. Override with
  `BURNBAR_DB_PATH=/absolute/path.sqlite` in the server's `env` table.

`tools/list returns sealed ciphertext instead of titles`

- You are on Option B. Sealed search results are not decrypted on
  the direct HTTP path. Switch to Option A (the shim) and confirm
  `OPENBURNBAR_CLOUD_VAULT_KEY_BASE64` is exported so the shim can
  decrypt.

`Daemon unavailable when calling burnbar_record_hermes_usage`

- The local OpenBurnBar daemon is down. The writer falls back to a
  file-locked append on
  `~/Library/Application Support/OpenBurnBar/usage-events.jsonl`,
  so the call still succeeds but the daemon ledger picks it up later.
  Open the macOS app and run **Repair Daemon** to restore the
  primary path.

## Security

- Hosted bearer tokens are user-scoped and per-client. Rotate from the
  macOS app's **Settings → Remote MCP** panel; revocation propagates
  through `users/{uid}/remote_mcp_clients/{clientId}.revokedAt`.
- The local MCP exposes plaintext chat transcripts to whatever
  process Codex launches. Do not point Codex at the local MCP from a
  shared / unprivileged account.
- Sealed search results are decrypted on-device by the stdio shim
  using `OPENBURNBAR_CLOUD_VAULT_KEY_BASE64`. Keep the vault key out
  of shared environments — Firebase only ever sees opaque token
  hashes.

## Support level

OpenBurnBar treats Codex integration as adjacent tooling, equivalent
to the Cursor and Claude Desktop paths:

- public and read-only by default for the hosted MCP
- one write tool on the local MCP, routed through the daemon's
  idempotent ledger
- not required to build or run the macOS app, daemon, CLI, or editor
  extension
- best-effort support compared with the core OpenBurnBar surfaces
