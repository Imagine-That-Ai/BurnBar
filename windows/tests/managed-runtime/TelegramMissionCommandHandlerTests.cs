using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Mission;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class TelegramMissionCommandHandlerTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 14, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public async Task FollowupCommands_ListSnoozeAndCompleteDurableState()
    {
        var store = new InMemoryTelegramMissionStateStore(new TelegramMissionState(
            new[] { new TelegramFollowup("f-1", "burnbar", "Review release", "Check evidence") },
            Array.Empty<TelegramQuestion>()));
        var handler = Handler(store);

        TelegramCommandResponse pending = await handler.HandleAsync(Request(TelegramCommand.Pending));
        TelegramCommandResponse snoozed = await handler.HandleAsync(
            Request(TelegramCommand.Snooze, "f-1", "30"));
        TelegramCommandResponse hidden = await handler.HandleAsync(Request(TelegramCommand.Followups));
        TelegramCommandResponse done = await handler.HandleAsync(Request(TelegramCommand.Done, "f-1"));

        Assert.Contains("f-1: Review release", pending.Message, StringComparison.Ordinal);
        Assert.Equal("Snoozed Review release for 30m.", snoozed.Message);
        Assert.Equal("No unresolved followups.", hidden.Message);
        Assert.Equal("Marked Review release done.", done.Message);
        TelegramMissionState state = await store.LoadAsync();
        Assert.True(Assert.Single(state.Followups).IsDone);
    }

    [Fact]
    public async Task AnswerCommand_RecordsActorAndFullAnswer()
    {
        var store = new InMemoryTelegramMissionStateStore(new TelegramMissionState(
            Array.Empty<TelegramFollowup>(),
            new[] { new TelegramQuestion("q-1", "burnbar", "Ship?") }));
        var handler = Handler(store);

        TelegramCommandResponse response = await handler.HandleAsync(
            Request(TelegramCommand.Answer, "q-1", "yes", "ship", "it"));

        Assert.Equal("Answered Ship?.", response.Message);
        TelegramQuestion question = Assert.Single((await store.LoadAsync()).Questions);
        Assert.Equal("yes ship it", question.Answer);
        Assert.Equal("telegram", question.AnsweredBy);
    }

    [Fact]
    public async Task StatusAndReviewCommands_UseProductionDelegates()
    {
        var launches = new List<(string Project, bool Weekly)>();
        var handler = new TelegramMissionCommandHandler(
            new InMemoryTelegramMissionStateStore(),
            _ => Task.FromResult("2 active runs"),
            (project, weekly, _) =>
            {
                launches.Add((project, weekly));
                return Task.FromResult("run-123");
            },
            () => Now);

        TelegramCommandResponse status = await handler.HandleAsync(Request(TelegramCommand.Status));
        TelegramCommandResponse review = await handler.HandleAsync(
            Request(TelegramCommand.RunWeekly, "burnbar"));

        Assert.Equal(
            "Projects: 0, pending questions: 0, open followups: 0. 2 active runs",
            status.Message);
        Assert.Equal("Launched weekly review for burnbar (run run-123).", review.Message);
        Assert.Equal(new[] { ("burnbar", true) }, launches);
    }

    [Fact]
    public async Task InvalidMutations_FailClosedWithoutChangingState()
    {
        var store = new InMemoryTelegramMissionStateStore();
        var handler = Handler(store);

        TelegramCommandResponse missingDone = await handler.HandleAsync(Request(TelegramCommand.Done));
        TelegramCommandResponse badSnooze = await handler.HandleAsync(
            Request(TelegramCommand.Snooze, "f-1", "999999"));
        TelegramCommandResponse missingAnswer = await handler.HandleAsync(
            Request(TelegramCommand.Answer, "q-1", "yes"));

        Assert.False(missingDone.Ok);
        Assert.False(badSnooze.Ok);
        Assert.False(missingAnswer.Ok);
        Assert.Equal(TelegramMissionState.Empty, await store.LoadAsync());
    }

    [Fact]
    public async Task RecordMethods_UpsertAndBoundState()
    {
        var store = new InMemoryTelegramMissionStateStore();
        var handler = Handler(store);

        await handler.RecordFollowupAsync(new TelegramFollowup("f-1", "p", "old", "summary"));
        await handler.RecordFollowupAsync(new TelegramFollowup("f-1", "p", "new", "summary"));
        await handler.RecordQuestionAsync(new TelegramQuestion("q-1", "p", "Question"));

        TelegramMissionState state = await store.LoadAsync();
        Assert.Equal("new", Assert.Single(state.Followups).Title);
        Assert.Equal("q-1", Assert.Single(state.Questions).Id);
    }

    [Fact]
    public async Task DueFollowups_AreDeliveredOnceAndRescheduled()
    {
        var store = new InMemoryTelegramMissionStateStore(new TelegramMissionState(
            new[] { new TelegramFollowup("f-1", "burnbar", "Review", "Check evidence") },
            Array.Empty<TelegramQuestion>()));
        var handler = Handler(store);

        IReadOnlyList<string> first = await handler.TakeDueFollowupMessagesAsync(30);
        IReadOnlyList<string> second = await handler.TakeDueFollowupMessagesAsync(30);

        Assert.Equal("[burnbar] Followup due\nReview\nCheck evidence", Assert.Single(first));
        Assert.Empty(second);
        Assert.Equal(Now.AddMinutes(30), Assert.Single((await store.LoadAsync()).Followups).NextNudgeAt);
    }

    private static TelegramMissionCommandHandler Handler(ITelegramMissionStateStore store) =>
        new(
            store,
            _ => Task.FromResult("status"),
            (_, _, _) => Task.FromResult("run-1"),
            () => Now);

    private static TelegramCommandRequest Request(
        TelegramCommand command,
        params string[] arguments) =>
        new(command, arguments, "telegram");
}
