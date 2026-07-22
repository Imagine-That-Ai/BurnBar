using System;
using System.Linq;
using OpenBurnBar.App.Presentation.Chat;
using Xunit;

namespace OpenBurnBar.App.Chat.Tests;

public sealed class ChatPromptComposerTests
{
    [Fact]
    public void ComposeIncludesPriorTurnsAndCurrentUserOnlyOnce()
    {
        var history = new[]
        {
            new ChatMessageRecord(ChatMessageRole.User, "first question"),
            new ChatMessageRecord(ChatMessageRole.Assistant, "first answer"),
            new ChatMessageRecord(ChatMessageRole.User, "second question"),
        };

        string prompt = ChatPromptComposer.Compose("second question", history);

        Assert.Contains("first question", prompt, StringComparison.Ordinal);
        Assert.Contains("first answer", prompt, StringComparison.Ordinal);
        Assert.Equal(1, prompt.Split("second question", StringSplitOptions.None).Length - 1);
        Assert.Contains("Current user request (authoritative):", prompt, StringComparison.Ordinal);
    }

    [Fact]
    public void ComposeCarriesAttachmentMetadataWithoutAbsolutePaths()
    {
        var attachment = new ChatAttachmentRecord(
            "a1", "text", "notes.md", "text/markdown", 42, @"C:\Users\Alberto\notes.md", "preview text");
        var history = new[]
        {
            new ChatMessageRecord(ChatMessageRole.User, "read this", attachments: new[] { attachment }),
        };

        string prompt = ChatPromptComposer.Compose("continue", history);

        Assert.Contains("notes.md", prompt, StringComparison.Ordinal);
        Assert.Contains("preview text", prompt, StringComparison.Ordinal);
        Assert.DoesNotContain("C:\\", prompt, StringComparison.Ordinal);
        Assert.DoesNotContain("/Users/", prompt, StringComparison.Ordinal);
    }

    [Fact]
    public void ComposeCapsHistoryAndPromptSize()
    {
        var history = Enumerable.Range(0, 80)
            .Select(index => new ChatMessageRecord(ChatMessageRole.Assistant, new string('x', 20_000)))
            .ToArray();

        string prompt = ChatPromptComposer.Compose("latest", history);

        Assert.True(prompt.Length <= ChatPromptComposer.MaxPromptCharacters);
        Assert.Contains("latest", prompt, StringComparison.Ordinal);
        Assert.Contains("<openburnbar-transcript-context>", prompt, StringComparison.Ordinal);
    }
}
