using System;
using System.Text.Json;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.ManagedAgentRuntime.Mission;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class CompanionCliTelegramHandlerTests
{
    [Fact]
    public async Task Router_RecordsFollowupsAndExecutesNotificationCommands()
    {
        var state = new InMemoryTelegramMissionStateStore();
        var commands = new TelegramMissionCommandHandler(
            state,
            _ => Task.FromResult("ready"),
            (_, _, _) => Task.FromResult("run-1"));
        var router = new CompanionCliCommandRouter(
            telegram: new CompanionCliTelegramHandler(commands));

        string recorded = await router.HandleAsync(
            "{\"op\":\"notification.followup.record\",\"id\":\"f-1\","
            + "\"projectSlug\":\"burnbar\",\"title\":\"Review\",\"summary\":\"Check evidence\"}",
            default);
        string listed = await router.HandleAsync(
            "{\"op\":\"notification.command\",\"text\":\"/pending\"}",
            default);

        using JsonDocument recordedJson = JsonDocument.Parse(recorded);
        using JsonDocument listedJson = JsonDocument.Parse(listed);
        Assert.True(recordedJson.RootElement.GetProperty("ok").GetBoolean());
        Assert.True(listedJson.RootElement.GetProperty("ok").GetBoolean());
        Assert.Contains(
            "f-1: Review",
            listedJson.RootElement.GetProperty("result").GetProperty("message").GetString(),
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task Router_RejectsOversizedOrMalformedNotificationRecords()
    {
        var commands = new TelegramMissionCommandHandler(
            new InMemoryTelegramMissionStateStore(),
            _ => Task.FromResult("ready"),
            (_, _, _) => Task.FromResult("run-1"));
        var router = new CompanionCliCommandRouter(
            telegram: new CompanionCliTelegramHandler(commands));

        string response = await router.HandleAsync(
            "{\"op\":\"notification.question.record\",\"id\":\"q-1\"}",
            default);

        using JsonDocument json = JsonDocument.Parse(response);
        Assert.False(json.RootElement.GetProperty("ok").GetBoolean());
        Assert.Equal("invalid_request", json.RootElement.GetProperty("error").GetString());
    }
}
