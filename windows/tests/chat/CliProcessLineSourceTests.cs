using OpenBurnBar.App.Chat;
using Xunit;

namespace OpenBurnBar.App.Chat.Tests;

public sealed class CliProcessLineSourceTests
{
    [Fact]
    public void ResolveCommandLine_DefaultEmbedsUserText()
    {
        string cmd = CliProcessLineSource.ResolveCommandLine("hello world");
        Assert.Contains("claude", cmd, System.StringComparison.Ordinal);
        Assert.Contains("stream-json", cmd, System.StringComparison.Ordinal);
        Assert.Contains("hello world", cmd, System.StringComparison.Ordinal);
    }

    [Fact]
    public void ResolveCommandLine_EnvOverride_Used()
    {
        try
        {
            System.Environment.SetEnvironmentVariable(ChatStreamDriverFactory.CliCommandEnv, "mycli --json {0}");
            string cmd = CliProcessLineSource.ResolveCommandLine("x");
            Assert.StartsWith("mycli", cmd, System.StringComparison.Ordinal);
            Assert.Contains("x", cmd, System.StringComparison.Ordinal);
        }
        finally
        {
            System.Environment.SetEnvironmentVariable(ChatStreamDriverFactory.CliCommandEnv, null);
        }
    }
}
