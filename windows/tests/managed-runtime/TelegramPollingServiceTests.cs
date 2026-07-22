using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Mission;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class TelegramPollingServiceTests
{
    [Theory]
    [InlineData("/help", TelegramCommand.Help)]
    [InlineData("pending", TelegramCommand.Pending)]
    [InlineData("/followups", TelegramCommand.Followups)]
    [InlineData("/done f-1", TelegramCommand.Done)]
    [InlineData("/snooze f-1 60", TelegramCommand.Snooze)]
    [InlineData("/calendar f-1 2026-07-15T12:00:00Z", TelegramCommand.Calendar)]
    [InlineData("/answer q-1 yes ship it", TelegramCommand.Answer)]
    [InlineData("/latest", TelegramCommand.Latest)]
    [InlineData("/status", TelegramCommand.Status)]
    [InlineData("/daily burnbar", TelegramCommand.RunDaily)]
    [InlineData("/run_daily burnbar", TelegramCommand.RunDaily)]
    [InlineData("/weekly burnbar", TelegramCommand.RunWeekly)]
    [InlineData("/run_weekly burnbar", TelegramCommand.RunWeekly)]
    public void Parser_MatchesMacOsCommandsAndAliases(string text, TelegramCommand expected)
    {
        TelegramCommandRequest request = Assert.IsType<TelegramCommandRequest>(
            TelegramCommandParser.Parse(text));

        Assert.Equal(expected, request.Command);
        Assert.Equal("telegram", request.Actor);
    }

    [Fact]
    public void Parser_PreservesCommandArguments()
    {
        TelegramCommandRequest request = Assert.IsType<TelegramCommandRequest>(
            TelegramCommandParser.Parse("/answer q-1 yes ship it"));

        Assert.Equal(new[] { "q-1", "yes", "ship", "it" }, request.Arguments);
        Assert.Null(TelegramCommandParser.Parse("/unknown"));
        Assert.Null(TelegramCommandParser.Parse("   "));
    }

    [Fact]
    public async Task PollOnce_SortsUpdatesPersistsOffsetAndFiltersConfiguredChat()
    {
        var client = new RecordingTelegramClient
        {
            Updates = new[]
            {
                new TelegramInboundMessage(12, "other-chat", "/status"),
                new TelegramInboundMessage(10, "chat-1", "/daily project-a"),
                new TelegramInboundMessage(11, "chat-1", "/unknown"),
            },
        };
        var offset = new RecordingOffsetStore(7);
        var commands = new List<TelegramCommandRequest>();
        await using var service = Service(client, offset, (request, _) =>
        {
            commands.Add(request);
            return Task.FromResult(new TelegramCommandResponse(true, "launched"));
        });

        await service.PollOnceAsync();

        Assert.Equal(7, client.RequestedOffset);
        TelegramCommandRequest command = Assert.Single(commands);
        Assert.Equal(TelegramCommand.RunDaily, command.Command);
        Assert.Equal(new long[] { 11, 12, 13 }, offset.SavedOffsets);
        Assert.Equal(new[] { ("chat-1", "launched") }, client.Sent);
    }

    [Fact]
    public async Task PollOnce_PersistsOffsetBeforeCommandFailure()
    {
        var client = new RecordingTelegramClient
        {
            Updates = new[] { new TelegramInboundMessage(44, "chat-1", "/status") },
        };
        var offset = new RecordingOffsetStore();
        await using var service = Service(client, offset, (_, _) =>
            throw new InvalidOperationException("handler failed"));

        await Assert.ThrowsAsync<InvalidOperationException>(() => service.PollOnceAsync());

        Assert.Equal(new long[] { 45 }, offset.SavedOffsets);
        Assert.Empty(client.Sent);
    }

    [Fact]
    public async Task DisabledConfiguration_DoesNotReadOffsetOrContactTelegram()
    {
        var client = new RecordingTelegramClient();
        var offset = new RecordingOffsetStore();
        await using var service = new TelegramPollingService(
            client,
            () => TelegramBridgeConfiguration.Disabled,
            offset,
            (_, _) => Task.FromResult(new TelegramCommandResponse(true, "ok")));

        await service.PollOnceAsync();

        Assert.Equal(0, offset.LoadCount);
        Assert.Equal(0, client.FetchCount);
    }

    [Fact]
    public async Task JsonOffsetStore_RoundTripsAndTreatsCorruptionAsNoOffset()
    {
        string directory = Path.Combine(Path.GetTempPath(), $"openburnbar-telegram-{Guid.NewGuid():N}");
        string path = Path.Combine(directory, "offset.json");
        try
        {
            var store = new JsonFileTelegramUpdateOffsetStore(path);
            Assert.Null(await store.LoadAsync());
            await store.SaveAsync(123);
            Assert.Equal(123, await store.LoadAsync());

            await File.WriteAllTextAsync(path, "not-json");
            Assert.Null(await store.LoadAsync());
        }
        finally
        {
            try { Directory.Delete(directory, recursive: true); } catch { /* best effort */ }
        }
    }

    private static TelegramPollingService Service(
        RecordingTelegramClient client,
        RecordingOffsetStore offset,
        Func<TelegramCommandRequest, CancellationToken, Task<TelegramCommandResponse>> handler) =>
        new(
            client,
            () => new TelegramBridgeConfiguration(
                true,
                "123:abc",
                "chat-1",
                TimeSpan.FromSeconds(5)),
            offset,
            handler);

    private sealed class RecordingTelegramClient : ITelegramBotClient
    {
        public IReadOnlyList<TelegramInboundMessage> Updates { get; init; } =
            Array.Empty<TelegramInboundMessage>();

        public int FetchCount { get; private set; }

        public long? RequestedOffset { get; private set; }

        public List<(string ChatId, string Text)> Sent { get; } = new();

        public Task<IReadOnlyList<TelegramInboundMessage>> FetchUpdatesAsync(
            string botToken,
            long? offset,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            FetchCount++;
            RequestedOffset = offset;
            return Task.FromResult(Updates);
        }

        public Task SendAsync(
            string botToken,
            string chatId,
            string text,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Sent.Add((chatId, text));
            return Task.CompletedTask;
        }
    }

    private sealed class RecordingOffsetStore(long? offset = null) : ITelegramUpdateOffsetStore
    {
        public int LoadCount { get; private set; }

        public List<long> SavedOffsets { get; } = new();

        public ValueTask<long?> LoadAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            LoadCount++;
            return ValueTask.FromResult(offset);
        }

        public ValueTask SaveAsync(long value, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            SavedOffsets.Add(value);
            offset = value;
            return ValueTask.CompletedTask;
        }
    }
}
