using System.Diagnostics;
using System.Linq;
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

    [Fact]
    public void ResolveProcessSpec_DefaultPreservesMetacharactersAsSingleArgument()
    {
        string prompt = "hello & del C:\\nope | $(bad) \"quoted\"";
        ChildProcessSpec spec = CliProcessLineSource.ResolveProcessSpec(prompt);

        Assert.Equal("claude", spec.FileName);
        Assert.Equal(prompt, spec.Arguments[1]);
        Assert.Contains("--output-format", spec.Arguments);
    }

    [Fact]
    public void CreateStartInfo_UsesArgumentListAndSecretFreeEnvironment()
    {
        try
        {
            System.Environment.SetEnvironmentVariable("OPENAI_API_KEY", "forbidden-canary");
            System.Environment.SetEnvironmentVariable("OPENBURNBAR_SQLCIPHER_PASSPHRASE", "forbidden-canary");
            System.Environment.SetEnvironmentVariable("DIAGNOSTIC_CANARY_SECRET", "forbidden-canary");

            ProcessStartInfo psi = CliProcessLineSource.CreateStartInfo(
                new ChildProcessSpec("claude", new[] { "-p", "hi" }));

            Assert.False(psi.UseShellExecute);
            Assert.Equal("claude", psi.FileName);
            Assert.Empty(psi.Arguments);
            Assert.Equal(new[] { "-p", "hi" }, psi.ArgumentList.ToArray());
            Assert.False(psi.Environment.ContainsKey("OPENAI_API_KEY"));
            Assert.False(psi.Environment.ContainsKey("OPENBURNBAR_SQLCIPHER_PASSPHRASE"));
            Assert.False(psi.Environment.ContainsKey("DIAGNOSTIC_CANARY_SECRET"));
        }
        finally
        {
            System.Environment.SetEnvironmentVariable("OPENAI_API_KEY", null);
            System.Environment.SetEnvironmentVariable("OPENBURNBAR_SQLCIPHER_PASSPHRASE", null);
            System.Environment.SetEnvironmentVariable("DIAGNOSTIC_CANARY_SECRET", null);
        }
    }
}
