# CLI Agent Mobile Chat And Import

OpenBurnBar treats Codex, Claude Code, OpenClaw, Droid, Forge, and Antigravity
as Mac-backed agent runtimes on mobile. iOS/iPadOS and Android can start a
blank chat immediately, but the actual execution and local history import happen
on a signed-in trusted macOS device because the source logs and CLIs live on the
Mac.

## Chat Transport Contract

Mobile CLI-agent chat uses the Hermes Remote Relay surface first. iOS, iPadOS,
and Android write a `cliAgentChat` relay request to the selected Mac relay and
stream native `CLIAgentRelayChatEvent` updates back into the local
`mobile_assistant_chats` thread. Android tries the direct iroh relay first when
the native transport is available, then falls back to the encrypted Firestore
relay for `cliAgentChat` so direct-transport failures do not demote native chat
to a mission request. iOS/iPadOS use their full relay cascade for the same
operation. The Mac opens or creates the provided `clientThreadID` in its
`ChatSessionController`, so the mobile thread and Mac chat thread stay aligned.

The legacy mission-dispatch path remains a compatibility fallback for old or
unpaired Macs. That fallback writes
`users/{uid}/cli_agent_mission_requests/{id}` with:

- `missionKind: "chat"`
- `source: "ios-chat"` or `source: "android-chat"`
- `clientThreadID` for stable optimistic mobile rows
- `parentSessionID` and `resumeAction` when resuming, forking, or forwarding an
  archived session

The Mac listener claims the fallback request, executes through the existing CLI
bridge, and writes events plus mirrored `cli_sessions` rows. Mobile still owns
the native thread in `mobile_assistant_chats`; queued mission state is hidden
behind the assistant placeholder, not rendered as the primary chat experience.

History import writes `users/{uid}/agent_import_jobs/{id}` with
`status: "pending"` and `selectedHarnesses`. Firestore rules allow the owner to
create and read jobs, but only a trusted macOS escrow device can claim or update
progress. The Mac claim is transactional: if another trusted Mac already moved
the job out of `pending`, the second listener exits without parsing.

## Storage Surfaces

- `agent_import_jobs`: import control, status, counts, and human-readable
  progress.
- `mobile_assistant_chats`: native mobile chat threads for Hermes, Pi, Codex,
  Claude Code, OpenClaw, Droid, Forge, and Antigravity; CLI execution remains
  Mac-backed.
- `session_logs`: encrypted hosted transcript bodies and searchable encrypted
  index data.
- `cli_sessions`: lightweight mobile list, thread, resume, fork, and archive
  rows.
- Local SQLite: Mac-side parser output and conversation indexing before cloud
  mirroring.

Full transcript bodies remain in encrypted session-log storage. `cli_sessions`
is intentionally the lightweight operational surface mobile needs to render
rows and invoke resume actions.

## Import Providers

The Mac import listener uses the shared parser registry for Codex, Claude Code,
OpenClaw, Hermes, OpenCode, Factory, Cursor, Aider, Cline/Kilo/Roo, Forge,
Gemini, Goose, Windsurf, Warp, Kimi, and Ollama when those parsers are present.
OpenClaw history is read from `~/.openclaw/sessions` and accepts JSONL, log
files, whole-session JSON arrays, and nested JSON objects with message/history
arrays.

If selected providers have no local files, the job completes with
`No selected agent history was found on this Mac.` so mobile users are not left
guessing whether anything happened.

## Mobile UX Rules

- The `+` affordance opens a blank composer, not a setup blocker.
- Mac-backed CLI runtimes render user and assistant bubbles immediately; the
  primary path is live Mac relay chat, and any mission/queued fallback remains a
  hidden transport detail.
- Project/model/options can be adjusted without blocking text entry.
- CLI model pickers are runtime-scoped and Mac-sourced. Mobile asks the selected
  Mac relay for `cliAgentModelCatalog` before showing Codex, Claude Code, Droid,
  Forge, Grok, or Antigravity options; if the paired Mac cannot enumerate or
  verify the catalog, the picker shows a refresh/error state instead of falling
  back to a bundled list. Codex rows come from `codex debug models` when that
  command is available, then fall back to the paired Mac CLI default/profile.
  Grok rows come from `grok models` plus `~/.grok/models_cache.json` when
  available. Claude Code rows enumerate the bundled Anthropic catalog because
  the CLI accepts `--model` but does not expose a reliable list command.
  Antigravity rows enumerate the bundled Google/Gemini catalog because `agy`
  does not expose a reliable model-list command; the selected `agy` profile row
  is appended only when it names a custom non-catalog model. Forge rows come
  from `forge agent list`. Droid rows come from
  `droid exec --help` and are split by spend source: `Droid Standard quota` and
  `Droid Core quota` rows consume Droid CLI quota, while `API/OAuth via
  OpenBurnBar` rows are Droid custom models that route through
  OpenBurnBar-connected API/OAuth subscriptions instead. OpenBurnBar proxy rows
  must render the underlying model logo with an OpenBurnBar app-logo badge so
  users can see the model family and the billing/auth path at the same time.
  Display names are intentionally verbose: `Model · Provider/source ·
  via OpenBurnBar · Reasoning: level`. Keep model IDs machine-stable and put
  this context in the user-facing name, provider fields, and source badges.
  Hermes/Pi/OpenClaw remain live-relay scoped and only show models the paired
  Mac relay advertises for that runtime.
- Import is explicit and observable: users choose harnesses, start a job, and
  watch progress/counts from the Mac.
- Archived rows expose resume, fork, and forward actions from their
  `resumeHandle`; mobile does not fake actions when no handle exists.

## Verification

Use these checks after changing this contract:

```bash
npm --prefix functions run test:firestore-rules
xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -configuration Debug -destination 'platform=macOS' build
xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
cd android && ./gradlew testDebugUnitTest assembleDebug
```
