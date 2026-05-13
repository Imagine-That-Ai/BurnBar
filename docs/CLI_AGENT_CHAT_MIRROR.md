# CLI Agent Chat Mirror (Mac → iOS)

When the user chats with **Codex**, **Claude Code**, or **OpenClaw**
on their Mac, OpenBurnBar mirrors the full transcript — text *and*
tool-use pills — to Firestore so the iOS Assistants tab can render the
same conversation. Read-only on iOS today; future waves can layer a
bi-directional transport on top.

## Wire format

Path: `users/{uid}/cli_sessions/{threadID}`.

The document body is encoded by
[`CLIAgentSessionCodec`](../OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CLIAgentSessionRecord.swift).
Important fields:

| Field | Type | Notes |
| --- | --- | --- |
| `id` | string | Thread id; matches the macOS `activeThreadID`. |
| `agent` | string | One of `codex` / `claude` / `openclaw`. |
| `title` | string | Derived from the first user message (≤ 64 chars). |
| `preview` | string | Last non-empty body (≤ 160 chars). |
| `modelName` | string? | Model the Mac requested. |
| `workspaceLabel` | string? | `chatWorkspaceURL.lastPathComponent` for context. |
| `createdAt` / `updatedAt` | timestamp | Firestore `Timestamp` (SDK auto-converts). |
| `endedAt` | timestamp? | Present when the session finalised. |
| `schemaVersion` | int | Current value: `CLIAgentSessionRecord.currentSchemaVersion`. Readers refuse newer versions. |
| `messages` | array | Inline array — keeps a single document round trip per session. |
| `tokenUsage` | object? | Flat `inputTokens` / `outputTokens` / cache + reasoning tokens. |

Per-message shape:

```json
{
  "id": "...",
  "role": "user" | "assistant" | "system",
  "text": "joined assistant body",
  "timestamp": Timestamp,
  "isError": false,
  "toolUses": [
    {
      "id": "transcript-piece-id",
      "name": "Read",
      "status": "done",
      "detail": "AgentLens/Services/AuthRepository.swift",
      "startedAt": Timestamp
    }
  ]
}
```

## Mac writer

[`CLIAgentSessionMirror`](../AgentLens/Services/CloudSync/CLIAgentSessionMirror.swift)
is the only writer. It runs on the main actor, takes an
`AccountManager` reference for auth gating, and a Firestore handle.

Authorization gate:

1. Firebase configured + signed in.
2. `accountManager.isCloudSyncEnabled` is true.
3. `UserDefaults.standard.bool(forKey: CLIAgentSessionMirror.preferenceKey)`
   is true (default: yes). Power users can disable transcript
   mirroring without disabling the broader cloud sync toggle.
4. The chat backend is one of the three CLI runtimes.

Call site:
[`ChatSessionController`](../AgentLens/Views/Chat/ChatSessionController.swift)
fires the mirror after every `saveChatMessage` for a streaming
assistant turn, so iOS sees partial transcripts as they grow.

To add a new runtime, extend `CLIAgentRuntime`, map the new
`ChatBackendID` in `CLIAgentSessionMirror.cliAgent(for:)`, and bump
`CLIAgentSessionRecord.currentSchemaVersion` if the on-wire shape
changes.

## iOS reader

[`CLIAgentChatReader`](../OpenBurnBarMobile/Services/CLIAgentChatReader.swift)
is a `@MainActor @Observable` singleton. Its `refresh()` is idempotent
and coalesces concurrent callers; the auth listener clears `sessions`
on sign-out and refetches on sign-in.

Views:

- [`CLIAgentConversationListView`](../OpenBurnBarMobile/Views/CLIAgents/CLIAgentConversationListView.swift)
  — runtime-aware list of sessions, accent-tinted per agent, empty state
  copy explains *why* the list is empty (Mac hasn't streamed anything yet).
- [`CLIAgentTranscriptView`](../OpenBurnBarMobile/Views/CLIAgents/CLIAgentTranscriptView.swift)
  — read-only message list, reuses the same tool-pill vocabulary
  Hermes / Pi already ship.

These are mounted from
[`AssistantsTabRoot`](../OpenBurnBarMobile/Views/Hermes/AssistantsTabRoot.swift)
in place of the previous "Connect your Mac" placeholder.

## Firestore security

The collection path is per-user (`users/{uid}/cli_sessions/{...}`), so the
existing rule (`match /users/{uid}/{document=**} { allow read, write: if
request.auth.uid == uid; }`) covers it. No new rule required.

If/when subcollections are added (e.g. per-tool-call attachments), the
rule must be extended to allow reads on the new path.

## Schema evolution

Bump `CLIAgentSessionRecord.currentSchemaVersion` whenever you add or
rename a required field. The decoder refuses any document stamped with
a version greater than the build it was compiled for — older builds
silently drop unknown sessions rather than crash. Adding *optional*
fields (e.g. a new `attachments` array on `CLIAgentMessage`) does not
require a version bump; both encoder and decoder tolerate unknown
fields.

## Testing

- `OpenBurnBarMobileTests/CLIAgents/CLIAgentSessionCodecTests.swift` —
  round-trip + future-version + unknown-agent + malformed-message tolerance.
- `OpenBurnBarMobileTests/CLIAgents/CLIAgentChatReaderTests.swift` —
  reader contract against a stub remote source (refresh, filter,
  errors, concurrency coalescing, id lookup).
- `AgentLensTests/Active/CLIAgentSessionMirrorTests.swift` — mirror
  builder: backend → CLI runtime mapping, transcript piece →
  CLI tool use conversion, title / preview derivation, legacy
  transcript fallback.
