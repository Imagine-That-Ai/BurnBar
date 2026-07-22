using System.Text;
using System.Text.Json;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class AnthropicProviderAdapterTests
{
    [Fact]
    public void ToolChoiceNoneIsOmittedFromAnthropicRequest()
    {
        byte[] request = Encoding.UTF8.GetBytes("""
            {
              "messages": [{"role":"user","content":"hello"}],
              "tools": [{"type":"function","function":{"name":"lookup","parameters":{"type":"object"}}}],
              "tool_choice": "none"
            }
            """);

        using JsonDocument converted = JsonDocument.Parse(
            AnthropicProviderAdapter.ToMessagesRequest(request, "claude-test"));

        Assert.True(converted.RootElement.TryGetProperty("tools", out _));
        Assert.False(converted.RootElement.TryGetProperty("tool_choice", out _));
    }
}
