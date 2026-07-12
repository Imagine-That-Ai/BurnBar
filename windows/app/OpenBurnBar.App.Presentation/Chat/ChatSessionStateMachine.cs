using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.Chat;

// MARK: - Chat Session State Machine
//
// The PORTABLE streaming state machine extracted from
// `AgentLens/Views/Chat/ChatSessionController.swift` (+ its `+Search` /
// `+Retrieval` extensions). The macOS controller is a 1,950-line @Observable
// god-type wired to CLIBridge, gateways, keychain, DataStore, and analytics.
// This class isolates the part that is genuinely platform-independent — the
// transition machine that drives a single assistant turn:
//
//     idle → streaming → (tool_use → tool_result)* → done
//                    ↘ stop (cancel) / fail
//     + regenerate (drop the last assistant turn and re-stream)
//     + citation jump token
//
// A platform *driver* (the WinUI ChatSurfaceViewModel, or a test) owns the real
// backend stream. It calls TryBeginUserTurn → BeginAssistantStream → Ingest(…)*
// → CompleteStream / FailStream, and CancelGeneration / PrepareRegeneration for
// the stop + regenerate affordances. Every transition here is synchronous and
// deterministic, which is exactly why it is unit-tested on the macOS host.
//
// Parity anchors (Swift → C#):
//   send() guard + user append            → TryBeginUserTurn
//   isStreaming = true; placeholder append → BeginAssistantStream
//   the `for try await event` switch       → Ingest
//   terminal `isStreaming = false; …`      → CompleteStream
//   catch { … cancelled? … }               → FailStream
//   cancelGeneration()                      → CancelGeneration
//   jumpToMemoryCitation / tokens           → JumpToMemoryCitation

public sealed class ChatSessionStateMachine
{
    private readonly List<ChatMessageRecord> _messages = new();

    /// The ordered transcript (peer of `ChatSessionController.messages`).
    public IReadOnlyList<ChatMessageRecord> Messages => _messages;

    /// True while a backend stream is live (peer of `isStreaming`).
    public bool IsStreaming { get; private set; }

    /// Id of the assistant placeholder currently receiving chunks (peer of
    /// `activeStreamMessageId`); null when idle.
    public string? ActiveStreamMessageId { get; private set; }

    /// Monotonic counter bumped on every ingested chunk (peer of `streamingTick`).
    /// Views observe this to mirror in-flight content without re-reading Messages.
    public int StreamingTick { get; private set; }

    /// Last non-cancellation stream error surfaced to the composer (peer of `streamError`).
    public string? StreamError { get; private set; }

    public ChatFailureKind? LastFailureKind { get; private set; }

    /// Synchronous reentrancy sentinel for a send in its await window before
    /// IsStreaming flips (peer of `sendInFlight`).
    public bool SendInFlight { get; private set; }

    /// True once the first assistant response badge has shown (peer of `firstAssistantBadgeShown`).
    public bool FirstAssistantBadgeShown { get; private set; }

    /// Busy iff streaming or a send is mid-flight (peer of `isSendBusy`).
    public bool IsSendBusy => IsStreaming || SendInFlight;

    /// The coarse phase walked by the machine (see <see cref="ChatStreamPhase"/>).
    public ChatStreamPhase Phase { get; private set; } = ChatStreamPhase.Idle;

    /// Best token-usage snapshot seen this turn (peer of the `usageSnapshot`
    /// local; kept as max-total like the Swift merge).
    public CliUsageSnapshot? LatestUsage { get; private set; }

    /// When the current stream began (peer of `streamStartedAt`).
    public DateTimeOffset? StreamStartedAt { get; private set; }

    // MARK: Citation jump (F-3 / E1)

    /// A message id the stream should scroll to (peer of `pendingMemoryJumpMessageID`).
    public string? PendingMemoryJumpMessageId { get; private set; }

    /// Monotonic token bumped on every citation tap so re-tapping an in-view row
    /// re-runs the scroll + flash (peer of `memoryJumpRequestToken`).
    public int MemoryJumpRequestToken { get; private set; }

    /// The message id currently painted with the "landed here" flash (peer of
    /// `memoryJumpHighlightMessageID`).
    public string? MemoryJumpHighlightMessageId { get; set; }

    // MARK: Events

    /// Raised on every terminal settle (peer of `onStreamSettled`).
    public event Action<ChatStreamSettleOutcome>? StreamSettled;

    /// Raised when <see cref="CancelGeneration"/> is invoked, so a driver can
    /// cancel the real backend task + I/O (peer of `streamTask?.cancel()` +
    /// `cliBridge.cancel()`).
    public event Action? CancelRequested;

    /// Raised whenever observable state changes, so a WinUI wrapper can forward a
    /// single INotifyPropertyChanged pulse without coupling this layer to WinUI.
    public event Action? Changed;

    // MARK: - Turn lifecycle

    /// Append the user turn and arm the reentrancy sentinel. Returns the appended
    /// record, or null when the input is empty or a send is already busy (peer of
    /// the top of `send()`: trim, `guard !isSendBusy`, `sendInFlight = true`,
    /// clear `streamError`, append user).
    public ChatMessageRecord? TryBeginUserTurn(string text, IReadOnlyList<string>? attachmentIds = null)
    {
        IReadOnlyList<ChatAttachmentRecord>? attachments = null;
        if (attachmentIds is { Count: > 0 })
        {
            var records = new ChatAttachmentRecord[attachmentIds.Count];
            for (var i = 0; i < attachmentIds.Count; i++)
            {
                records[i] = ChatAttachmentRecord.ReferenceOnly(attachmentIds[i]);
            }

            attachments = records;
        }

        return TryBeginUserTurnWithAttachments(text, attachments);
    }

    public ChatMessageRecord? TryBeginUserTurnWithAttachments(
        string text,
        IReadOnlyList<ChatAttachmentRecord>? attachments = null)
    {
        var trimmed = (text ?? string.Empty).Trim();
        var hasAttachments = attachments is { Count: > 0 };
        if (trimmed.Length == 0 && !hasAttachments)
        {
            return null;
        }
        if (IsSendBusy)
        {
            return null;
        }

        SendInFlight = true;
        StreamError = null;
        LastFailureKind = null;

        var user = new ChatMessageRecord(ChatMessageRole.User, trimmed, attachments: attachments);
        _messages.Add(user);
        RaiseChanged();
        return user;
    }

    /// Flip to streaming and append the empty assistant placeholder that chunks
    /// mutate in place. Clears the send sentinel (the stream has begun) and
    /// returns the placeholder (peer of `isStreaming = true; … placeholder;
    /// messages.append(placeholder)`).
    public ChatMessageRecord BeginAssistantStream(string? backendLabel = null, DateTimeOffset? startedAt = null)
    {
        var assistantId = Guid.NewGuid().ToString();
        var placeholder = new ChatMessageRecord(
            ChatMessageRole.Assistant,
            content: string.Empty,
            id: assistantId,
            cliUsed: FirstAssistantBadgeShown ? null : backendLabel);
        FirstAssistantBadgeShown = true;

        IsStreaming = true;
        ActiveStreamMessageId = assistantId;
        SendInFlight = false;
        LatestUsage = null;
        StreamError = null;
        LastFailureKind = null;
        StreamStartedAt = startedAt ?? DateTimeOffset.UtcNow;
        Phase = ChatStreamPhase.Streaming;

        _messages.Add(placeholder);
        RaiseChanged();
        return placeholder;
    }

    /// Apply one backend event to the active placeholder (peer of the
    /// `for try await event { switch event … }` body): coalesce text/reasoning/
    /// refusal, push tool events, merge usage, then mutate the placeholder's
    /// Content + TranscriptPieces and bump StreamingTick.
    public void Ingest(ChatStreamEvent streamEvent)
    {
        if (streamEvent is null)
        {
            throw new ArgumentNullException(nameof(streamEvent));
        }
        var active = ActiveMessage();
        if (active is null)
        {
            return; // no live placeholder — ignore stray events (defensive).
        }
        var pieces = active.TranscriptPieces;

        switch (streamEvent)
        {
            case ChatStreamEvent.Text t:
                ChatMessageRecord.AppendStreamingText(t.Chunk, pieces);
                UpdatePhaseFromLastPiece();
                break;
            case ChatStreamEvent.Reasoning r:
                ChatMessageRecord.AppendStreamingChunk(r.Chunk, ChatTranscriptPieceKind.Reasoning, pieces);
                UpdatePhaseFromLastPiece();
                break;
            case ChatStreamEvent.Refusal f:
                ChatMessageRecord.AppendStreamingChunk(f.Chunk, ChatTranscriptPieceKind.Refusal, pieces);
                UpdatePhaseFromLastPiece();
                break;
            case ChatStreamEvent.ToolUse u:
                pieces.Add(new ChatTranscriptPiece(ChatTranscriptPieceKind.ToolUse, u.Name, u.Detail));
                Phase = ChatStreamPhase.ToolUse;
                break;
            case ChatStreamEvent.ToolResult tr:
                pieces.Add(new ChatTranscriptPiece(ChatTranscriptPieceKind.ToolResult, tr.Name, tr.Detail));
                Phase = ChatStreamPhase.ToolResult;
                break;
            case ChatStreamEvent.Usage usage:
                MergeUsage(usage.Snapshot);
                // usage does not advance the transcript phase; return early so
                // the empty-content re-render below is still applied (parity: the
                // Swift loop rebuilds content every event).
                break;
            case ChatStreamEvent.StreamFailure failure:
                pieces.Add(new ChatTranscriptPiece(ChatTranscriptPieceKind.Refusal, failure.Message));
                active.Content = ChatMessageRecord.JoinedText(pieces);
                FailStream(cancelled: failure.Kind == ChatFailureKind.Cancelled, failure.Kind, failure.Message);
                return;
        }

        active.Content = ChatMessageRecord.JoinedText(pieces);
        unchecked
        {
            StreamingTick += 1; // wraps like the Swift `&+= 1`.
        }
        RaiseChanged();
    }

    /// Terminal success: clear the live flags and settle (peer of the terminal
    /// `isStreaming = false; activeStreamMessageId = nil; … onStreamSettled(.completed)`).
    public ChatStreamSettleOutcome CompleteStream()
    {
        IsStreaming = false;
        ActiveStreamMessageId = null;
        Phase = ChatStreamPhase.Done;
        RaiseChanged();
        var outcome = ChatStreamSettleOutcome.CompletedOutcome;
        StreamSettled?.Invoke(outcome);
        return outcome;
    }

    /// Terminal failure (peer of the `catch` arm). A cancellation is NOT surfaced
    /// as an error (`shouldPersistFailure = !(error is CancellationError)`); a
    /// genuine failure records <paramref name="errorMessage"/> in StreamError.
    public ChatStreamSettleOutcome FailStream(bool cancelled, string? errorMessage = null) =>
        FailStream(cancelled, cancelled ? ChatFailureKind.Cancelled : ChatFailureKind.StreamError, errorMessage);

    public ChatStreamSettleOutcome FailStream(
        bool cancelled,
        ChatFailureKind failureKind,
        string? errorMessage = null)
    {
        IsStreaming = false;
        ActiveStreamMessageId = null;
        LastFailureKind = failureKind;
        if (!cancelled)
        {
            StreamError = errorMessage;
        }
        Phase = cancelled ? ChatStreamPhase.Cancelled : ChatStreamPhase.Failed;
        RaiseChanged();
        var outcome = ChatStreamSettleOutcome.Failed(cancelled);
        StreamSettled?.Invoke(outcome);
        return outcome;
    }

    /// Stop the active generation (peer of `cancelGeneration()`): request the
    /// driver cancel the backend task/I-O, clear the live flags, and settle as a
    /// cancelled failure. The partial assistant message stays in the transcript,
    /// exactly like the Swift path which leaves the placeholder in place.
    public void CancelGeneration()
    {
        if (!IsStreaming && ActiveStreamMessageId is null)
        {
            return;
        }
        CancelRequested?.Invoke();
        IsStreaming = false;
        ActiveStreamMessageId = null;
        LastFailureKind = ChatFailureKind.Cancelled;
        Phase = ChatStreamPhase.Cancelled;
        RaiseChanged();
        StreamSettled?.Invoke(ChatStreamSettleOutcome.Failed(cancelled: true));
    }

    /// Prepare a regeneration: drop the trailing assistant turn and return the
    /// user text it answered, so the driver can re-run BeginAssistantStream +
    /// stream a fresh answer. Returns null when busy or when there is no
    /// assistant turn to regenerate.
    ///
    /// This models the "Regenerate" affordance the WinUI surface exposes; the
    /// macOS controller drives the same effect by re-sending. Kept deterministic
    /// + guard-checked so it is unit-testable.
    public string? PrepareRegeneration()
    {
        if (IsSendBusy)
        {
            return null;
        }
        var lastIndex = _messages.Count - 1;
        if (lastIndex < 0 || _messages[lastIndex].Role != ChatMessageRole.Assistant)
        {
            return null;
        }

        // Find the user turn this assistant answered (the nearest preceding user).
        string? userText = null;
        for (var i = lastIndex - 1; i >= 0; i--)
        {
            if (_messages[i].Role == ChatMessageRole.User)
            {
                userText = _messages[i].Content;
                break;
            }
        }
        if (userText is null)
        {
            return null; // orphaned assistant with no preceding user — nothing to regenerate.
        }

        _messages.RemoveAt(lastIndex);
        FirstAssistantBadgeShown = _messages.Exists(m => m.Role == ChatMessageRole.Assistant);
        Phase = ChatStreamPhase.Idle;
        RaiseChanged();
        return userText;
    }

    // MARK: - Citation jump

    /// Request a scroll to <paramref name="messageId"/> and bump the request token
    /// so re-tapping the same in-view source re-runs the flash (peer of
    /// `jumpToMemoryCitation`: set id in lockstep with `memoryJumpRequestToken`).
    public void JumpToMemoryCitation(string messageId)
    {
        PendingMemoryJumpMessageId = messageId;
        unchecked
        {
            MemoryJumpRequestToken += 1;
        }
        RaiseChanged();
    }

    /// Clear the pending jump after the view has scrolled (peer of the stream
    /// clearing `pendingMemoryJumpMessageID` once centered).
    public void ClearMemoryJump()
    {
        PendingMemoryJumpMessageId = null;
        RaiseChanged();
    }

    public void LoadTranscript(IReadOnlyList<ChatMessageRecord> messages)
    {
        ArgumentNullException.ThrowIfNull(messages);
        _messages.Clear();
        _messages.AddRange(messages);
        IsStreaming = false;
        ActiveStreamMessageId = null;
        StreamingTick = 0;
        StreamError = null;
        LastFailureKind = null;
        SendInFlight = false;
        LatestUsage = null;
        StreamStartedAt = null;
        Phase = ChatStreamPhase.Idle;
        FirstAssistantBadgeShown = _messages.Exists(m => m.Role == ChatMessageRole.Assistant);
        RaiseChanged();
    }

    // MARK: - Internals

    private ChatMessageRecord? ActiveMessage()
    {
        if (ActiveStreamMessageId is null)
        {
            return null;
        }
        for (var i = _messages.Count - 1; i >= 0; i--)
        {
            if (_messages[i].Id == ActiveStreamMessageId)
            {
                return _messages[i];
            }
        }
        return null;
    }

    private void UpdatePhaseFromLastPiece()
    {
        Phase = ChatStreamPhase.Streaming;
    }

    private void MergeUsage(CliUsageSnapshot snapshot)
    {
        if (LatestUsage is { } prev)
        {
            LatestUsage = snapshot.TotalTokens >= prev.TotalTokens ? snapshot : prev;
        }
        else
        {
            LatestUsage = snapshot;
        }
    }

    private void RaiseChanged() => Changed?.Invoke();
}
