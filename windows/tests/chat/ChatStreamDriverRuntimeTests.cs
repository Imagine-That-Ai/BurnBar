using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Chat;
using OpenBurnBar.App.Presentation.Chat;
using Xunit;

namespace OpenBurnBar.App.Chat.Tests;

public sealed class ChatStreamDriverRuntimeTests
{
    private const string CliEnv = ChatStreamDriverFactory.CliCommandEnv;
    private const string SampleEnv = "OPENBURNBAR_SAMPLE_MODE";

    [Fact]
    public async Task Unavailable_driver_surfaces_explicit_configuration_guidance_not_scripted_demo()
    {
        var driver = new UnavailableChatStreamDriver();
        var events = new List<ChatStreamEvent>();

        await foreach (ChatStreamEvent evt in driver.StreamAsync("hello", Array.Empty<ChatMessageRecord>(), CancellationToken.None))
        {
            events.Add(evt);
        }

        ChatStreamEvent.StreamFailure failure = Assert.IsType<ChatStreamEvent.StreamFailure>(Assert.Single(events));
        Assert.Equal(ChatFailureKind.BackendUnavailable, failure.Kind);
        Assert.Contains("not configured", failure.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("OPENBURNBAR_SAMPLE_MODE=1", failure.Message);
    }

    [Fact]
    public async Task Scripted_driver_replays_representative_tokens_for_labeled_demo()
    {
        var driver = new ScriptedChatStreamDriver(tokenDelayMs: 0);
        var chunks = new List<string>();

        await foreach (ChatStreamEvent evt in driver.StreamAsync("hello", Array.Empty<ChatMessageRecord>(), CancellationToken.None))
        {
            if (evt is ChatStreamEvent.Text t)
            {
                chunks.Add(t.Chunk);
            }
        }

        string joined = string.Concat(chunks);
        Assert.Contains("found", joined, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("spent", joined, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task CliJsonLineDriver_MapsStreamJsonLines_ThroughShippedParser()
    {
        async IAsyncEnumerable<string> Lines(
            string userText,
            IReadOnlyList<ChatMessageRecord> history,
            [EnumeratorCancellation] CancellationToken ct)
        {
            await Task.Yield();
            yield return """{"message":{"content":[{"type":"text","text":"Hello "}]}}""";
            yield return """{"message":{"content":[{"type":"text","text":"world"}]}}""";
            yield return """{"type":"tool_use","name":"Read","input":{"path":"a.md"}}""";
            yield return """{"type":"tool_result","name":"Read","content":"ok"}""";
            yield return """{"usage":{"input_tokens":10,"output_tokens":5}}""";
        }

        var driver = new CliJsonLineChatStreamDriver(Lines);
        var events = new List<ChatStreamEvent>();
        await foreach (ChatStreamEvent evt in driver.StreamAsync("hi", Array.Empty<ChatMessageRecord>(), CancellationToken.None))
        {
            events.Add(evt);
        }

        Assert.Equal(5, events.Count);
        Assert.IsType<ChatStreamEvent.Text>(events[0]);
        Assert.Equal("Hello ", ((ChatStreamEvent.Text)events[0]).Chunk);
        Assert.Equal("world", ((ChatStreamEvent.Text)events[1]).Chunk);
        Assert.IsType<ChatStreamEvent.ToolUse>(events[2]);
        Assert.IsType<ChatStreamEvent.ToolResult>(events[3]);
        var usage = Assert.IsType<ChatStreamEvent.Usage>(events[4]);
        Assert.Equal(10, usage.Snapshot.InputTokens);
        Assert.Equal(5, usage.Snapshot.OutputTokens);
    }

    [Fact]
    public async Task CliJsonLineDriver_MalformedLine_EmitsTypedFailure()
    {
        async IAsyncEnumerable<string> Lines(
            string userText,
            IReadOnlyList<ChatMessageRecord> history,
            [EnumeratorCancellation] CancellationToken ct)
        {
            await Task.Yield();
            yield return "{not-json";
        }

        var driver = new CliJsonLineChatStreamDriver(Lines);
        var events = new List<ChatStreamEvent>();
        await foreach (ChatStreamEvent evt in driver.StreamAsync("hi", Array.Empty<ChatMessageRecord>(), CancellationToken.None))
        {
            events.Add(evt);
        }

        ChatStreamEvent.StreamFailure failure = Assert.IsType<ChatStreamEvent.StreamFailure>(Assert.Single(events));
        Assert.Equal(ChatFailureKind.MalformedStream, failure.Kind);
    }

    [Fact]
    public async Task CliJsonLineDriver_ProcessFailureRecord_EmitsTypedFailure()
    {
        async IAsyncEnumerable<string> Lines(
            string userText,
            IReadOnlyList<ChatMessageRecord> history,
            [EnumeratorCancellation] CancellationToken ct)
        {
            await Task.Yield();
            yield return """{"openburnbar_stream_error":{"kind":"ExecutableDenied","message":"not approved"}}""";
        }

        var driver = new CliJsonLineChatStreamDriver(Lines);
        var events = new List<ChatStreamEvent>();
        await foreach (ChatStreamEvent evt in driver.StreamAsync("hi", Array.Empty<ChatMessageRecord>(), CancellationToken.None))
        {
            events.Add(evt);
        }

        ChatStreamEvent.StreamFailure failure = Assert.IsType<ChatStreamEvent.StreamFailure>(Assert.Single(events));
        Assert.Equal(ChatFailureKind.ExecutableDenied, failure.Kind);
        Assert.Equal("not approved", failure.Message);
    }

    [Fact]
    public void Factory_SampleMode_UsesScripted()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, "1");
            Environment.SetEnvironmentVariable(CliEnv, null);
            IChatStreamDriver driver = ChatStreamDriverFactory.CreateDefault();
            Assert.IsType<ScriptedChatStreamDriver>(driver);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            Environment.SetEnvironmentVariable(CliEnv, null);
        }
    }

    [Fact]
    public void Factory_ProductionDefault_UsesCliJsonDriver()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            Environment.SetEnvironmentVariable(ChatStreamDriverFactory.CliDisableEnv, null);
            Environment.SetEnvironmentVariable(CliEnv, null);
            IChatStreamDriver driver = ChatStreamDriverFactory.CreateDefault();
            Assert.IsType<CliJsonLineChatStreamDriver>(driver);
            Assert.True(ChatStreamDriverFactory.IsCliConfigured());
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            Environment.SetEnvironmentVariable(ChatStreamDriverFactory.CliDisableEnv, null);
            Environment.SetEnvironmentVariable(CliEnv, null);
        }
    }

    [Fact]
    public void Factory_CliDisabled_UsesUnavailable()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            Environment.SetEnvironmentVariable(ChatStreamDriverFactory.CliDisableEnv, "1");
            IChatStreamDriver driver = ChatStreamDriverFactory.CreateDefault();
            Assert.IsType<UnavailableChatStreamDriver>(driver);
            Assert.False(ChatStreamDriverFactory.IsCliConfigured());
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            Environment.SetEnvironmentVariable(ChatStreamDriverFactory.CliDisableEnv, null);
        }
    }
}
