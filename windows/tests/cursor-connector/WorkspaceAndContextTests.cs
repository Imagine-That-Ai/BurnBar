using System;
using System.Text.Json;
using OpenBurnBar.App.CursorConnector;
using Xunit;

namespace OpenBurnBar.App.CursorConnector.Tests;

public sealed class WorkspaceAndContextTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 14, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Broker_EnforcesSingleCallAndClaimOwnership()
    {
        var broker = new WorkspaceBridgeBroker(new FixedClock(Now));
        WorkspaceToolCallSnapshot pending = broker.Enqueue(Invocation("call-1", "run-1"));
        Assert.Equal(WorkspaceToolCallStatus.Pending, pending.Status);
        Assert.Throws<InvalidOperationException>(() => broker.Enqueue(Invocation("call-2", "run-1")));
        Assert.Equal("client-a", broker.Claim("run-1", "client-a")?.ClaimedBy);
        Assert.Null(broker.Claim("run-1", "client-b"));
        Assert.Equal("client-a", broker.Claim("run-1", "client-a")?.ClaimedBy);
    }

    [Fact]
    public void Broker_ClaimsOldestAndRejectsStaleResult()
    {
        var broker = new WorkspaceBridgeBroker(new FixedClock(Now));
        broker.Enqueue(Invocation("later", "run-2", Now.AddSeconds(1)));
        broker.Enqueue(Invocation("first", "run-1", Now));
        Assert.Equal("run-1", broker.Claim(null, "client")?.RunId);
        Assert.Throws<InvalidOperationException>(() => broker.Complete(new WorkspaceToolResultSubmission(
            "run-1", "wrong", true, Json("{}"), null, Now)));
        WorkspaceToolCallSnapshot done = broker.Complete(new WorkspaceToolResultSubmission(
            "run-1", "first", true, Json("{\"ok\":true}"), null, Now));
        Assert.Equal(WorkspaceToolCallStatus.Completed, done.Status);
        Assert.Equal("first", broker.Clear("run-1", "first")?.CallId);
    }

    [Fact]
    public void Broker_CancelRemovesCallAndRestoreAcceptsOnlyActiveStates()
    {
        var broker = new WorkspaceBridgeBroker(new FixedClock(Now));
        broker.Enqueue(Invocation("call", "run"));
        Assert.Equal(WorkspaceToolCallStatus.Cancelled, broker.Cancel("run")?.Status);
        Assert.Null(broker.ActiveCall("run"));
        broker.Restore(new WorkspaceToolCallSnapshot("done", "run", "read_file", Json("{}"),
            WorkspaceToolCallStatus.Completed, "model", Now));
        Assert.Null(broker.ActiveCall("run"));
        broker.Restore(Invocation("pending", "run") is var input
            ? new WorkspaceToolCallSnapshot(input.CallId, input.RunId, input.Tool, input.Arguments,
                WorkspaceToolCallStatus.Pending, input.RequestedBy, input.RequestedAt)
            : throw new InvalidOperationException());
        Assert.NotNull(broker.ActiveCall("run"));
    }

    [Fact]
    public void ContextSelector_ProducesReadThenPatchSequence()
    {
        var selector = new ContextSelector();
        var intent = new AgentIntent(AgentIntentKind.ReplaceStringInFile, "replace", "replace",
            "src/app.cs", Replacement: new TextReplacement("old", "new"));
        ContextAction read = Assert.IsType<ContextAction>(selector.NextAction(intent, new ContextSelectionState(0, null, false)));
        Assert.Equal("read_file", read.Tool);
        ContextAction patch = Assert.IsType<ContextAction>(selector.NextAction(intent, new ContextSelectionState(1, "old value", false)));
        Assert.Equal("apply_patch", patch.Tool);
        Assert.Contains("new value", patch.Arguments.GetRawText(), StringComparison.Ordinal);
    }

    [Fact]
    public void ContextSelector_RejectsMissingReplacementAndMissingNeedle()
    {
        var selector = new ContextSelector();
        Assert.Throws<ArgumentException>(() => selector.NextAction(
            new AgentIntent(AgentIntentKind.ReplaceStringInFile, "x", "x", "a.cs"),
            new ContextSelectionState(0, null, false)));
        Assert.Throws<ArgumentException>(() => selector.NextAction(
            new AgentIntent(AgentIntentKind.ReplaceStringInFile, "x", "x", "a.cs", Replacement: new("absent", "new")),
            new ContextSelectionState(1, "content", false)));
    }

    [Fact]
    public void ContextSelector_DeduplicatesPathsAndPrioritizesSearch()
    {
        var selector = new ContextSelector();
        var intent = new AgentIntent(AgentIntentKind.InspectWorkspace, "inspect", "summary", "a.cs", "needle");
        AgentContextSnapshot snapshot = selector.MakeSnapshot(intent, new ContextSelectionState(0, null, false),
            "a.cs", new[] { "b.cs", "a.cs" });
        Assert.Equal(new[] { "a.cs", "b.cs" }, snapshot.CandidatePaths);
        ContextAction action = Assert.IsType<ContextAction>(selector.NextAction(intent, new ContextSelectionState(0, null, false)));
        Assert.Equal("search_workspace", action.Tool);
    }

    private static WorkspaceToolInvocation Invocation(string callId, string runId, DateTimeOffset? at = null) =>
        new(callId, runId, "read_file", Json("{\"path\":\"a.cs\"}"), "model", at ?? Now);

    private static JsonElement Json(string value)
    {
        using JsonDocument document = JsonDocument.Parse(value);
        return document.RootElement.Clone();
    }
}
