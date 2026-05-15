# Hermes CLI Session Archive

Hermes treats Codex, Claude Code, and OpenClaw as first-class assistant runtimes. Live chats still mirror to `users/{uid}/cli_sessions`; archived local session logs are now exposed through the same surface without duplicating transcript plaintext.

## What Syncs

- macOS scans the local provider logs already indexed by `SessionLogSyncService`.
- Full transcript bodies, previews, chunks, and searchable indexes stay in the encrypted session-log cloud path.
- `cli_sessions` receives only a lightweight runtime row for archived logs: provider, title, timestamps, message count, source kind, encrypted transcript availability, and a resume handle when the provider supports one.
- Writes use stable document IDs and `setData(..., merge: true)` so rescans update the same archive row instead of creating duplicates or deleting history.

## Runtime Parity

Hermes, Pi, Codex, Claude Code, and OpenClaw all appear as enabled mobile runtimes by default. Archived Codex and Claude Code rows include resume hints such as `codex resume "<id>"` or `claude --resume "<id>"`; mobile can search and inspect them, while actual resume/fork execution remains a Mac-side provider action.

## Hermes Square Search

The Hermes Square search bar now federates:

- local Square index results,
- live runtime chats,
- active missions,
- cloud `cli_sessions` rows,
- encrypted hosted session-log matches.

Cloud transcript hits open a decrypting detail view. If the device cannot unwrap the vault key or the log body is not available, the UI surfaces the failure instead of pretending the transcript exists.

## Upgrade Safety

The `CLIAgentSessionRecord` schema version remains stable because the archive fields are additive and optional. Older records decode as live chats, while newer clients can use `sourceKind`, `resumeHandle`, and `encryptedTranscriptAvailable` when present.
