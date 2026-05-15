# CLI Agent Mobile Chat And Import

OpenBurnBar treats Codex, Claude Code, and OpenClaw as Mac-backed agent
runtimes on mobile. iOS/iPadOS and Android can start a blank chat immediately,
but the actual execution and local history import happen on a signed-in trusted
macOS device because the source logs and CLIs live on the Mac.

## Firestore Contract

Mobile chat dispatch writes `users/{uid}/cli_agent_mission_requests/{id}` with:

- `missionKind: "chat"`
- `source: "ios-chat"` or `source: "android-chat"`
- `clientThreadID` for stable optimistic mobile rows
- `parentSessionID` and `resumeAction` when resuming, forking, or forwarding an
  archived session

The Mac listener claims the request, executes through the existing CLI bridge,
and writes events plus mirrored `cli_sessions` rows. Mobile observes those rows
for thread state instead of inventing local-only transcript truth.

History import writes `users/{uid}/agent_import_jobs/{id}` with
`status: "pending"` and `selectedHarnesses`. Firestore rules allow the owner to
create and read jobs, but only a trusted macOS escrow device can claim or update
progress. The Mac claim is transactional: if another trusted Mac already moved
the job out of `pending`, the second listener exits without parsing.

## Storage Surfaces

- `agent_import_jobs`: import control, status, counts, and human-readable
  progress.
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
- Project/model/options can be adjusted without blocking text entry.
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
