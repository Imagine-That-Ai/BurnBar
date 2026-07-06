using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Chat;
using OpenBurnBar.App.Presentation.Chat;
using Xunit;

namespace OpenBurnBar.App.Chat.Tests;

public sealed class ChatStreamDriverRuntimeTests
{
    [Fact]
    public async Task Unavailable_driver_surfaces_explicit_configuration_guidance_not_scripted_demo()
    {
        var driver = new UnavailableChatStreamDriver();
        var events = new List<ChatStreamEvent>();

        await foreach (ChatStreamEvent evt in driver.StreamAsync("hello", Array.Empty<ChatMessageRecord>(), CancellationToken.None))
        {
            events.Add(evt);
        }

        ChatStreamEvent.Text text = Assert.IsType<ChatStreamEvent.Text>(Assert.Single(events));
        Assert.Contains("not configured", text.Chunk, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("OPENBURNBAR_SAMPLE_MODE=1", text.Chunk);
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
}