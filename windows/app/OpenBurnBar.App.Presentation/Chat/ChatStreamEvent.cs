namespace OpenBurnBar.App.Presentation.Chat;

// MARK: - Chat Stream Event
//
// C# peer of `AgentLens/Services/CLIBridge/CLIBridgeTypes.swift` `CLIChatStreamEvent`
// — the typed events the backend stream yields, parsed from Claude `stream-json`
// lines and Codex/Hermes deltas. The portable state machine
// (`ChatSessionStateMachine`) consumes these; the platform stream sources
// (WinUI CLIBridge / gateway clients) produce them.

/// One backend stream event (peer of Swift `CLIChatStreamEvent`).
public abstract record ChatStreamEvent
{
    private ChatStreamEvent()
    {
    }

    public sealed record Text(string Chunk) : ChatStreamEvent;

    public sealed record Reasoning(string Chunk) : ChatStreamEvent;

    public sealed record Refusal(string Chunk) : ChatStreamEvent;

    public sealed record ToolUse(string Name, string? Detail) : ChatStreamEvent;

    public sealed record ToolResult(string Name, string? Detail) : ChatStreamEvent;

    public sealed record Usage(CliUsageSnapshot Snapshot) : ChatStreamEvent;

    public sealed record StreamFailure(ChatFailureKind Kind, string Message) : ChatStreamEvent;
}

/// Token-usage rollup carried by a <see cref="ChatStreamEvent.Usage"/> event
/// (peer of Swift `CLIUsageSnapshot`). <see cref="TotalTokens"/> is the
/// input+output basis the controller compares when merging successive snapshots.
public sealed record CliUsageSnapshot(
    int InputTokens,
    int OutputTokens,
    int CacheCreationTokens = 0,
    int CacheReadTokens = 0,
    int ReasoningTokens = 0)
{
    public int TotalTokens => InputTokens + OutputTokens;
}

/// Terminal outcome of a stream (peer of Swift `ChatStreamSettleOutcome`).
public sealed record ChatStreamSettleOutcome
{
    private ChatStreamSettleOutcome(bool completed, bool cancelled)
    {
        Completed = completed;
        Cancelled = cancelled;
    }

    public bool Completed { get; }

    /// True only for a cancelled failure (peer of Swift `isCancelled`).
    public bool Cancelled { get; }

    public static readonly ChatStreamSettleOutcome CompletedOutcome = new(completed: true, cancelled: false);

    public static ChatStreamSettleOutcome Failed(bool cancelled) => new(completed: false, cancelled: cancelled);
}

public enum ChatFailureKind
{
    BackendUnavailable,
    ExecutableDenied,
    ExecutableUnavailable,
    ExecutableReplaced,
    ProcessStartFailed,
    NonZeroExit,
    TimedOut,
    Cancelled,
    OutputLimitExceeded,
    MalformedStream,
    StreamError,
    StorageUnavailable,
    AttachmentMissing,
    RetrievalDegraded,
}

/// The coarse phase of the active turn, walked by <see cref="ChatSessionStateMachine"/>.
/// Idle -> Streaming -> (ToolUse -> ToolResult)* -> Done, with Cancelled / Failed
/// terminal branches. Mirrors the transition contract this lane must prove.
public enum ChatStreamPhase
{
    Idle,
    Streaming,
    ToolUse,
    ToolResult,
    Done,
    Cancelled,
    Failed,
}
