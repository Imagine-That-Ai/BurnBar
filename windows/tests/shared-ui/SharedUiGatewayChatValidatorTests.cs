using System.Linq;
using System.Text.Json.Nodes;
using Xunit;

namespace OpenBurnBar.App.SharedUi.Tests;

/// <summary>
/// The gateway_chat_stream request validator — pins the lib.rs taxonomy
/// (gateway_invalid_request_id / gateway_invalid_model /
/// gateway_invalid_message_count / gateway_invalid_message_role /
/// gateway_request_too_large) and the 1 MiB content / 256 message bounds.
/// </summary>
public sealed class SharedUiGatewayChatValidatorTests
{
    private static JsonObject Args(string requestId, string model, params (string Role, string Content)[] messages)
    {
        var array = new JsonArray();
        foreach (var (role, content) in messages)
        {
            array.Add(new JsonObject { ["role"] = role, ["content"] = content });
        }

        return new JsonObject
        {
            ["request"] = new JsonObject
            {
                ["requestId"] = requestId,
                ["model"] = model,
                ["messages"] = array,
            },
        };
    }

    [Fact]
    public void ValidRequestPasses()
    {
        var (requestId, model, messages) = SharedUiGatewayChatValidator.ValidateRequest(
            Args("req-1_ABC", "claude-opus", ("system", "s"), ("user", "hello"), ("assistant", "hi"), ("tool", "out")));
        Assert.Equal("req-1_ABC", requestId);
        Assert.Equal("claude-opus", model);
        Assert.Equal(4, messages.Count);
    }

    [Theory]
    [InlineData("", "gateway_invalid_request_id")]
    [InlineData("has space", "gateway_invalid_request_id")]
    [InlineData("slash/id", "gateway_invalid_request_id")]
    [InlineData("unicode-é", "gateway_invalid_request_id")]
    public void RequestIdValidation(string requestId, string expectedError)
    {
        var ex = Assert.Throws<SharedUiCommandException>(() =>
            SharedUiGatewayChatValidator.ValidateRequest(Args(requestId, "m", ("user", "hi"))));
        Assert.Equal(expectedError, ex.Message);
    }

    [Fact]
    public void RequestIdLongerThan128IsRefused()
    {
        var ex = Assert.Throws<SharedUiCommandException>(() =>
            SharedUiGatewayChatValidator.ValidateRequest(Args(new string('a', 129), "m", ("user", "hi"))));
        Assert.Equal("gateway_invalid_request_id", ex.Message);
    }

    [Theory]
    [InlineData("", "gateway_invalid_model")]
    [InlineData("   ", "gateway_invalid_model")]
    public void ModelValidation(string model, string expectedError)
    {
        var ex = Assert.Throws<SharedUiCommandException>(() =>
            SharedUiGatewayChatValidator.ValidateRequest(Args("req-1", model, ("user", "hi"))));
        Assert.Equal(expectedError, ex.Message);
    }

    [Fact]
    public void ModelIsTrimmedBeforeValidation()
    {
        var (_, model, _) = SharedUiGatewayChatValidator.ValidateRequest(Args("req-1", "  opus  ", ("user", "hi")));
        Assert.Equal("opus", model);
    }

    [Fact]
    public void EmptyMessageListIsRefused()
    {
        var ex = Assert.Throws<SharedUiCommandException>(() =>
            SharedUiGatewayChatValidator.ValidateRequest(Args("req-1", "m")));
        Assert.Equal("gateway_invalid_message_count", ex.Message);
    }

    [Fact]
    public void MoreThan256MessagesIsRefused()
    {
        var messages = Enumerable.Repeat(("user", "hi"), 257).ToArray();
        var ex = Assert.Throws<SharedUiCommandException>(() =>
            SharedUiGatewayChatValidator.ValidateRequest(Args("req-1", "m", messages)));
        Assert.Equal("gateway_invalid_message_count", ex.Message);
    }

    [Theory]
    [InlineData("developer")]
    [InlineData("function")]
    [InlineData("")]
    public void UnknownRolesAreRefused(string role)
    {
        var ex = Assert.Throws<SharedUiCommandException>(() =>
            SharedUiGatewayChatValidator.ValidateRequest(Args("req-1", "m", (role, "hi"))));
        Assert.Equal("gateway_invalid_message_role", ex.Message);
    }

    [Fact]
    public void ContentBytesAreMeasuredInUtf8()
    {
        // (1 MiB − 1) ASCII bytes + a 2-byte 'é' = 1 MiB + 1 UTF-8 bytes —
        // over the byte cap even though the char count is under it.
        var content = new string('a', SharedUiGatewayChatValidator.MaxContentBytes - 1) + "é";
        var ex = Assert.Throws<SharedUiCommandException>(() =>
            SharedUiGatewayChatValidator.ValidateRequest(Args("req-1", "m", ("user", content))));
        Assert.Equal("gateway_request_too_large", ex.Message);
    }

    [Fact]
    public void ContentAtTheByteCapPasses()
    {
        var content = new string('a', SharedUiGatewayChatValidator.MaxContentBytes);
        var (requestId, _, _) = SharedUiGatewayChatValidator.ValidateRequest(Args("req-1", "m", ("user", content)));
        Assert.Equal("req-1", requestId);
    }
}
