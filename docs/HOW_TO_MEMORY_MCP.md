# How to use the Memory MCP

The local Memory MCP gives your coding agents a memory that lives on this Mac:
one encrypted SQLite store, 45 MCP tools, no account, no network.

This page answers the six questions people actually ask, in the order they ask
them. Every answer names the file that proves it, so you can check the claim
rather than trust it.

> **Which memory is this?** Two different things wear the word "memory".
> This page is the **local** engine in
> [`tools/openburnbar-mcp/`](../tools/openburnbar-mcp/README.md) — on this Mac,
> no sign-in, `burnbar_remember` / `burnbar_recall` / `burnbar_forget`.
> The **hosted**, end-to-end-encrypted Pensieve memory (`mcp.burnbar.ai`, Cloud
> Pro) is a separate surface with its own guide:
> [`docs/MEMORY_MCP_GUIDE.md`](MEMORY_MCP_GUIDE.md). The illustrated tour of this
> one is [burnbar.ai/memory](https://burnbar.ai/memory).

Reference material, not duplicated here: the full behaviour contract and every
client's config block live in
[`tools/openburnbar-mcp/README.md`](../tools/openburnbar-mcp/README.md); Codex
CLI scope, recovery paths and bearer-token handling live in
[`docs/CODEX_AGENT_ONBOARDING.md`](CODEX_AGENT_ONBOARDING.md).

---

## The short version

The same four questions are answered with per-surface detail, diagrams and the
live tool atlas at
[burnbar.ai/memory#duties](https://burnbar.ai/memory#duties) — and that section
is where the app's first-run memory step sends you. This page is the long form:
it names the file behind each answer so you can check it in this checkout.

| Question | Answer |
| --- | --- |
| Is it on by default? | The engine is; it just has nothing to do until an agent calls it. Nothing is collected, and no store is created, until something writes a memory. |
| Do I have to install it into my coding agents? | Yes. One click for the seven clients the app knows how to wire; a config block by hand for the rest. |
| Once installed, does it collect automatically? | Only when an agent calls a memory tool. The Claude Code `SessionEnd` hook that collects without being asked is opt-in and off until you add it yourself. |
| Does it prune itself? | No. Nothing is ever deleted on a timer. `expiresAt`, review, `burnbar_forget` and supersession are the tools; every one of them is something you or your agent invokes. |

---

## 1 · Is it on by default?

There are four separate things people mean by "on". They have four different
answers.

### The local engine and its database — on, but empty

The engine ships inside the MCP server. There is no daemon to start, no
account, no service to enable. It becomes real the first time something writes
a memory: that write creates
`~/Library/Application Support/OpenBurnBar/openburnbar-memory.sqlite` (override
with `OPENBURNBAR_MEMORY_DB_PATH`) and its key file
`openburnbar-memory.key`, both mode `0600`. Bodies and history bodies are
AES-256-GCM sealed with that key. Until then there is no store at all.

Writes are enabled by default *for the memory toolset only*: `memory_write` is
granted when `BURNBAR_MCP_TOOLSET=memory` — which is exactly what the one-click
installer and the repo's own `.mcp.json` set — and also by `local_write` or
`OPENBURNBAR_LOCAL_MCP_PROFILE=operator`. An explicit
`OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_WRITE=false` always wins.

*Proof:* `tools/openburnbar-mcp/server.py` — `_memory_write_enabled()`;
`tools/openburnbar-mcp/README.md` § Local memory engine.

### The rest of the server's capabilities — off

The local MCP fails closed. Cloud decrypt, cloud sync, full plaintext
conversation reads, code-index writes and process spawn are all refused until
you export the matching `OPENBURNBAR_LOCAL_MCP_ENABLE_*` variable for the shell
session that needs it. `OPENBURNBAR_LOCAL_MCP_PROFILE=operator` grants that set
in one go — and deliberately does **not** grant secret retention.

*Proof:* `tools/openburnbar-mcp/README.md`, first section.

### The daemon's session watcher — running, and it writes no memories

If you run the OpenBurnBar daemon, its Pensieve watcher starts with it and
watches `~/.claude/projects` for settled `*.jsonl` files. Two things are worth
knowing:

- It stops before doing anything unless a 32-byte cloud vault key is available
  for a signed-in member. No sign-in, no vault key, no activity at all.
- When it does run, a Claude session file produces exactly one **sentinel**:
  a `{sessionPath, modifiedAt, sourceKind, schemaVersion}` JSON file, mode
  `0600`, under `~/.openburnbar/pensieve-queue/session-end-signals/`. The
  daemon does not read the transcript and does not extract anything —
  extraction needs your model, so it is deferred to the app, behind consent.

The watcher is not what fills `burnbar_recall`. It feeds the hosted Pensieve
knowledge path, which is a different store from the local engine described
here.

*Proof:*
`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/PensieveKnowledgeWatcher.swift` —
the `vaultKeyProvider` guard in `scan()`, and `signalSessionEnds(in:)`;
`OpenBurnBarDaemon/Sources/OpenBurnBarDaemonExecutable/OpenBurnBarDaemonMain.swift`
— `makePensieveKnowledgeWatcher`.

### Agent access — off until you install it

No agent can reach any of this until the MCP server is in that agent's config.
That is the next section, and it is the step people miss.

---

## 2 · Do I have to install it into my coding agents?

**Yes.** Installing BurnBar does not give your agents memory; wiring the MCP
server into each agent does.

| Agent | How it gets installed | Where |
| --- | --- | --- |
| **Claude Code** | One click in the app | Settings › Agents › **CLIs** → "Agent memory (MCP)" — writes `~/.claude.json` |
| **Cursor** | One click in the app | same card — writes `~/.cursor/mcp.json` |
| **Codex CLI** | One click in the app | same card — writes a sentinel-fenced `[mcp_servers.*]` block into `~/.codex/config.toml` |
| **Factory Droid** | One click in the app | same card — writes `~/.factory/mcp.json` |
| **Antigravity CLI** | One click in the app | same card — writes `~/.gemini/config/mcp_config.json` |
| **Gemini CLI** | One click in the app | same card — writes `~/.gemini/settings.json` |
| **Muse** | One click in the app | same card — writes `$XDG_CONFIG_HOME/muse/settings.json` (default `~/.config/muse/settings.json`) |
| **Claude Desktop** | By hand | the JSON block in [`tools/openburnbar-mcp/README.md` § Claude Desktop](../tools/openburnbar-mcp/README.md) → `~/Library/Application Support/Claude/claude_desktop_config.json` |
| **Hermes Agent** | By hand | the YAML block in [`tools/openburnbar-mcp/README.md` § Hermes Agent](../tools/openburnbar-mcp/README.md) → `~/.hermes/config.yaml` |
| **Agy, and anything else** | Not wired by the installer today | Configure by hand if the tool supports MCP. We do not publish a config path for these, because we have not verified one. |

The one-click card is honest about failure: it probes each client's real config
file for the current state, names the exact file the button will modify, and if
no server can be resolved on this Mac it says why instead of writing an entry
that points at nothing.

Every path the installer writes sets `BURNBAR_MCP_TOOLSET=memory`, which serves
the 45-tool memory surface instead of all 95 tools the server registers.

*Proof:* `AgentLens/Views/Settings/MCPInstallCard.swift`;
`AgentLens/Services/CLIBridge/MCPClientWiring.swift` — `MCPClientWiringTarget`
is exactly `{claudeCode, cursor, codex, droid, antigravity, geminiCLI, muse}`,
and `MCPServerLaunch.toolset` defaults to `"memory"`.

### Doing it by hand anywhere

Point the client at `tools/openburnbar-mcp/launch-memory.sh` with
`BURNBAR_MCP_TOOLSET=memory` in its env — the same shape the repo's
[`.mcp.json`](../.mcp.json) uses. The launcher bootstraps its own virtualenv on
first run (Python only; no Rust, no Cargo). To avoid losing your first session
to that cold start, run it once yourself:

```bash
./tools/openburnbar-mcp/bootstrap-memory.sh
```

---

## 3 · Once installed, does it collect automatically?

Three lanes, and only one of them is automatic without you doing anything more.

### Lane A — the agent calls the tools (on, by default)

This is the normal path. Your agent decides a fact is durable and calls
`burnbar_remember`, or hands a conversation to `burnbar_memorize`. Nothing is
scheduled: a memory exists because a tool call made it exist. This works the
moment the server is installed, because `memory_write` is on for the memory
toolset.

The honest limitation: agents forget to call memory tools, because the moment
worth remembering is the moment they are thinking about something else.

### Lane B — the Claude Code `SessionEnd` hook (opt-in, off until you add it)

This closes that gap. When a Claude Code session ends, the hook feeds the
transcript to the same `burnbar_memorize` path the tool uses. Turn it on by
adding this to your **user-level** `~/.claude/settings.json`, substituting your
own checkout path:

```json
{
  "hooks": {
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "\"$HOME/Projects/BurnBar/tools/openburnbar-mcp/hooks/claude-code-session-end.sh\"",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

Use the absolute path. `$CLAUDE_PROJECT_DIR` expands to whatever project the
session ran in, not to your BurnBar checkout, so the hook would go looking for
the script inside every unrelated repository. Inside the checkout itself — in
`.claude/settings.local.json` — the repo-relative form is the correct one.

What it does: keeps only user and assistant prose (tool calls, results,
thinking blocks and wrapper tags are dropped), trims to the last 400 messages /
200,000 characters, memorizes against the session's working directory, and is
idempotent on the transcript's content hash. It never blocks session end: a
20-second budget, one JSON status line, exit 0 in every case but a usage error.
The status line is a receipt — counts, ids, status codes — never memory text.

Expect the very first session end on a fresh machine to report `timeout` and
write nothing: bootstrapping the interpreter eats the budget. Running the
bootstrap once by hand skips that lost run.

`OPENBURNBAR_MEMORY_SESSION_HOOK=off` disables it entirely — nothing is read
and no store is created.

*Proof:* `tools/openburnbar-mcp/README.md` § Automatic collection from Claude
Code sessions; `tools/openburnbar-mcp/hooks/claude-code-session-end.sh`;
`tools/openburnbar-mcp/memorize_transcript.py`.

### Lane C — the daemon watcher (a signal, not a collection)

Covered in § 1. It notices that a Claude session file settled and drops a
sentinel. Nothing is extracted, nothing reaches the local memory store, and
nothing happens at all without a signed-in vault key. If you are waiting for
memories to appear because "the daemon is watching", you are waiting for the
wrong thing — install lane A, and add lane B if you want collection without
asking.

### A fourth lane, if you sync

If you have turned on "Sync memories to my other devices", memories another
device backed up land in your engine only when something calls
`burnbar_memory_sync_pull`. There is an opt-in `SessionStart` hook for that too,
gated a second time behind `OPENBURNBAR_MEMORY_SYNC_HOOK=on`. See
[`tools/openburnbar-mcp/README.md` § Draining synced memories at session
start](../tools/openburnbar-mcp/README.md).

---

## 4 · Does it prune itself?

**No.** There is no retention sweep, no TTL job, no background compaction, and
no size cap that starts deleting. A memory you write today is still there in a
year unless something explicitly removes it.

What exists instead — all of it invoked, never scheduled:

| Mechanism | What it actually does |
| --- | --- |
| `expiresAt` on a memory | A **read-time filter**, not a deletion. Past its timestamp the row stops appearing in recall, lists and packs — and stays in the database. Re-remembering the same fact reactivates it (`UPDATE`, `reactivated: true`). An invalid `expiresAt` is rejected rather than becoming an immortal row. |
| Supersession | A fact that replaces another retires the old row: it gets `valid_to` and `superseded_by`, drops out of recall, and stays readable in history. Nothing is overwritten in silence. |
| `burnbar_memory_review` | Approve, quarantine or reject. Injection suspects start quarantined and are excluded from recall until you work the queue. Rejected is a decision, not a delete. |
| `burnbar_forget` | The only single-row **hard delete**. It removes the memory row, its vectors, its history, its relations, its vault entry, its aliases and its sync marks, and records a label-only audit event. A forget receipt is kept so a synced copy cannot resurrect the fact. |
| `burnbar_forget_all` | Two-step bulk delete for a project. The preview returns a `selectionToken`; the confirmation needs `confirm="DELETE"` plus that token, and is refused if the matching rows changed underneath it. |
| `burnbar_memory_doctor` | Reports health. `apply=True` prunes exactly two housekeeping classes — aged orphan bodies from the legacy daemon store, and aged parked supersedes — and never deletes a memory or a finding. |

So: decide what you want gone and say so. Salience decay changes *ranking*
(30-day half-life for `event` and `todo`, 365 days otherwise); it never removes
anything.

*Proof:* `tools/openburnbar-mcp/memory_engine/_util.py` — `_is_expired`, used
as a filter in `_read.py`;
`tools/openburnbar-mcp/memory_engine/_lifecycle.py` — `forget` / `_purge` /
`forget_all`; `tools/openburnbar-mcp/memory_engine/_admin.py` — `doctor`'s
`apply` bound. There is no scheduler anywhere in `memory_engine/`.

---

## 5 · How do I test it in ten minutes?

A literal script. Every tool name below is in `MEMORY_TOOLSET`.

**1 · Install it (2 min).**
Open BurnBar › Settings › Agents › CLIs and click Install on the client you use,
or paste the config block from
[`tools/openburnbar-mcp/README.md`](../tools/openburnbar-mcp/README.md).
Then run the bootstrap once so the first session is not a cold start:

```bash
./tools/openburnbar-mcp/bootstrap-memory.sh
```

**2 · Confirm the server is there (1 min).**
`/mcp` in Claude Code or Codex; Settings → MCP in Cursor. You should see
`openburnbar` with 45 tools. Then ask the agent:

> Run `burnbar_memory_doctor`.

Schema version, write mode, embedding provider and index health come back. If
it says recall is lexical-only, that is true and fine — `ollama pull
nomic-embed-text` upgrades it later. If it says a signed install rejected this
process as a daemon peer, that is expected and is a status, not an error: the
engine is the authority for the local MCP.

**3 · Remember one fact (1 min).**

> Remember that this project generates its Xcode project with xcodegen.

The agent should call `burnbar_remember`. Expect `ADD`, a memory id, a kind,
and a `mirror.status`.

**4 · Start a new session, and ask it differently (2 min).**
Quit the session. Open a fresh one — ideally in a *different* client, to prove
the store is shared rather than the context window.

> How is the Xcode project file produced here?

The agent should call `burnbar_recall` and return your memory with a score and
a `why` block naming what matched: `lexical`, `semantic`, or both. If only the
exact original wording works, you have no embedding provider — pull a local
model and run `burnbar_memory_reindex` once.

**5 · Read it back in the console (2 min).**

> List my memories for this project with `burnbar_memory_list`, then
> `burnbar_memory_get` the xcodegen one with its history.

You get the row, its kind, its scope, its review status, and every change ever
made to it.

**6 · Forget it, and prove it is gone (2 min).**

> `burnbar_forget` that memory id.

Expect `status: ok` and
`purged: ["memory", "vector", "history", "relations", "vault"]`. Now ask the
question from step 4 again in a new session: recall returns nothing. Run
`burnbar_memory_list` again: the row is absent. Run `burnbar_audit_trail`: the
label-only `memory.forget` event is there, with no memory text in it.

That is the whole loop — write, recall across sessions, inspect, delete,
verify.

---

## 6 · What leaves my machine?

**Nothing, by default.** With nothing turned on there is no account, no
network call, and no BurnBar server in the path. Memory bodies, the
transcripts they were extracted from, your vectors, retained secrets,
quarantined rows and repository knowledge all stay on this Mac.

Two features can send something, each off by default, each needing its own
consent in the app, each fail-closed — no entitlement, no consent, or no daemon
means zero network calls and unchanged local behaviour:

- **Cloud models for memory.** Redacted memory facts and your questions go from
  your Mac to the provider you picked, on your own key or your own CLI
  subscription. Raw transcripts, anything the secret filter caught, and the
  sealed vault are never sent.
- **Encrypted backup of approved memories.** Approved, non-secret memories
  replicate to your own namespace, sealed. The stored document holds a sealed
  blob, an opaque id, keyed source hashes, a kind, a review status and three
  timestamps — and the server's own rules forbid the rest.

The full field-by-field breakdown, including the tier language and what is
**not shipped yet**, is on [burnbar.ai/memory](https://burnbar.ai/memory) under
"The boundary", and in [`docs/PRIVACY.md`](PRIVACY.md) § Optional Memory Backup
and Device Sync.

---

## Where to go next

- [`tools/openburnbar-mcp/README.md`](../tools/openburnbar-mcp/README.md) — the
  behaviour contract: every tool, every capability switch, every config block.
- [burnbar.ai/memory](https://burnbar.ai/memory) — the same story with the
  measurements, the tool atlas, and the device boundary.
- [`docs/CODEX_AGENT_ONBOARDING.md`](CODEX_AGENT_ONBOARDING.md) — Codex CLI
  scope, recovery paths, and security guidance.
- [`docs/MEMORY_MCP_GUIDE.md`](MEMORY_MCP_GUIDE.md) — the *hosted* Pensieve
  memory, which is a different surface.
- [`docs/PRIVACY.md`](PRIVACY.md) — the privacy model this page summarises.
