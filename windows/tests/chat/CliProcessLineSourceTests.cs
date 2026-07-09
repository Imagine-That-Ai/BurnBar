using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using OpenBurnBar.App.Chat;
using OpenBurnBar.App.Presentation.Chat;
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
    public void CreateStartInfo_UsesApprovedExecutableArgumentListAndSecretFreeEnvironment()
    {
        try
        {
            System.Environment.SetEnvironmentVariable("OPENAI_API_KEY", "forbidden-canary");
            System.Environment.SetEnvironmentVariable("OPENBURNBAR_SQLCIPHER_PASSPHRASE", "forbidden-canary");
            System.Environment.SetEnvironmentVariable("DIAGNOSTIC_CANARY_SECRET", "forbidden-canary");
            string executable = System.Environment.ProcessPath!;
            var catalog = CatalogFor(executable);

            ProcessStartInfo psi = ChatProcessRunner.CreateStartInfo(
                new ChildProcessSpec(executable, new[] { "-p", "hi" }),
                catalog);

            Assert.False(psi.UseShellExecute);
            Assert.Equal(executable, psi.FileName);
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

    [Fact]
    public void ApprovedCatalog_DeniesExecutableReplacement()
    {
        string helper = CopyExecutableForMutation();
        string sha = ApprovedChatExecutableCatalog.ComputeSha256(helper);
        var catalog = new ApprovedChatExecutableCatalog(new[]
        {
            new ApprovedChatExecutable("helper", helper, sha),
        });

        File.AppendAllText(helper, "mutation");

        ChatProcessException ex = Assert.Throws<ChatProcessException>(() => catalog.Resolve(helper));
        Assert.Equal(ChatFailureKind.ExecutableReplaced, ex.Kind);
    }

    [Fact]
    public async System.Threading.Tasks.Task ReadLinesAsync_PreservesMetacharactersAsData()
    {
        string? echo = ExistingExecutable("/bin/echo", "/usr/bin/echo");
        if (echo is null)
        {
            return;
        }

        string prompt = "hello & | < > ^ % ! \"quoted\" unicode-Δ newline\\ntext";
        var lines = new System.Collections.Generic.List<string>();
        await foreach (string line in CliProcessLineSource.ReadLinesAsync(
            new ChildProcessSpec(echo, new[] { prompt }),
            CatalogFor(echo),
            new ChatProcessLimits(1024 * 1024, 1024 * 1024),
            System.Threading.CancellationToken.None))
        {
            lines.Add(line);
        }

        Assert.Equal(prompt, AssertSingleNonFailure(lines));
    }

    [Fact]
    public async System.Threading.Tasks.Task ReadLinesAsync_UnapprovedExecutableReturnsTypedDenial()
    {
        string executable = System.Environment.ProcessPath!;
        var lines = new System.Collections.Generic.List<string>();

        await foreach (string line in CliProcessLineSource.ReadLinesAsync(
            new ChildProcessSpec(executable, new[] { "--version" }),
            new ApprovedChatExecutableCatalog(System.Array.Empty<ApprovedChatExecutable>()),
            new ChatProcessLimits(1024, 1024),
            System.Threading.CancellationToken.None))
        {
            lines.Add(line);
        }

        string failure = Assert.Single(lines);
        Assert.Contains("ExecutableDenied", failure, System.StringComparison.Ordinal);
    }

    [Fact]
    public async System.Threading.Tasks.Task ReadLinesAsync_OutputLimitBecomesTypedFailure()
    {
        string? yes = ExistingExecutable("/usr/bin/yes");
        if (yes is null)
        {
            return;
        }

        var lines = new System.Collections.Generic.List<string>();
        await foreach (string line in CliProcessLineSource.ReadLinesAsync(
            new ChildProcessSpec(yes, new[] { "x" }),
            CatalogFor(yes),
            new ChatProcessLimits(64, 16),
            System.Threading.CancellationToken.None))
        {
            lines.Add(line);
            if (lines.Count > 128)
            {
                break;
            }
        }

        Assert.Contains(lines, line => line.Contains("OutputLimitExceeded", System.StringComparison.Ordinal));
    }

    [Fact]
    public async System.Threading.Tasks.Task ReadLinesAsync_CancellationReturnsTypedFailure()
    {
        string? sleep = ExistingExecutable("/bin/sleep", "/usr/bin/sleep");
        if (sleep is null)
        {
            return;
        }

        using var cts = new System.Threading.CancellationTokenSource();
        cts.CancelAfter(System.TimeSpan.FromMilliseconds(100));
        var lines = new System.Collections.Generic.List<string>();

        await foreach (string line in CliProcessLineSource.ReadLinesAsync(
            new ChildProcessSpec(sleep, new[] { "30" }),
            CatalogFor(sleep),
            new ChatProcessLimits(1024 * 1024, 1024 * 1024),
            cts.Token))
        {
            lines.Add(line);
        }

        Assert.Contains(lines, line => line.Contains("Cancelled", System.StringComparison.Ordinal));
    }

    private static string AssertSingleNonFailure(System.Collections.Generic.IReadOnlyList<string> lines)
    {
        string line = Assert.Single(lines);
        Assert.False(line.Contains("openburnbar_stream_error", System.StringComparison.Ordinal), DescribeFailure(line));
        return line;
    }

    private static string DescribeFailure(string line)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(line);
            JsonElement error = document.RootElement.GetProperty("openburnbar_stream_error");
            return error.GetProperty("kind").GetString() + ": " + error.GetProperty("message").GetString();
        }
        catch
        {
            return line;
        }
    }

    private static ApprovedChatExecutableCatalog CatalogFor(string executable)
    {
        return new ApprovedChatExecutableCatalog(new[]
        {
            new ApprovedChatExecutable("test-helper", executable, ApprovedChatExecutableCatalog.ComputeSha256(executable)),
        });
    }

    private static string CopyExecutableForMutation()
    {
        string source = System.Environment.ProcessPath!;
        string target = Path.Combine(Path.GetTempPath(), "obb-approved-helper-" + System.Guid.NewGuid().ToString("N"));
        File.Copy(source, target);
        return target;
    }

    private static string? ExistingExecutable(params string[] paths)
    {
        foreach (string path in paths)
        {
            if (File.Exists(path))
            {
                return path;
            }
        }

        return null;
    }
}
