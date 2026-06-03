# CLI Agent Chat Mirror (Mac → Mobile)

When the user chats with **Codex**, **Claude Code**, **OpenClaw**, **Droid**,
**Forge**, or **Antigravity** on their Mac, OpenBurnBar mirrors the session to
Firestore so mobile Assistants tabs can render the same conversation. The
transcript text, tool-use details, title, preview, model, workspace label, and
resume hints are sealed on device before Firestore receives them. Mobile chat
can also send new turns back through the trusted Mac relay for these Mac-backed
runtimes.

## Mobile session interface modes

iOS, iPadOS, and Android expose a per-runtime session interface toggle in the
CLI agent composer:

| Mode | Wire value | Behavior |
| --- | --- | --- |
| Chat | `native_chat` | Uses the native mobile chat surface. iOS, iPadOS, and Android send the turn through the encrypted `/v1/cli-agent/chat` Mac relay first. Android falls back from iroh to encrypted Firestore relay before considering any mission fallback. |
| Mac CLI | `mac_visible_cli` | Sends the turn through the mission queue with `deliveryMode = full_stream`, opens the selected agent in a visible macOS Terminal window, and streams that same Terminal output back into the mobile thread. The phone/tablet can use Mercury screen sharing as the main interface while the Mac CLI is running. |

The main iOS Hermes chat uses the same `mac_visible_cli` mission path when its
toolbar view mode is set to **CLI**. A new Hermes turn opens `hermes chat` in
Terminal on the paired Mac, starts the inline Mercury mirror, and uses Smart
Zoom focus context to frame the active Terminal window on the phone. Attachment
turns are rejected in CLI mode until there is a terminal-visible attachment
handoff; switch back to Smart/native chat for attachment turns.

The request field is `presentationMode`. Older clients and older relay payloads
that omit the field decode as `native_chat`.

## Wire format

Path: `users/{uid}/cli_sessions/{threadID}`.

The document body is encoded by
[`CLIAgentSessionCodec`](../OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CLIAgentSessionRecord.swift).
Current sealed fields:

| Field | Type | Notes |
| --- | --- | --- |
| `id` | string | Thread id; matches the macOS `activeThreadID`. |
| `agent` | string | One of `codex` / `claude` / `openclaw` / `droid` / `forge` / `antigravity`. |
| `sourceKind` | string | `live_chat` or `archived_log`. |
| `createdAt` / `updatedAt` | timestamp | Firestore `Timestamp` (SDK auto-converts). |
| `endedAt` | timestamp? | Present when the session finalised. |
| `schemaVersion` | int | Current value: `CLIAgentSessionRecord.currentSchemaVersion`. Readers refuse newer versions. |
| `contentSealed` | bool | Must be `true` for current writers. |
| `sealedSchemaVersion` | int | Current sealed payload schema, currently `1`. |
| `vaultKeyID` | string | Active Cloud Vault key id; Firestore rules require it to match `cloud_vault_state/current`. |
| `sealedPayload` | object | AES-GCM Cloud Vault envelope containing the private `CLIAgentSessionRecord`. |
| `messageCount` | int | Count only; no message text. |
| `lastMessageRole` | string? | Generic notification/sync hint. |
| `lastAssistantMessageID` | string? | Deterministic notification de-dupe hint. |
| `tokenUsage` | object? | Flat `inputTokens` / `outputTokens` / cache + reasoning tokens. |
| `encryptedTranscriptAvailable` | bool | True when an archived transcript also has an encrypted session-log body. |
| `labelColorHex` / `isPinned` / `priorityOrder` | optional metadata | Non-content list organization metadata. |

The sealed payload contains the private record that used to live in plaintext:

```json
{
  "title": "derived first user message",
  "preview": "last non-empty body",
  "modelName": "requested model",
  "workspaceLabel": "project folder label",
  "messages": [
    {
      "id": "...",
      "role": "user|assistant|system",
      "text": "joined assistant body",
      "toolUses": [
        {
          "name": "Read",
          "detail": "AgentLens/Services/AuthRepository.swift"
        }
      ]
    }
  ],
  "resumeHandle": {
    "providerSessionID": "...",
    "projectLabel": "...",
    "commandHint": "codex resume ..."
  }
}
```

Legacy readers still tolerate old plaintext `title`, `preview`, and `messages`
documents so users can migrate existing rows. Firestore rules reject new
plaintext writes.

## Mac writer

[`CLIAgentSessionMirror`](../AgentLens/Services/CloudSync/CLIAgentSessionMirror.swift)
is the only writer. It runs on the main actor, takes an
`AccountManager` reference for auth gating, and a Firestore handle.

Authorization gate:

1. Firebase configured + signed in.
2. `accountManager.isCloudSyncEnabled` is true.
3. `UserDefaults.standard.bool(forKey: CLIAgentSessionMirror.preferenceKey)` is
   true (default: yes). Power users can disable the mirror without disabling the
   broader cloud sync toggle.
4. The chat backend is one of the Mac-backed CLI runtimes.
5. The Mac has an active Cloud Vault key wrapper; otherwise the write fails
   closed instead of falling back to plaintext.

Call site:
[`ChatSessionController`](../AgentLens/Views/Chat/ChatSessionController.swift)
fires the mirror after every `saveChatMessage` for a streaming
assistant turn, so iOS sees partial transcripts as they grow.

To add a new runtime, extend `CLIAgentRuntime`, map the new
`ChatBackendID` in `CLIAgentSessionMirror.cliAgent(for:)`, and bump
`CLIAgentSessionRecord.currentSchemaVersion` if the on-wire shape
changes.

## Mobile readers

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
- [`CliAgentChatView`](../android/app/src/main/java/com/openburnbar/ui/hermes/CliAgentChatView.kt)
  — Android native composer for Codex, Claude Code, OpenClaw, Droid, Forge, and
  Antigravity.
  Native Chat mode uses [`CLIAgentRelayChatTransport`](../android/app/src/main/java/com/openburnbar/data/assistants/CLIAgentRelayChatTransport.kt)
  and the encrypted Mac relay; the mission dispatcher is reserved for explicit
  Mac CLI mode or old relay-incompatible Macs.

These are mounted from
[`AssistantsTabRoot`](../OpenBurnBarMobile/Views/Hermes/AssistantsTabRoot.swift)
and Android [`AssistantsScreen`](../android/app/src/main/java/com/openburnbar/ui/hermes/AssistantsScreen.kt)
in place of the previous "Connect your Mac" placeholder.

## Firestore security

The collection path is per-user (`users/{uid}/cli_sessions/{...}`), so the
checked-in rules require:

- `contentSealed == true`
- `sealedPayload` is a valid Cloud Vault AES-GCM envelope
- `vaultKeyID` matches the user's active `cloud_vault_state/current`
- top-level plaintext fields such as `title`, `preview`, `modelName`,
  `workspaceLabel`, `messages`, `resumeHandle`, and `customTitle` are absent

If/when subcollections are added (e.g. per-tool-call attachments), the
rule must be extended to require the same sealed-private-field boundary.

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
  CLI tool use conversion, title / preview derivation, sealed payload
  encoding, and legacy transcript fallback.
- `functions/scripts/test-firestore-rules.mjs` — rejects plaintext
  `cli_sessions` writes and accepts sealed payloads only.
- `scripts/privacy/scan-chat-cloud-plaintext.mjs` — static guard that checks
  writers and rules for this boundary.
