# OpenBurnBar local MCP (Codex, Claude, Cursor, Hermes)

Default read-only access to your **OpenBurnBar SQLite** database (`conversations`, `token_usage`, `chat_messages`) so MCP-capable clients can search transcript indexes and usage without the in-app assistant’s trimmed system prompt.

The local server now fails closed for higher-risk capabilities. By default it blocks cloud decrypt, cloud sync, local writes, full plaintext reads, and process spawn. Enable a capability only for the shell session that needs it:

```bash
export OPENBURNBAR_LOCAL_MCP_ENABLE_SENSITIVE_READ=true  # full conversation/chat/project-memory plaintext
export OPENBURNBAR_LOCAL_MCP_ENABLE_CLOUD_DECRYPT=true   # hosted encrypted search/body/project-memory decrypt
export OPENBURNBAR_LOCAL_MCP_ENABLE_CLOUD_SYNC=true      # upload encrypted project memory snapshots
export OPENBURNBAR_LOCAL_MCP_ENABLE_LOCAL_WRITE=true     # usage ledger and budget mutation tools
export OPENBURNBAR_LOCAL_MCP_ENABLE_SPAWN=true           # detached native/cross-harness resume processes
```

`OPENBURNBAR_LOCAL_MCP_PROFILE=operator` enables all of the above for an operator-controlled session. Policy decisions are written without prompts/results/tokens to `~/Library/Application Support/OpenBurnBar/mcp-policy-audit.jsonl` unless `OPENBURNBAR_LOCAL_MCP_DISABLE_AUDIT=true` is set.

## Setup

The repo-scoped `openburnbar` entry in [`.mcp.json`](../../.mcp.json) uses the
memory-only launcher and needs no Rust toolchain:

```bash
./tools/openburnbar-mcp/bootstrap-memory.sh
```

On its first run, `launch-memory.sh` calls `bootstrap-memory.sh`, creates
`.venv`, and installs only `requirements.txt`. It prefers Python 3.12, then
3.11, then 3.13, before accepting any `python3` that is 3.11 or newer. It does
not invoke Cargo, build the domain-core binding, or build the static parser.
MCP clients bootstrap it automatically; the command above is only needed when
you want to prepare a fresh checkout before the first MCP connection.

For the full Project Code Memory static tier, use the existing setup path:

```bash
cd tools/openburnbar-mcp
./setup.sh
```

This creates the Python venv, installs deps, builds or verifies the
`crates/project-code-static-parser` release helper for the Project Code Memory
static tier, and symlinks the `burnbar-operator` Hermes skill into
`~/.hermes/skills/` (if `~/.hermes` exists). Set
`OPENBURNBAR_MCP_ALLOW_LEXICAL_ONLY=true` only when you explicitly want setup to
continue without the static parser helper.

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

**C. Local SQLite — no network, no auth.** Default read-only access to
`~/Library/Application Support/OpenBurnBar/openburnbar.sqlite`; opt-in env
flags are required for plaintext bodies, cloud decrypt/sync, local writes, or
process spawning.

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
| `burnbar_remember` | **Write** one durable memory (kind, scope, tags, entities, metadata, `supersedes`, `expires_at`, `immutable`); secrets redacted, PII kept by default; mirrored to the daemon ledger when reachable |
| `burnbar_memorize` | **Write** durable memories from a conversation, text, or pre-extracted `facts` (the mem0 `add()` equivalent): extraction → gate → injection screen → ADD / UPDATE / NONE / DELETE reconciliation; idempotent per input |
| `burnbar_recall` | Hybrid BM25 + vector recall with reciprocal-rank fusion and salience rerank; kind/tag/entity/metadata/date filters; personal-scope memories follow the user across projects; bodies and free-form auxiliary fields wrapped as untrusted content |
| `burnbar_recall_pack` | Token-budgeted, prompt-ready block of the most relevant memories, wrapped as untrusted retrieved data |
| `burnbar_memory_get` / `burnbar_memory_list` | Read one memory (optionally with history) / page through memories with filters and ordering; quarantined rows are hidden by default and explicit review reads are wrapped |
| `burnbar_memory_update` | **Write** patch a memory in place (stable id, history row, re-embed) |
| `burnbar_memory_history` | Per-memory change history with wrapped before/after bodies and metadata |
| `burnbar_memory_review` | **Write** approve / quarantine / reject (injection suspects start quarantined) |
| `burnbar_forget` | **Write** hard-delete one memory (body, vectors, history, relations, vault) with a label-only audit event; mirrored to the daemon when reachable |
| `burnbar_forget_all` | **Write** two-step bulk delete for a project (optionally scope / kinds); requires `confirm="DELETE"` |
| `burnbar_memory_entities` / `burnbar_memory_relations` | Entities mentioned by memories, and heuristic (subject, predicate, object) relations |
| `burnbar_memory_export` / `burnbar_memory_import` | JSON export (requires `sensitive_read`; retained secrets excluded unless asked) and machine-round-trippable project export/import; `all_projects` exports are diagnostic archives and cannot be flattened into one project; trust wrappers are provenance-checked, decoded, then every value passes the normal import gate again |
| `burnbar_memory_reindex` | **Write** embed memories missing a vector for the active model version; purge stale-version vectors |
| `burnbar_audit_trail` | Read the label-only memory audit hash chain, with chain verification |
| `burnbar_memory_analytics` | Counts by kind / scope / sensitivity / review status, embedding coverage, vault entries, policy |
| `burnbar_index_project` | **Write** a local-only, project-partitioned code index into the existing search substrate; accepts `storage_budget_bytes` |
| `burnbar_watch_project` | **Write** start daemon-owned automatic reindexing for source/git-ref changes |
| `burnbar_search_code` | Lexical/path search over local-only indexed project code; returns `semanticAvailable=false` until a real local embedding provider is configured |
| `burnbar_context_pack` / `burnbar_code_context_pack` | Build token-budgeted code context packs |
| `burnbar_get_symbol` | Symbol lookup with `exact_lsp` / `static_tree_sitter` / `lexical_fallback` tier evidence |
| `burnbar_find_references` | Reference lookup for a project symbol, using exact LSP when a configured language server answers for the current buffer |
| `burnbar_call_graph` | Lexical-tier call graph edges |
| `burnbar_diagnostics` | Read cached diagnostics for a project |
| `burnbar_index_status` | Read project-scoped code-memory index status |
| `burnbar_explore` | **Write** auto-index if needed, then search and return a context pack |
| `burnbar_memory_doctor` | Check local memory/code schema, write mode, and index health |
| `burnbar_list_project_memory` | List project memory snapshots with source counts and freshness |
| `burnbar_get_project_memory` | Read one project memory snapshot by slug |
| `burnbar_cloud_sync_project_memory` | Sync a local project memory snapshot through the encrypted cloud path |
| `burnbar_cloud_delete_project_memory` | Delete one encrypted cloud Project Memory snapshot by vault-derived opaque docID |
| `burnbar_get_conversation` | Full row + `fullText` for one id |
| `burnbar_recent_usage` | Recent `token_usage` rows |
| `burnbar_project_summary` | Per-project cost + session aggregation over a rolling window |
| `burnbar_chat_messages` | In-app `chat_messages` tail |
| `burnbar_record_hermes_usage` | **Write** an idempotent row to the OpenBurnBar daemon usage ledger |
| `burnbar_resolve_usage_ledger_path` | Show the ledger path the writer will use |
| `burnbar_query_spend` | Query spend by provider, model, project, account, and time window |
| `burnbar_budget_status` | Summarize active budget gates and current burn state |
| `burnbar_spend_forecast` | Forecast spend against configured budget limits |
| `burnbar_budget_audit` | Read budget gate audit events for recent enforcement decisions |
| `burnbar_set_budget_limit` | **Write** a daemon-backed budget limit |
| `burnbar_pause_budget_gate` | **Write** a pause window for one budget gate |
| `burnbar_resume_budget_gate` | **Write** a previously paused budget gate back into enforcement |
| `burnbar_list_resumable_conversations` | Return recent conversations eligible for native or ported resume |
| `burnbar_resume_conversation` | Compose a native command hint or deterministic cross-harness briefing |
| `burnbar_spawn_resume` | Spawn the selected native or ported resume command after an explicit tool call |
| `ministry_list_wands` | List Headmaster/Pareto wands or a sanitized local wand store |
| `ministry_validate_wands` | Validate the local Ministry wand store without writing |
| `ministry_save_wands` | **Write** an operator-gated sanitized Ministry wand store |
| `ministry_list_launchable` | List droid launch candidates from Factory `customModels[]` plus the built-in allowlist |
| `ministry_provider_quota` | Read authenticated local-gateway model quota state |
| `ministry_select_model_for_wand` | Select a model by wand policy, optionally proving headless commit ability |
| `ministry_select_models_for_wand` | Select N models by wand policy with optional provider diversity and proof |
| `ministry_smoke_probe` | Spawn a disposable droid probe and verify it lands a commit |
| `ministry_build_droid_command` | Build a droid worker command with namespaced disabled tools and a done marker |
| `ministry_collect_result` | Classify worker completion from `result.done`, JSON output, and HEAD-vs-base |
| `ministry_cleanup_plan` | Emit post-capture cleanup commands for worktree, branch, files, and exact transcript candidates |
| `castle_list_runtimes` | List Castle runtime Houses with install/auth preconditions |
| `castle_list_launchable` | List runtime-stamped `(runtime, model)` candidates across supported CLI Houses |
| `castle_select_models_for_wand` | Select N Castle workers for a wand, optionally proving each with a disposable landed-commit probe |
| `castle_smoke_probe` | Run a disposable runtime probe and verify it lands a scoped commit |
| `castle_build_command` | Build a wrapped worker command with prompt, result, done, stderr, and status sentinels |
| `castle_collect_result` | Classify a Castle worker from `result.done`, parsed completion, and HEAD-vs-base; writes Swift-readable status JSON |
| `castle_status_snapshot` | Read Castle status records for dashboard/debug surfaces |
| `castle_seed_worktree_isolation` | Seed `.git/info/exclude` with known agent scratch paths before launching a worker |

## Local memory engine

The memory tools above are served by `memory_engine.py`, an MCP-owned store at
`~/Library/Application Support/OpenBurnBar/openburnbar-memory.sqlite`
(override with `OPENBURNBAR_MEMORY_DB_PATH`). Design and the gap analysis
against mem0 / Mixedbread: [`docs/superpowers/2026-09-02-memory-mcp-v2-design.md`](../../docs/superpowers/2026-09-02-memory-mcp-v2-design.md).

- **Works without the daemon.** Production daemons reject this process as an
  unsigned peer and the app database is SQLCipher-encrypted, so the engine is
  the authority for the local MCP. Committed non-secret memories are mirrored
  to the daemon ledger through the signed `openburnbar-cli memory-remember` /
  `memory-forget` couriers when installed; unsigned development builds fall
  back to the daemon socket. Every write reports `mirror.status`
  (`mirrored | partial | peer_rejected | unreachable | rejected | disabled |
  skipped`). `partial` is used only for a multi-row lifecycle operation whose
  failed deletes remain retryable.
  A mirrored row records the daemon's own content-derived id, and
  `burnbar_forget` uses that id for the daemon-side forget (a row that was
  never mirrored reports `mirror.status: skipped` instead of sending the
  engine's local id). If the daemon is unavailable, a metadata-only tombstone
  retains its id and original project path for a later `burnbar_forget` retry,
  and clears only after the daemon reports `localDeleted: true`. Mirror
  provenance uses only the engine-gated `sourceRef`, never the caller's raw
  source string. Only permanent approved rows are mirrored; expiring,
  quarantined, rejected, and secret rows stay local. Personal-memory updates
  reconcile the previous daemon copy before remirroring in the row's owning
  project.
- **Legacy daemon memories migrate themselves.** Memories written by the
  pre-engine `burnbar_remember` or by the app into the daemon-owned
  `agent_memories` store are imported into the engine store once, on the
  first `burnbar_recall` / `burnbar_recall_pack` / `burnbar_memory_list` for
  a project (gated and reconciled like any other write, `sourceKind:
  legacy_daemon`, `metadata.legacyMemoryID`). The outcome is reported as
  `legacyMigration` on those responses and in `burnbar_memory_doctor`; when
  the app database is unreadable (signed install) it is a status, never an
  error. Migration paginates the complete active daemon ledger rather than
  stopping at 2,000 rows. Transient unavailable or capability-disabled
  outcomes and recoverable gate rejections are not receipted or cached and
  retry on the next read. Successful imports preserve the daemon memory id and
  original project path so a later forget deletes the legacy daemon row too.
- **Encrypted at rest.** Bodies and history bodies are AES-256-GCM sealed with
  a key the engine owns (`openburnbar-memory.key`, mode 0600, published
  atomically so two first-run processes cannot truncate each other's key, or
  `OPENBURNBAR_MEMORY_KEY_BASE64`). The database and its WAL / SHM sidecars are
  mode 0600. A missing or invalid key for a populated store fails closed rather
  than replacing the only key reference. Vectors and metadata are plaintext, the same posture as the app's
  on-disk `VectorIndexes/`. No FTS table is written; BM25 runs in-process over
  one project's decrypted bodies. Reinforcement history and the ingest replay
  table hold hashes and labels, never bodies.
- **Embeddings.** `OPENBURNBAR_MEMORY_EMBEDDING_PROVIDER=auto|ollama|none`
  (default `auto`), model `OPENBURNBAR_MEMORY_EMBEDDING_MODEL`
  (default `nomic-embed-text`; `mxbai-embed-large` works too), Ollama at
  `OPENBURNBAR_OLLAMA_BASE_URL` (default `http://127.0.0.1:11434`). Run
  `ollama pull nomic-embed-text` once. Without a provider recall is lexical
  only and `burnbar_memory_doctor` says so. Vectors carry the model version and
  are never compared across versions; `burnbar_memory_reindex` re-embeds.
- **Extraction.** `burnbar_memorize` prefers `facts` the calling agent already
  extracted (free, highest quality). Otherwise `OPENBURNBAR_MEMORY_EXTRACTOR` =
  `heuristic` (default, deterministic, offline) | `claude` (`claude -p`, the
  user's own plan) | `ollama` (`OPENBURNBAR_MEMORY_EXTRACTOR_MODEL`) | `none`
  (store the raw text as one `note`). Selecting `claude` or `ollama` through
  the tool's `extractor` argument (rather than the env) needs the
  `memory_llm_extract` capability (`OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_LLM_EXTRACT=true`
  or the operator profile), and `claude` additionally needs `spawn_process`.
  External extractors only ever receive a gated transcript: secrets are
  redacted first, and nothing is sent when the scanner cannot run.
- **Secrets and PII.** `OPENBURNBAR_MEMORY_SECRET_POLICY` = `redact` (default:
  keep the fact, replace the secret with `[REDACTED:<label>]`) | `reject` |
  `retain`. `OPENBURNBAR_MEMORY_PII_POLICY` = `keep` (default; your own email
  in your own local memory is useful context) | `redact` | `reject`. SSNs and
  card numbers are always redacted. The gate covers tags, entities, metadata,
  and `source_path` as well as the body, and base64 / hex encoded secrets are
  decoded and redacted at their surface span. A secret that only appears once
  line continuations or adjacent string literals are joined cannot be redacted
  in place, so `redact` refuses that write (`SECRET_DETECTED`) rather than
  storing a reconstructable form. In `retain` mode, re-remembering the same
  sentence with a rotated secret keeps one memory and replaces the vault
  entry (`secretRotated: true`). Prompt-injection screening covers tags,
  entities, metadata, and `source_path` as well as the body; a hit in any of
  them quarantines the memory.
- **Untrusted recall boundary.** Prompt-injection sentinels in the body, tags,
  entities, metadata keys/values, or `source_path` quarantine the row. Default
  recall/get/list/entity/relation surfaces exclude quarantined rows, including
  legacy rows detected by the read-time backstop. Explicit review reads keep
  their JSON shape but wrap free-form values, injection-bearing metadata keys,
  and history metadata as untrusted data.
  `burnbar_memory_export` applies the same shape-preserving wrappers, including
  to quarantined rows and retained secret text.
- **Experimental: retain secrets.** `retain` stores the verbatim text in an
  encrypted vault table, keeps a redacted, searchable body in the main store,
  and hides the memory from default recall. It needs
  `OPENBURNBAR_LOCAL_MCP_ENABLE_SECRET_RETAIN=true` (never granted by the
  operator profile) to write, and `sensitive_read` plus `include_secrets=true`
  to read back. Retained memories are never mirrored or exported by default.
- **Write capability.** `memory_write` is on by default when
  `BURNBAR_MCP_TOOLSET=memory`, and also granted by `local_write` or the
  operator profile. Set `OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_WRITE=false` to
  force it off. Writes are rate-limited under the `memory` family.
- **Structured refusals.** Malformed JSON in `filters`, `metadata`, `facts`,
  or `memories` returns `INVALID_JSON_ARGUMENT` (never a silently widened
  query); filter `AND` / `OR` clauses must be non-empty arrays of objects.
  Invalid `expires_at` values are rejected instead of becoming immortal rows.
  Editing a memory's text to match another active memory returns
  `DUPLICATE_BODY`; re-remembering text whose memory was rejected in review
  returns `NONE` with `PREVIOUSLY_REJECTED` (re-approve it with
  `burnbar_memory_review`), while an expired duplicate is reactivated
  (`UPDATE`, `reactivated: true`), and a fact that reverts to an earlier
  statement (A, then B, then A again) brings the retired row back under its
  original id. `tags=[]` / `entities=[]` on `burnbar_memory_update` clear the
  field; omit the argument to keep it. `burnbar_recall_pack` budgets the whole
  serialized pack (floor 192 tokens: the envelope plus one truncated line),
  keeps each memory on one line, neutralizes pack sentinels inside bodies, and
  reinforces only memories that actually fit. Import skips retired rows from
  historical exports so obsolete facts cannot become active again.
- **Cross-store lifecycle.** Supersession, negation/`DELETE`, quarantine, and
  confirmed bulk deletion forget
  the corresponding daemon mirrors. Failed daemon deletes retain only the
  local-to-daemon id tombstone and can be retried after the local row is gone.
  Update, review, and import writes also reconcile the mirror; body changes
  retire the old content-derived daemon id before publishing the replacement,
  and the recorded body hash makes an interrupted transition safely retryable.
  A project-scoped reindex leaves other projects' old-version vectors intact,
  and a transient Ollama startup miss is retried without restarting the MCP.
  Concurrent duplicate inserts serialize lookup plus insertion, and embedding
  HTTP calls complete before SQLite write locks are taken.
- **Quality.** `eval_memory.py` scores lexical vs hybrid recall on a 40-memory
  / 30-paraphrase gold set against your local Ollama model.

Project Code Memory is local-only by default. Indexing uses a shared
Swift/Python secret-scanner corpus, Git exclude-standard ignore semantics when
the project is a Git worktree, manifest-backed delta indexing for
unchanged/removed files, Git fingerprint-backed Project ID v2 with path aliases
for moved checkouts, and untrusted-content wrappers on returned source text.
Project-code search reports `semanticAvailable=false` until a real local
embedding provider is configured. The Rust helper
`crates/project-code-static-parser` provides the static tier for Swift,
TypeScript/TSX, and Python. Set `OPENBURNBAR_CODE_LSP_COMMANDS` to a JSON map
like `{"python":["pyright-langserver","--stdio"],"swift":["sourcekit-lsp"]}` to
enable opt-in `exact_lsp` symbol/reference tiers; the helper falls back when the
language server is unavailable, slow, or stale.

Code-index write tools are explicit, daemon-scoped, and disabled until
`OPENBURNBAR_LOCAL_MCP_ENABLE_LOCAL_WRITE=true` or
`OPENBURNBAR_LOCAL_MCP_PROFILE=operator` is set. Code writes are
fail-closed: `burnbar_index_project`, `burnbar_watch_project`, and
`burnbar_explore` require the daemon socket and do not fall back to direct
SQLite writes. Memory writes (`burnbar_remember`, `burnbar_memorize`,
`burnbar_forget`, …) go to the MCP-owned memory engine store described above
and never touch the app database; the daemon mirror is best-effort.
`burnbar_record_hermes_usage` never touches the SQLite DB. The writer is daemon-first: when a local OpenBurnBar daemon is
reachable on its UNIX socket
(`~/Library/Application Support/OpenBurnBar/openburnbar-daemon.sock`) it sends
the row through the `daemon.usage.record` RPC so the daemon's in-memory
idempotency cache stays consistent. When the daemon is offline the writer
falls back to a file-locked append against
`~/Library/Application Support/OpenBurnBar/usage-events.jsonl`. Either way,
re-sending the same `idempotency_key` will not double-count the spend.

The cloud search tools are opt-in twice: configure credentials only for agents
you trust with session-log recall, and enable
`OPENBURNBAR_LOCAL_MCP_ENABLE_CLOUD_DECRYPT=true` for the local MCP process:

```bash
export OPENBURNBAR_FIREBASE_PROJECT_ID=burnbar
export OPENBURNBAR_FIREBASE_ID_TOKEN="<Firebase Auth ID token>"
export OPENBURNBAR_CLOUD_VAULT_KEY_BASE64="<32-byte vault key, base64>"
```

The MCP process keeps the plaintext query and vault key local. Firebase
receives only keyed token/semantic hashes, returns encrypted result envelopes,
and this MCP process decrypts titles, snippets, and requested bodies on-device.
Project Memory cloud sync uploads only sealed snapshot payloads under
vault-derived opaque document IDs. `burnbar_cloud_delete_project_memory`
removes the hosted sealed snapshot and returns the backend's content-free
tombstone receipt; local Project Memory stays authoritative and unchanged.

`burnbar_resume_conversation` is print-only by default and returns either a
native command hint, a rendered cross-harness briefing, or a structured error.
`burnbar_spawn_resume` is intentionally separate so agents must make an explicit
second tool call before launching a process.

## Castle multi-runtime fan-out

Castle extends the Ministry selector from `model` to `(runtime, model)` without
weakening the success gate. A worker counts as landed only when the done marker
exists, the runtime parser says the run did not error, and the worker worktree
HEAD differs from the recorded base SHA. The same verdict is written into the
Castle status record that AgentLens reads; dashboard green states must come from
`landsCommit`, not from process exit or a generic completed phase.

Runtime wrappers write durable sentinels under
`~/Library/Application Support/OpenBurnBar/castle/runs/<run-id>/` unless a
caller supplies explicit paths. AgentLens can discover recent `status.json`
records from that directory, or can be pointed at exact files with
`OPENBURNBAR_CASTLE_STATUS_PATHS` using colon-separated paths. See
[`docs/THE_CASTLE.md`](../../docs/THE_CASTLE.md) for adapter contracts,
status-record semantics, and launch-readiness checks.

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
