# Receipts register

The Receipts register is the Mac app's itemized burn slip for a finished
CLI session: cost, cache, git proof, and now the chat that produced it.

Open it from the dashboard **Receipts** section, Settings, or
`openburnbar://receipts`.

## What a slip shows

Every selected receipt prints three things that used to be missing:

1. **A summary of the chat** — conversation `summary`, then
   `summaryTitle`, then the inferred first-prompt title. The generic
   "Session completed successfully" line is never the headline.
2. **The transcript** — the **Chat** lens loads the indexed session
   (user and assistant turns) without decrypting overflow pages for the
   list itself.
3. **Links** — `openburnbar://receipts/{id}` lands on that slip.
   `openburnbar://sessions/{conversation-or-session-id}` opens the same
   row in Session Logs. The Chat and Proof lenses reveal the project
   folder and touched files in Finder when a working directory is known.

The **Slip / Burn / Proof / Chat** picker is a viewing mode. Switching
receipts keeps the lens you chose.

## How receipts join to chats

Receipts have been minted against either `conversations.id` or
`conversations.sessionId`. Lookups try both — Chat tape tries the
overlay conversation id first, then session id, then the receipt's own
key — so a slip minted on either still prints the transcript. List rows
hydrate `promptSummary` from conversation metadata (no `fullText`) so
the ~1,200 already-printed slips pick up a real title without reminting.

Deep links:

| URL | Lands on |
|---|---|
| `openburnbar://receipts` | Receipts register |
| `openburnbar://receipts/{id}` | Same register, that slip selected (and pinned if filters would hide it) |
| `openburnbar://receipts/{id}?lens=chat` | Same slip, Chat tape selected (`slip` / `burn` / `proof` also work) |
| `openburnbar://sessions/{id}` | Session Logs, jumped to that conversation |

`AppCommandRouter` has to list the host (`receipts`, `sessions`) or the
URL never reaches `NavigationCoordinator`. Chat tape, the slip banner,
Proof, the close flyout, and inbox citations all open those URLs through
that router first so a tap stays in-app. Inbox evidence that cites
`openburnbar://receipts/{id}` opens the slip the same way a banner tap
does — scheme and host are case-insensitive, `%20` in the id is
decoded, and a slash inside a subagent id is one path identity
(`parentSession/agentId`), not a truncated first segment. A missing or
deleted receipt id clears the pin instead of leaving the previous slip
selected. Session Logs jumps clear a stale target when the new id does
not resolve.

## Live flyout / notification

`CLISessionCloseMonitor` **prints** a slip when a session goes quiet
(60s) or truly ends. That is not the same as **announcing** it.

The flyout, thermal-printer sound, and system banner fire only when the
provider CLI process, terminal job, or dedicated agent app is gone.
The banner itself is silent; the thermal-printer sample is the only
close sound, including when BurnBar is already in the foreground.
The flyout loads the conversation overlay before it appears so the
headline and Session Logs link use the same join as the register.
Concurrent close events cancel the previous overlay lookup so an older
slip cannot replace a newer flyout. The banner uses that same overlay
when the stored prompt is empty or generic. The Session ID row opens
Session Logs; it does not overwrite the clipboard (Copy chat link does).
Banners are on by default; the first one asks for notification permission
the same way an agent-reply does. The banner title is the chat summary; the body is harness, project,
cost, and duration. Tapping the banner (or its Open action)
opens `openburnbar://receipts/{id}` so the register lands on that slip —
even if Receipts is already open. `?lens=chat` opens Chat tape on that
slip instead. The Chat lens still offers
`openburnbar://sessions/{id}` for the same conversation in Session Logs,
plus Finder reveal for the project folder and touched files.
Process ownership is the house `/bin/ps` classifier shared with Pixel Clock
(`ps -axo comm,args`, header dropped — one snapshot, both surfaces). A 60-second pause while Codex is
still thinking does not pop a notification. Cursor.app staying open does
not count as "still running" — only `cursor-agent` does, including the
binary shipped inside `Cursor.app/Contents/Resources`. Matching is the
**first real executable basename** after wrappers (`node`, `env`, `npx`),
never an intermediate directory, a later argv word (`aider --message grok`),
or a `--model` flag. House skips (`OpenBurnBar`, `/bin/ps`) apply to that
basename only, so `prime-agent --provider openburnbar` and a CLI living
inside this worktree still count. A `~/.cursor` path, `.../factory/docs/...`,
`.../claude/docs/...`, or `git commit -m claude` is not a live process.
A directory named `server` on the Codex path does not hide a live `codex`
binary. Service detection uses the executable name and the first
subcommand (`codex-daemon`, `droid daemon`, `ollama serve`) — a later
prompt word such as `codex exec "fix server"` is still a live session.
Factory waits on `droid` / `factory-cli`; Claude waits on `claude` /
`claude-code`; Grok waits on `grok`; Gemini / Aider / Goose /
Antigravity / Muse / OpenClaude / Prime / Junie / Ollama / Forge / OMP /
Copilot / Cline / Kilo / Augment / fx wait on their own executables.
Warp also waits on Warp.app (Stable, Nightly, and Preview). Claude Desktop
does not hold a Claude Code slip — only `com.anthropic.claude-code` does.
Pi waits on `pi` / `pi-agent`; Antigravity waits on `agy` /
`antigravity` / `antigravity-cli`. Two Codex terminals are treated
conservatively when any argv has no workspace flag — a bare `codex exec`,
or a later prompt path such as `inspect /Users/a/other-app/file`,
plus a sibling in another repo still holds this slip. Only recognized
cwd flags (`-C`, `--cd`, `--cwd`, `--workspace`, `--add-dir`, …)
attribute a process to another workspace. `ps` repeats the executable in
`ARGS` (`droid /path/to/droid daemon`); the first real subcommand
after that copy is what decides daemon vs session. A timed-out or
failed `/bin/ps` is an unknown snapshot: receipts stay open, and Pixel
Clock keeps its last running lanes instead of going idle. If the
printed-receipt lookup throws, that poll aborts instead of reminting
every recent slip.

Harnesses we cannot see on `/bin/ps` (Windsurf, Devin, IDE-only Composer)
still **print** a slip on quiet, but they **announce** only when the
indexed conversation has a terminal `endTime` that is not the start
placeholder and not the file-mtime stamp. Duration alone is not a close.

Codex is usage-first (new session id every run). Factory, Claude Code,
Grok, and the other indexed harnesses are conversation-first — the
monitor reads recent conversation metadata and joins `token_usage` by
session id so a long-lived session file still mints when it goes quiet.
The 20-minute live window only decides whether to *first-announce*
a never-printed history row whose CLI is **already gone**, so launching
the app does not replay the whole day. If the CLI is still open, the
slip waits for close even on a first mint after a 25-minute think —
the live window must not retire that pending announce. A slip that is
already in the register when BurnBar starts does not fire again if the
CLI is already gone. If that slip was printed during a pause and the
terminal is still open, the later close still notifies — even if the
think ran longer than 20 minutes and BurnBar relaunched in the middle.
Only the newest preexisting slip for that provider and project joins
the close queue, so a new Codex in a busy repo does not replay the
rest of the day's printed slips.

Conversation ingest is horizon-filtered (last 6 hours, up to 400
chats), not "newest 200 chats in the entire database," so a long-lived
Factory / Claude session cannot be crowded out by a busy Codex day. The horizon uses
the newest of file mtime / end / start — never `indexedAt` and never the
first non-null timestamp — so a stale file mtime cannot hide a later
end, and a parser restamp cannot resurrect a session with no real
activity. Usage joined by session id loads **every** row for those
sessions, so a Warp chat with hundreds of events keeps its full totals.

Copied markdown includes the chat line plus the slip and Session Logs
URLs so a shared receipt still has working deep links.
