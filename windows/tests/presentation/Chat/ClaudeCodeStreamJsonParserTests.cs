using OpenBurnBar.App.Presentation.Chat;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Chat;

public sealed class ClaudeCodeStreamJsonParserTests
{
    [Fact]
    public void EventsFromLine_TextBlock_EmitsText()
    {
        var events = ClaudeCodeStreamJsonParser.EventsFromLine(
            """{"message":{"content":[{"type":"text","text":"hi"}]}}""");
        var text = Assert.IsType<ChatStreamEvent.Text>(Assert.Single(events));
        Assert.Equal("hi", text.Chunk);
    }

    [Fact]
    public void EventsFromLine_Malformed_ReturnsEmpty()
    {
        Assert.Empty(ClaudeCodeStreamJsonParser.EventsFromLine("{not-json"));
        Assert.Empty(ClaudeCodeStreamJsonParser.EventsFromLine(""));
    }

    [Fact]
    public void EventsFromLine_ToolUseAndResult()
    {
        var use = ClaudeCodeStreamJsonParser.EventsFromLine(
            """{"type":"tool_use","name":"Bash","input":{"command":"ls"}}""");
        var toolUse = Assert.IsType<ChatStreamEvent.ToolUse>(Assert.Single(use));
        Assert.Equal("Bash", toolUse.Name);
        Assert.Equal("ls", toolUse.Detail);

        var result = ClaudeCodeStreamJsonParser.EventsFromLine(
            """{"type":"tool_result","name":"Bash","content":"ok"}""");
        var toolResult = Assert.IsType<ChatStreamEvent.ToolResult>(Assert.Single(result));
        Assert.Equal("Bash", toolResult.Name);
        Assert.Equal("ok", toolResult.Detail);
    }

    [Fact]
    public void EventsFromLine_DeltaText()
    {
        var events = ClaudeCodeStreamJsonParser.EventsFromLine(
            """{"delta":{"text":"tok"}}""");
        Assert.Equal("tok", Assert.IsType<ChatStreamEvent.Text>(Assert.Single(events)).Chunk);
    }
}
