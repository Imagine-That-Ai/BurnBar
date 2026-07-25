using System.Text.Json.Nodes;
using Xunit;

namespace OpenBurnBar.App.SharedUi.Tests;

/// <summary>
/// Pins the JS dispatch-script escaping — character-for-character parity with
/// OpenBurnBar.Pretext.PretextBridge (and through it, the Swift bridge): the
/// escaping order (backslash first) and the U+2028/U+2029 guards.
/// </summary>
public sealed class SharedUiBridgeScriptTests
{
    [Theory]
    [InlineData("plain", "plain")]
    [InlineData("back\\slash", "back\\\\slash")]
    [InlineData("say \"hi\"", "say \\\"hi\\\"")]
    [InlineData("line\nbreak", "line\\nbreak")]
    [InlineData("carriage\rreturn", "carriage\\rreturn")]
    [InlineData("tab\there", "tab\\there")]
    public void EscapeMatchesPretextBridgeOrder(string input, string expected)
    {
        Assert.Equal(expected, SharedUiBridgeScript.EscapeForJsStringLiteral(input));
    }

    [Fact]
    public void EscapeHandlesJsLineSeparators()
    {
        // U+2028 / U+2029 are illegal raw inside JS string literals, so the
        // escape must emit the six-character \uXXXX sequences.
        Assert.Equal("a\\u2028b", SharedUiBridgeScript.EscapeForJsStringLiteral("a\u2028b"));
        Assert.Equal("a\\u2029b", SharedUiBridgeScript.EscapeForJsStringLiteral("a\u2029b"));
    }

    [Fact]
    public void EscapeNeverDoublesInsertedBackslashes()
    {
        // Backslash-then-quote: the backslash escape MUST run first, producing
        // \\\" (escaped backslash + escaped quote), not \" + \" .
        Assert.Equal("\\\\\\\"", SharedUiBridgeScript.EscapeForJsStringLiteral("\\\""));
    }

    [Fact]
    public void DispatchScriptWrapsGuardedGlobalCall()
    {
        var script = SharedUiBridgeScript.BuildDispatchScript(
            SharedUiBridgeMessage.InvokeResult(1, null));
        Assert.Equal(
            """window.__obbShimDispatch && window.__obbShimDispatch(JSON.parse("{\"kind\":\"invoke-result\",\"id\":1,\"ok\":true,\"value\":null}"));""",
            script);
    }

    [Fact]
    public void DispatchScriptEscapesPayloadQuotes()
    {
        // {"error":"say \"no\""} — System.Text.Json's default encoder emits
        // quotes inside string values as \u0022; the JS-escaper must double
        // those backslashes so the renderer's JSON.parse restores the value.
        var message = new JsonObject { ["error"] = "say \"no\"" };
        var script = SharedUiBridgeScript.BuildDispatchScript(message);
        Assert.Equal(
            """window.__obbShimDispatch && window.__obbShimDispatch(JSON.parse("{\"error\":\"say \\u0022no\\u0022\"}"));""",
            script);
    }
}
