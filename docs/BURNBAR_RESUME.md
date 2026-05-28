# BurnBar Resume

BurnBar Resume lets an MCP client or the `openburnbar` CLI continue a prior
OpenBurnBar-recorded coding-agent conversation in another harness.

## Modes

- Native resume: when source and target are the same native-capable harness and
  the on-disk handle validates, OpenBurnBar returns a command hint such as
  `claude --resume <id>` or `codex resume <id>`.
- Ported resume: every other valid case renders a deterministic Markdown
  briefing from the conversation row, token summary, key files, and indexed
  conversation trail.
- Error: missing sessions, ambiguous bare `sessionId` values, and non-native
  sources without `--as <harness>` return structured recovery guidance.

`burnbar_resume_conversation` is print-only by default. Process launch is
available only through the separate `burnbar_spawn_resume` tool or the
daemon-backed CLI/UI spawn flow.

## Local MCP

The local Python MCP server exposes:

- `burnbar_list_resumable_conversations`
- `burnbar_resume_conversation`
- `burnbar_spawn_resume`

The dispatcher accepts a bare native session id or a composite conversation id
such as `Codex:<thread-id>`. Bare ids that match more than one conversation fail
with `ambiguous_session` so agents do not resume the wrong run.

Native eligibility is data-driven by
`tools/openburnbar-mcp/eligible_providers.json`, which stores the provider
rawValues observed in the OpenBurnBar database. Composite sub-agent ids are never
treated as native handles.

## CLI

```bash
openburnbar resume <sessionId> [--as <harness>] [--model <model>] [--print|--copy|--open|--spawn]
openburnbar resume --query "fuzzy memory" [--as <harness>] [--model <model>] [--print|--copy|--open|--spawn]
OBB Resume "session id or fuzzy memory" [--as <harness>]
obbresume "session id or fuzzy memory" [--as <harness>]
```

The Swift daemon CLI and the Node hosted shim use the same response contract.
`--print` is the default. `--copy` writes the command or briefing to the local
clipboard. `--open` opens a local 0600 temp briefing file for review. `--spawn`
is opt-in and starts the target process detached with ignored stdio and the
conversation working directory when OpenBurnBar knows one.

CLI resume errors print the structured `error: <code>` recovery text and exit
nonzero so shell automation does not mistake a failed resume for success.

The hosted shim supports fuzzy memory resume. `OBB Resume "auth refactor from
last week"` derives local vault-key search hashes and prints the most probable
matching hosted memories first. Each candidate shows title, last date, source
agent, model, project, a short decrypted preview, confidence/match kind, and the
exact `OBB Resume '<id>'` command to run. Raw fuzzy text is not sent to hosted
MCP. Exact ids still resume directly; a single no-space value is tried as an id
first, then falls back to fuzzy hosted search if no exact session exists.

For GUI editor targets, OpenBurnBar does not pretend to inject a prompt into the
editor. Cursor receives `<workspace>/.cursor/burnbar-resume.md`, Windsurf
receives `<workspace>/.windsurf/burnbar-resume.md`, and other GUI targets fall
back to `<workspace>/.openburnbar/burnbar-resume.md`; the app opens the
workspace and leaves the 0600 hint file for manual review/paste.

The current Codex CLI on this machine accepts the briefing as the positional
prompt with `-C <workspace>` when a working directory is known. It does not
advertise the older planned `--system-prompt` flag, so OpenBurnBar uses the
real installed CLI contract instead of emitting a stale argv.

## Hosted Remote MCP

Hosted resume preserves the hosted MCP privacy model:

- the server returns a sealed resume envelope;
- the local shim checks vault-key availability before making the hosted request;
- decrypt and briefing render happen on-device;
- chunk hashes are verified before rendering.
The hosted stdio shim supports the same `--print`, `--copy`, `--open`, and
opt-in `--spawn` modes after local decrypt.

The hosted tools are:

- `burnbar_list_resumable_conversations`
- `burnbar_resume_conversation`

## Storage And Migration

The macOS database stores an optional `conversations.workingDirectory` column so
resume commands can run from the right project. Fresh parser output fills it when
the source harness exposes a cwd. Existing rows are backfilled lazily from
absolute key-file paths in small background batches after app launch.

The canonical conversation manifest and rendered briefing are not written to
SQLite or Firestore. Ported briefings live in memory or in a local 0600 temp file
created for explicit copy/open/spawn flows.
