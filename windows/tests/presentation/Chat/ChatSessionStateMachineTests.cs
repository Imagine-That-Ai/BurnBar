using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Chat;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Chat;

/// <summary>
/// Real tests for the portable streaming state machine extracted from
/// AgentLens/Views/Chat/ChatSessionController.swift (+ its +Search / +Retrieval
/// extensions). Proves the transition contract this lane owns:
///   idle → streaming → (tool_use → tool_result)* → done, plus stop (cancel),
///   fail, regenerate, and the citation-jump token — all deterministic and
///   runnable on the macOS authoring host today.
/// </summary>
public sealed class ChatSessionStateMachineTests
{
    private static ChatSessionStateMachine RunOneTurn(string user, string reply, string? backend = "hermes")
    {
        var sm = new ChatSessionStateMachine();
        sm.TryBeginUserTurn(user);
        sm.BeginAssistantStream(backend);
        sm.Ingest(new ChatStreamEvent.Text(reply));
        sm.CompleteStream();
        return sm;
    }

    [Fact]
    public void FullTurn_WalksIdleStreamingToolUseToolResultDone()
    {
        var sm = new ChatSessionStateMachine();
        Assert.Equal(ChatStreamPhase.Idle, sm.Phase);

        var user = sm.TryBeginUserTurn("hello");
        Assert.NotNull(user);
        Assert.True(sm.SendInFlight);
        Assert.False(sm.IsStreaming);
        Assert.Single(sm.Messages);

        var placeholder = sm.BeginAssistantStream("hermes");
        Assert.True(sm.IsStreaming);
        Assert.False(sm.SendInFlight);
        Assert.Equal(placeholder.Id, sm.ActiveStreamMessageId);
        Assert.Equal(ChatStreamPhase.Streaming, sm.Phase);
        Assert.Equal(2, sm.Messages.Count);

        sm.Ingest(new ChatStreamEvent.Text("Hel"));
        sm.Ingest(new ChatStreamEvent.Text("lo"));
        Assert.Equal(ChatStreamPhase.Streaming, sm.Phase);
        Assert.Equal("Hello", placeholder.Content);

        sm.Ingest(new ChatStreamEvent.ToolUse("Read", "path=a"));
        Assert.Equal(ChatStreamPhase.ToolUse, sm.Phase);

        sm.Ingest(new ChatStreamEvent.ToolResult("Read", "ok"));
        Assert.Equal(ChatStreamPhase.ToolResult, sm.Phase);

        sm.Ingest(new ChatStreamEvent.Text(" done"));
        Assert.Equal(ChatStreamPhase.Streaming, sm.Phase);
        Assert.Equal("Hello done", placeholder.Content);

        var outcome = sm.CompleteStream();
        Assert.True(outcome.Completed);
        Assert.False(sm.IsStreaming);
        Assert.Null(sm.ActiveStreamMessageId);
        Assert.Equal(ChatStreamPhase.Done, sm.Phase);

        // Transcript shape: text, toolUse, toolResult, text.
        var pieces = placeholder.TranscriptPieces;
        Assert.Equal(4, pieces.Count);
        Assert.Equal(ChatTranscriptPieceKind.Text, pieces[0].Kind);
        Assert.Equal(ChatTranscriptPieceKind.ToolUse, pieces[1].Kind);
        Assert.Equal(ChatTranscriptPieceKind.ToolResult, pieces[2].Kind);
        Assert.Equal(ChatTranscriptPieceKind.Text, pieces[3].Kind);
    }

    [Fact]
    public void TryBeginUserTurn_EmptyInput_ReturnsNull()
    {
        var sm = new ChatSessionStateMachine();
        Assert.Null(sm.TryBeginUserTurn("   "));
        Assert.Empty(sm.Messages);
    }

    [Fact]
    public void TryBeginUserTurn_AttachmentsOnly_IsAllowed()
    {
        var sm = new ChatSessionStateMachine();
        var user = sm.TryBeginUserTurn(string.Empty, new List<string> { "att-1" });
        Assert.NotNull(user);
        Assert.Equal("att-1", Assert.Single(user!.AttachmentIds));
    }

    [Fact]
    public void TryBeginUserTurn_RejectsReentrantSendWhileInFlight()
    {
        var sm = new ChatSessionStateMachine();
        Assert.NotNull(sm.TryBeginUserTurn("first"));
        // Sentinel is set synchronously before streaming begins.
        Assert.Null(sm.TryBeginUserTurn("second"));
        Assert.Single(sm.Messages);
    }

    [Fact]
    public void TryBeginUserTurn_RejectedWhileStreaming()
    {
        var sm = new ChatSessionStateMachine();
        sm.TryBeginUserTurn("first");
        sm.BeginAssistantStream();
        Assert.True(sm.IsSendBusy);
        Assert.Null(sm.TryBeginUserTurn("second"));
    }

    [Fact]
    public void FirstAssistantBadge_ShownOnce_ThenNull()
    {
        var sm = new ChatSessionStateMachine();
        sm.TryBeginUserTurn("a");
        var first = sm.BeginAssistantStream("hermes");
        Assert.Equal("hermes", first.CliUsed);
        Assert.True(sm.FirstAssistantBadgeShown);
        sm.Ingest(new ChatStreamEvent.Text("x"));
        sm.CompleteStream();

        sm.TryBeginUserTurn("b");
        var second = sm.BeginAssistantStream("hermes");
        Assert.Null(second.CliUsed);
    }

    [Fact]
    public void Ingest_BumpsStreamingTick_PerEvent()
    {
        var sm = new ChatSessionStateMachine();
        sm.TryBeginUserTurn("a");
        sm.BeginAssistantStream();
        var before = sm.StreamingTick;
        sm.Ingest(new ChatStreamEvent.Text("x"));
        sm.Ingest(new ChatStreamEvent.Reasoning("y"));
        Assert.Equal(before + 2, sm.StreamingTick);
    }

    [Fact]
    public void Ingest_NoActiveStream_IsNoOp()
    {
        var sm = new ChatSessionStateMachine();
        sm.Ingest(new ChatStreamEvent.Text("stray"));
        Assert.Empty(sm.Messages);
        Assert.Equal(ChatStreamPhase.Idle, sm.Phase);
    }

    [Fact]
    public void Ingest_MergesUsage_KeepingMaxTotal()
    {
        var sm = new ChatSessionStateMachine();
        sm.TryBeginUserTurn("a");
        sm.BeginAssistantStream();
        sm.Ingest(new ChatStreamEvent.Usage(new CliUsageSnapshot(InputTokens: 6, OutputTokens: 4)));   // total 10
        sm.Ingest(new ChatStreamEvent.Usage(new CliUsageSnapshot(InputTokens: 3, OutputTokens: 2)));   // total 5
        Assert.Equal(10, sm.LatestUsage!.TotalTokens);
        sm.Ingest(new ChatStreamEvent.Usage(new CliUsageSnapshot(InputTokens: 12, OutputTokens: 8)));  // total 20
        Assert.Equal(20, sm.LatestUsage!.TotalTokens);
    }

    [Fact]
    public void CancelGeneration_ClearsFlags_KeepsPartial_AndRequestsCancel()
    {
        var sm = new ChatSessionStateMachine();
        var cancelRequested = false;
        sm.CancelRequested += () => cancelRequested = true;
        ChatStreamSettleOutcome? settled = null;
        sm.StreamSettled += o => settled = o;

        sm.TryBeginUserTurn("a");
        var placeholder = sm.BeginAssistantStream();
        sm.Ingest(new ChatStreamEvent.Text("partial"));
        sm.CancelGeneration();

        Assert.True(cancelRequested);
        Assert.False(sm.IsStreaming);
        Assert.Null(sm.ActiveStreamMessageId);
        Assert.Equal(ChatStreamPhase.Cancelled, sm.Phase);
        Assert.Equal("partial", placeholder.Content); // partial content survives
        Assert.NotNull(settled);
        Assert.True(settled!.Cancelled);
    }

    [Fact]
    public void FailStream_GenuineError_RecordsStreamError()
    {
        var sm = new ChatSessionStateMachine();
        sm.TryBeginUserTurn("a");
        sm.BeginAssistantStream();
        var outcome = sm.FailStream(cancelled: false, errorMessage: "boom");
        Assert.Equal("boom", sm.StreamError);
        Assert.Equal(ChatStreamPhase.Failed, sm.Phase);
        Assert.False(outcome.Cancelled);
        Assert.False(sm.IsStreaming);
    }

    [Fact]
    public void Ingest_StreamFailure_SettlesTypedFailureAndKeepsVisibleMessage()
    {
        var sm = new ChatSessionStateMachine();
        sm.TryBeginUserTurn("a");
        var assistant = sm.BeginAssistantStream();

        sm.Ingest(new ChatStreamEvent.StreamFailure(ChatFailureKind.MalformedStream, "bad json"));

        Assert.Equal(ChatStreamPhase.Failed, sm.Phase);
        Assert.Equal(ChatFailureKind.MalformedStream, sm.LastFailureKind);
        Assert.Equal("bad json", sm.StreamError);
        Assert.False(sm.IsStreaming);
        Assert.Equal("bad json", Assert.Single(assistant.TranscriptPieces).Value);
        Assert.Equal(ChatTranscriptPieceKind.Refusal, assistant.TranscriptPieces[0].Kind);
    }

    [Fact]
    public void FailStream_Cancelled_DoesNotSurfaceError()
    {
        var sm = new ChatSessionStateMachine();
        sm.TryBeginUserTurn("a");
        sm.BeginAssistantStream();
        sm.FailStream(cancelled: true, errorMessage: "ignored");
        Assert.Null(sm.StreamError);
        Assert.Equal(ChatStreamPhase.Cancelled, sm.Phase);
    }

    [Fact]
    public void PrepareRegeneration_DropsAssistant_ReturnsUserText()
    {
        var sm = RunOneTurn("what is 2+2?", "4");
        Assert.Equal(2, sm.Messages.Count);

        var userText = sm.PrepareRegeneration();
        Assert.Equal("what is 2+2?", userText);
        Assert.Single(sm.Messages);
        Assert.Equal(ChatMessageRole.User, sm.Messages[0].Role);
        Assert.Equal(ChatStreamPhase.Idle, sm.Phase);

        // Can immediately re-stream a fresh answer.
        var placeholder = sm.BeginAssistantStream("hermes");
        sm.Ingest(new ChatStreamEvent.Text("four"));
        sm.CompleteStream();
        Assert.Equal("four", placeholder.Content);
        Assert.Equal(2, sm.Messages.Count);
    }

    [Fact]
    public void PrepareRegeneration_WhileStreaming_ReturnsNull()
    {
        var sm = new ChatSessionStateMachine();
        sm.TryBeginUserTurn("a");
        sm.BeginAssistantStream();
        Assert.Null(sm.PrepareRegeneration());
    }

    [Fact]
    public void PrepareRegeneration_NoAssistantTurn_ReturnsNull()
    {
        var sm = new ChatSessionStateMachine();
        sm.TryBeginUserTurn("a"); // only a user turn, no assistant yet
        Assert.Null(sm.PrepareRegeneration());
    }

    [Fact]
    public void JumpToMemoryCitation_SetsTargetAndBumpsToken_EvenOnRepeat()
    {
        var sm = new ChatSessionStateMachine();
        sm.JumpToMemoryCitation("msg-1");
        Assert.Equal("msg-1", sm.PendingMemoryJumpMessageId);
        Assert.Equal(1, sm.MemoryJumpRequestToken);

        // Re-tapping the SAME id still advances the token so the flash re-runs.
        sm.JumpToMemoryCitation("msg-1");
        Assert.Equal(2, sm.MemoryJumpRequestToken);

        sm.ClearMemoryJump();
        Assert.Null(sm.PendingMemoryJumpMessageId);
    }

    [Fact]
    public void StreamSettled_FiresCompletedOutcome_OnComplete()
    {
        var sm = new ChatSessionStateMachine();
        ChatStreamSettleOutcome? settled = null;
        sm.StreamSettled += o => settled = o;
        sm.TryBeginUserTurn("a");
        sm.BeginAssistantStream();
        sm.CompleteStream();
        Assert.NotNull(settled);
        Assert.True(settled!.Completed);
        Assert.False(settled.Cancelled);
    }

    [Fact]
    public void Changed_Fires_OnEveryTransition()
    {
        var sm = new ChatSessionStateMachine();
        var count = 0;
        sm.Changed += () => count++;
        sm.TryBeginUserTurn("a");     // 1
        sm.BeginAssistantStream();     // 2
        sm.Ingest(new ChatStreamEvent.Text("x")); // 3
        sm.CompleteStream();           // 4
        Assert.Equal(4, count);
    }
}
