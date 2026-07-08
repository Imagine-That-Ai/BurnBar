using System.Text.Json.Nodes;
using OpenBurnBar.Pretext;
using Xunit;

namespace OpenBurnBar.Pretext.Tests;

// Direct assertions that the C# bridge codec matches the Swift `PretextEngine.call`
// escaping + `handleBridgeMessage` reply parsing, plus a full round-trip.

public class PretextBridgeTests
{
    [Theory]
    [InlineData("\"", "\\\"")]      // quote  -> \"
    [InlineData("\\", "\\\\")]      // backslash -> \\
    [InlineData("\n", "\\n")]       // LF -> \n
    [InlineData("\r", "\\r")]       // CR -> \r
    [InlineData("\t", "\\t")]       // tab -> \t
    [InlineData("\u2028", "\\u2028")] // JS line separator
    [InlineData("\u2029", "\\u2029")] // JS paragraph separator
    [InlineData("plain", "plain")]  // untouched
    public void Escape_matches_swift_character_map(string input, string expected)
    {
        Assert.Equal(expected, PretextBridge.EscapeForJsStringLiteral(input));
    }

    [Fact]
    public void Escape_processes_backslash_before_inserted_escapes()
    {
        // A literal backslash followed by a newline must become \\ then \n — never
        // a collapsed \\n (which would be an escaped-backslash + 'n'). This is why
        // the Swift order escapes backslash FIRST.
        Assert.Equal("\\\\\\n", PretextBridge.EscapeForJsStringLiteral("\\\n"));
    }

    [Fact]
    public void BuildDispatchScript_wraps_like_the_swift_call()
    {
        var script = PretextBridge.BuildDispatchScript(1, "ready", new JsonObject());
        Assert.StartsWith("window.__pretextDispatch && window.__pretextDispatch(\"", script);
        Assert.EndsWith("\");", script);
        // The inner payload is the escaped JSON request.
        Assert.Contains("\\\"method\\\":\\\"ready\\\"", script);
        Assert.Contains("\\\"id\\\":1", script);
    }

    [Fact]
    public void ParseReply_reads_ok_value()
    {
        var reply = PretextBridge.ParseReply("{\"id\":7,\"ok\":true,\"value\":{\"height\":44,\"lineCount\":2}}");
        Assert.Equal(7, reply.Id);
        Assert.False(reply.IsReady);
        Assert.True(reply.Ok);
        Assert.NotNull(reply.Value);
        Assert.Equal(44, reply.Value!.AsObject()["height"]!.GetValue<double>());
    }

    [Fact]
    public void ParseReply_reads_error()
    {
        var reply = PretextBridge.ParseReply("{\"id\":9,\"ok\":false,\"error\":\"boom\"}");
        Assert.Equal(9, reply.Id);
        Assert.False(reply.Ok);
        Assert.Equal("boom", reply.Error);
    }

    [Fact]
    public void ParseReply_flags_readiness_heartbeat()
    {
        var reply = PretextBridge.ParseReply("{\"id\":0,\"ok\":true,\"value\":{\"ready\":true}}");
        Assert.Equal(0, reply.Id);
        Assert.True(reply.IsReady);
    }

    [Theory]
    [InlineData("not json at all")]
    [InlineData("{\"no\":\"id\"}")]
    [InlineData("[1,2,3]")]
    public void ParseReply_marks_unaddressable_as_negative_id(string json)
    {
        var reply = PretextBridge.ParseReply(json);
        Assert.True(reply.Id < 0);
    }

    [Fact]
    public void Roundtrip_preserves_tricky_characters()
    {
        // Text with a quote, backslash, newline, tab, and a U+2028 must survive the
        // escape -> dispatch-script -> unescape -> JSON.parse round-trip intact.
        var tricky = "quote\" back\\slash\nnew\ttab\u2028sep";
        var request = PretextBridge.BuildRequest(42, "prepare", new JsonObject
        {
            ["text"] = tricky,
            ["font"] = "16px Arial",
        });
        var script = PretextBridge.BuildDispatchScript(request);

        var recovered = FakePretextWebHost.ParseDispatchScript(script);
        Assert.Equal(42, recovered.Id);
        Assert.Equal("prepare", recovered.Method);
        Assert.Equal(tricky, recovered.Params["text"]!.GetValue<string>());
        Assert.Equal("16px Arial", recovered.Params["font"]!.GetValue<string>());
    }
}
