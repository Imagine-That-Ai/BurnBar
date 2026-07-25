using System.Text.Json.Nodes;
using Xunit;

namespace OpenBurnBar.App.SharedUi.Tests;

/// <summary>
/// Pins the shim wire codec against the exact messages
/// apps/linux-desktop/src/shim/tauriWebviewShim.ts posts.
/// </summary>
public sealed class SharedUiBridgeMessageTests
{
    [Fact]
    public void ParseInvoke_WithArgs()
    {
        var message = SharedUiBridgeMessage.TryParse(
            """{"kind":"invoke","id":7,"command":"session_search","args":{"query":"burn"}}""");

        var invoke = Assert.IsType<SharedUiInboundMessage.Invoke>(message);
        Assert.Equal(7, invoke.Id);
        Assert.Equal("session_search", invoke.Command);
        Assert.Equal("burn", invoke.Args["query"]!.GetValue<string>());
    }

    [Fact]
    public void ParseInvoke_ChannelArgReadsChannelId()
    {
        var message = SharedUiBridgeMessage.TryParse(
            """{"kind":"invoke","id":3,"command":"gateway_chat_stream","args":{"request":{"requestId":"r1"},"onEvent":{"__channel":42}}}""");

        var invoke = Assert.IsType<SharedUiInboundMessage.Invoke>(message);
        Assert.True(SharedUiBridgeMessage.TryReadChannelId(invoke.Args, "onEvent", out int channelId));
        Assert.Equal(42, channelId);
    }

    [Fact]
    public void ParseInvoke_MissingArgsBecomesEmptyObject()
    {
        var message = SharedUiBridgeMessage.TryParse(
            """{"kind":"invoke","id":1,"command":"daemon_health"}""");

        var invoke = Assert.IsType<SharedUiInboundMessage.Invoke>(message);
        Assert.NotNull(invoke.Args);
        Assert.Empty(invoke.Args);
    }

    [Fact]
    public void ParseListen()
    {
        var message = SharedUiBridgeMessage.TryParse(
            """{"kind":"listen","event":"media-call-state-changed"}""");

        var listen = Assert.IsType<SharedUiInboundMessage.Listen>(message);
        Assert.Equal("media-call-state-changed", listen.Event);
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("""{"kind":"nope"}""")]
    [InlineData("""{"kind":"invoke","id":0,"command":"x"}""")]
    [InlineData("""{"kind":"invoke","id":1}""")]
    [InlineData("""{"kind":"invoke","id":1,"command":"  "}""")]
    [InlineData("""{"kind":"listen"}""")]
    [InlineData("""[1,2,3]""")]
    [InlineData("""{"kind":"invoke","id":"1","command":"x"}""")]
    public void MalformedMessagesAreDropped(string json)
    {
        Assert.Null(SharedUiBridgeMessage.TryParse(json));
    }

    [Fact]
    public void InvokeResultEnvelopeMatchesShimContract()
    {
        var reply = SharedUiBridgeMessage.InvokeResult(9, new JsonObject { ["ok"] = true });
        Assert.Equal("invoke-result", reply["kind"]!.GetValue<string>());
        Assert.Equal(9, reply["id"]!.GetValue<int>());
        Assert.True(reply["ok"]!.GetValue<bool>());
        Assert.True(reply["value"]!["ok"]!.GetValue<bool>());
    }

    [Fact]
    public void InvokeErrorEnvelopeMatchesShimContract()
    {
        var reply = SharedUiBridgeMessage.InvokeError(4, "not implemented on Windows: pet_feed");
        Assert.Equal("invoke-result", reply["kind"]!.GetValue<string>());
        Assert.Equal(4, reply["id"]!.GetValue<int>());
        Assert.False(reply["ok"]!.GetValue<bool>());
        Assert.Equal("not implemented on Windows: pet_feed", reply["error"]!.GetValue<string>());
        Assert.Null(reply["value"]);
    }

    [Fact]
    public void ChannelAndEventEnvelopesMatchShimContract()
    {
        var chunk = SharedUiBridgeMessage.ChannelChunk(11, "data: [DONE]\n\n");
        Assert.Equal("channel", chunk["kind"]!.GetValue<string>());
        Assert.Equal(11, chunk["channelId"]!.GetValue<int>());
        Assert.Equal("data: [DONE]\n\n", chunk["chunk"]!.GetValue<string>());

        var evt = SharedUiBridgeMessage.Event("media-incoming-call", new JsonObject { ["phase"] = "ringing" });
        Assert.Equal("event", evt["kind"]!.GetValue<string>());
        Assert.Equal("media-incoming-call", evt["event"]!.GetValue<string>());
        Assert.Equal("ringing", evt["payload"]!["phase"]!.GetValue<string>());
    }
}
