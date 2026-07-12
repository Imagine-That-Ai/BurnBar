using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using OpenBurnBar.App.Chat;
using OpenBurnBar.App.Configuration;
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
    public void ResolveCommandLine_IgnoresLegacyEnvironmentCommandOverride()
    {
        try
        {
            System.Environment.SetEnvironmentVariable("OPENBURNBAR_CLI_COMMAND", "mycli --json {0}");
            string cmd = CliProcessLineSource.ResolveCommandLine("x");
            Assert.StartsWith("claude", cmd, System.StringComparison.Ordinal);
            Assert.Contains("x", cmd, System.StringComparison.Ordinal);
        }
        finally
        {
            System.Environment.SetEnvironmentVariable("OPENBURNBAR_CLI_COMMAND", null);
        }
    }

    [Fact]
    public void ResolveProcessSpec_TestCommandTemplateInjection_UsedOnlyByCaller()
    {
        ChildProcessSpec spec = CliProcessLineSource.ResolveProcessSpec("x", "mycli --json {0}");

        Assert.Equal("mycli", spec.FileName);
        Assert.Equal(new[] { "--json", "x" }, spec.Arguments.ToArray());
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
    public void ProtectedInventory_ApprovesPersistsRotatesAndRemovesExecutable()
    {
        var secrets = new MemorySecretStore();
        var inventory = new ProtectedChatExecutableInventoryStore(secrets);
        string helper = CopyExecutableForMutation();

        ApprovedChatExecutable approved = inventory.ApproveExecutable(helper, "helper");
        Assert.True(secrets.Contains(AppSecretNames.ChatApprovedExecutables));

        var reopened = new ProtectedChatExecutableInventoryStore(secrets);
        ChatExecutableResolution resolution = reopened.LoadCatalog().Resolve("helper");
        Assert.Equal(helper, resolution.Path);
        Assert.Equal(approved.Sha256, resolution.Sha256);

        File.AppendAllText(helper, "mutation");
        Assert.Equal(ChatExecutableInventoryStatusKind.ExecutableReplaced, reopened.LoadSnapshot().Status.Kind);
        ChatProcessException replaced = Assert.Throws<ChatProcessException>(() => reopened.LoadCatalog().Resolve("helper"));
        Assert.Equal(ChatFailureKind.ExecutableReplaced, replaced.Kind);

        ApprovedChatExecutable rotated = reopened.RotateExecutable("helper", helper);
        Assert.NotEqual(approved.Sha256, rotated.Sha256);
        Assert.Equal(ChatExecutableInventoryStatusKind.Ready, reopened.LoadSnapshot().Status.Kind);

        Assert.True(reopened.RemoveExecutable("helper"));
        Assert.False(secrets.Contains(AppSecretNames.ChatApprovedExecutables));
        Assert.Equal(ChatExecutableInventoryStatusKind.SetupRequired, reopened.LoadSnapshot().Status.Kind);
    }

    [Fact]
    public void ProtectedInventory_DeniesMissingInventoryAndMissingExecutable()
    {
        var secrets = new MemorySecretStore();
        var inventory = new ProtectedChatExecutableInventoryStore(secrets);

        ChatProcessException denied = Assert.Throws<ChatProcessException>(() =>
            inventory.LoadCatalog().Resolve(System.Environment.ProcessPath!));
        Assert.Equal(ChatFailureKind.ExecutableDenied, denied.Kind);

        string helper = CopyExecutableForMutation();
        inventory.ApproveExecutable(helper, "helper");
        File.Delete(helper);

        Assert.Equal(ChatExecutableInventoryStatusKind.ExecutableUnavailable, inventory.LoadSnapshot().Status.Kind);
        ChatProcessException unavailable = Assert.Throws<ChatProcessException>(() =>
            inventory.LoadCatalog().Resolve("helper"));
        Assert.Equal(ChatFailureKind.ExecutableUnavailable, unavailable.Kind);
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
    public async System.Threading.Tasks.Task ReadLinesAsync_StillWatchesStderrAfterStdoutCloses()
    {
        string dotnet = ResolveDotnetHost();
        string helper = Path.Combine(System.AppContext.BaseDirectory, "OpenBurnBar.Chat.ProcessTestHelper.dll");
        Assert.True(File.Exists(helper), $"Process helper not found: {helper}");

        async System.Threading.Tasks.Task<System.Collections.Generic.List<string>> ReadAsync()
        {
            var output = new System.Collections.Generic.List<string>();
            await foreach (string line in CliProcessLineSource.ReadLinesAsync(
                new ChildProcessSpec(dotnet, new[] { helper, "close-stdout-overflow-stderr" }),
                CatalogFor(dotnet),
                new ChatProcessLimits(256, 128),
                System.Threading.CancellationToken.None))
            {
                output.Add(line);
            }

            return output;
        }

        System.Collections.Generic.List<string> lines = await ReadAsync().WaitAsync(System.TimeSpan.FromSeconds(5));
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

    private static string ResolveDotnetHost()
    {
        string? configured = System.Environment.GetEnvironmentVariable("DOTNET_HOST_PATH");
        if (!string.IsNullOrWhiteSpace(configured) && File.Exists(configured))
        {
            return configured;
        }

        string executable = System.OperatingSystem.IsWindows() ? "dotnet.exe" : "dotnet";
        foreach (string directory in (System.Environment.GetEnvironmentVariable("PATH") ?? string.Empty)
                     .Split(Path.PathSeparator, System.StringSplitOptions.RemoveEmptyEntries))
        {
            string candidate = Path.Combine(directory, executable);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new FileNotFoundException("Unable to locate the dotnet host for the process helper.");
    }

    private sealed class MemorySecretStore : IAppSecretStore
    {
        private readonly System.Collections.Generic.Dictionary<string, string> _secrets = new();

        public string BackendName => "test-memory";

        public SecretWriteReceipt Write(string secretName, string value)
        {
            _secrets[secretName] = value;
            return new SecretWriteReceipt(secretName, BackendName, "memory://" + secretName, System.DateTimeOffset.UtcNow);
        }

        public string? Read(string secretName) =>
            _secrets.TryGetValue(secretName, out string? value) ? value : null;

        public bool Contains(string secretName) => _secrets.ContainsKey(secretName);

        public void Delete(string secretName) => _secrets.Remove(secretName);
    }
}
