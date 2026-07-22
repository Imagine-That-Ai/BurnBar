using OpenBurnBar.App.Configuration;
using Xunit;

namespace OpenBurnBar.App.Configuration.Tests;

public sealed class WindowsCreateProcessCommandLineTests
{
    [Theory]
    [InlineData("codex", "codex")]
    [InlineData("", "\"\"")]
    [InlineData("hello world", "\"hello world\"")]
    [InlineData("say\"hello", "\"say\\\"hello\"")]
    [InlineData("C:\\Program Files\\", "\"C:\\Program Files\\\\\"")]
    [InlineData("a\\\"b", "\"a\\\\\\\"b\"")]
    public void QuoteFollowsCreateProcessArgvRules(string value, string expected)
    {
        Assert.Equal(expected, WindowsCreateProcessCommandLine.Quote(value));
    }

    [Fact]
    public void BuildPreservesExecutableAndArgumentBoundaries()
    {
        string commandLine = WindowsCreateProcessCommandLine.Build(
            @"C:\Program Files\OpenBurnBar\codex.exe",
            new[] { "--project", "hello & goodbye", "", @"tail\" });

        Assert.Equal(
            "\"C:\\Program Files\\OpenBurnBar\\codex.exe\" --project \"hello & goodbye\" \"\" \"tail\\\\\"",
            commandLine);
    }
}
