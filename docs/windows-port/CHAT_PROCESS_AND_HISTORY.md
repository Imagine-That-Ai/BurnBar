# Windows Chat Process And History

This is the implementation and validation note for `VAL-CHAT-001`,
`VAL-CHAT-002`, and `VAL-CHAT-003`.

## Process Launch

Windows chat no longer builds a shell command for the configured backend. The
production path is:

1. `ChatSurfaceViewModel`
2. `CliJsonLineChatStreamDriver`
3. `CliProcessLineSource`
4. `ChatProcessRunner`
5. `ProcessStartInfo.FileName` plus `ArgumentList`

`UseShellExecute` is always `false`; stdout, stderr, and stdin are redirected
directly. `cmd.exe`, PowerShell, and shell string construction are not part of
the chat launch path.

The executable must be present in `OPENBURNBAR_CHAT_APPROVED_EXECUTABLES`:

```json
[
  {
    "id": "claude",
    "path": "C:\\Program Files\\Claude\\claude.exe",
    "sha256": "<lowercase sha256>"
  }
]
```

The runner resolves the requested executable against that catalog, verifies the
file still exists, recomputes SHA-256 immediately before launch, and denies both
unapproved paths and replaced executables with typed stream failures.

## Bounds And Failure States

The Windows parity budget is enforced in product code:

- Combined stdout/stderr per turn: `32 MiB`.
- Maximum logical stdout/stderr record: `1 MiB`.
- Cancellation: the process tree is killed through `Process.Kill(entireProcessTree: true)`.

The stream path converts lifecycle failures into typed chat states:

- `ExecutableDenied`
- `ExecutableUnavailable`
- `ExecutableReplaced`
- `ProcessStartFailed`
- `NonZeroExit`
- `TimedOut`
- `Cancelled`
- `OutputLimitExceeded`
- `MalformedStream`
- `StreamError`
- `BackendUnavailable`
- `RetrievalDegraded`
- `AttachmentMissing`

The UI surfaces these states as actionable banners and the state machine stores
them with the transcript.

## Encrypted History

Chat history is stored by the Windows SQLCipher owner. Clean profiles provision:

- `chat_threads`
- `chat_messages`
- `chat_stream_failures`
- `chat_retrieval_events`

Messages persist role, content, ordered transcript pieces, CLI label, usage,
errors, retrieval state, and attachment references. Attachments are copied into
the chat workspace by reference; the encrypted database stores only the metadata
and workspace-relative path.

On app start, `ChatSurfaceViewModel` reopens the most recent thread through the
SQLCipher store and rehydrates the visible transcript. Storage failures render a
persistence warning instead of silently showing an empty history.

## Paste And Drop

The WinUI chat composer accepts dropped files and clipboard files as bounded
attachments. Dropped text becomes a text attachment. Normal short text paste is
left to the TextBox; large pasted text is staged as a bounded text attachment.

Missing staged files are marked on the attachment reference and do not corrupt
the thread.

## Evidence

Local portable evidence:

```powershell
dotnet test windows\tests\chat\OpenBurnBar.App.Chat.Runtime.Tests.csproj --no-restore --nologo
dotnet test windows\tests\storage\OpenBurnBar.App.Storage.Tests.csproj --no-restore --nologo
dotnet test windows\tests\presentation\OpenBurnBar.App.Presentation.Tests.csproj --no-restore --nologo --filter Chat
```

Windows host evidence producer:

```powershell
pwsh scripts\windows-port\chat-evidence.ps1 -RepoRoot C:\src\BurnBar
```

The host run must add process traces, process-table proof, UIA restart proof,
encrypted-byte scans, and ORACLE-CHAT-001 differential outcomes before any
ledger or public parity claim is promoted.
