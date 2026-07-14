using System.Diagnostics;
using OpenBurnBar.App.Configuration;
using Xunit;

namespace OpenBurnBar.App.Configuration.Tests;

public sealed class ChildProcessLaunchPolicyTests
{
    [Fact]
    public void Reviewed_inventory_covers_current_product_launch_sites()
    {
        string[] ids = ChildProcessLaunchPolicy.ReviewedProductLaunches
            .Select(entry => entry.Id)
            .OrderBy(id => id, StringComparer.Ordinal)
            .ToArray();

        Assert.Equal(new[]
        {
            "chat.conpty-cli",
            "chat.direct-cli",
            "cloud.oauth-browser",
            "computer-use.playwright-bridge",
            "data.swift-engine-interim",
            "gateway.provider-cli",
            "project-code.language-server",
            "project-code.static-parser",
            "quota.claude-statusline-forwarder",
            "switcher.conpty-cli",
        }, ids);
    }

    [Fact]
    public void Windows_browser_activation_uses_os_activation_without_shell_or_secret_environment()
    {
        var source = new[]
        {
            new KeyValuePair<string, string?>("LOCALAPPDATA", @"C:\Users\a\AppData\Local"),
            new KeyValuePair<string, string?>("PATH", @"C:\secret-path"),
            new KeyValuePair<string, string?>("OPENAI_API_KEY", "forbidden"),
            new KeyValuePair<string, string?>("OPENBURNBAR_SQLCIPHER_PATH", @"C:\secret.sqlite"),
            new KeyValuePair<string, string?>("OPENBURNBAR_SQLCIPHER_PASSPHRASE", "forbidden"),
            new KeyValuePair<string, string?>("WINDOWS_UPDATE_SIGNING_KEY", "forbidden"),
            new KeyValuePair<string, string?>("DIAGNOSTIC_CANARY_SECRET", "forbidden"),
        };

        ProcessStartInfo startInfo = ChildProcessLaunchPolicy.CreateDefaultBrowserActivation(
            new Uri("https://accounts.example.test/auth?state=abc"),
            ChildProcessHost.Windows,
            @"C:\Windows",
            source);

        Assert.False(startInfo.UseShellExecute);
        Assert.Contains("explorer.exe", startInfo.FileName, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(new[] { "https://accounts.example.test/auth?state=abc" }, startInfo.ArgumentList.ToArray());
        Assert.Equal(@"C:\Users\a\AppData\Local", startInfo.Environment["LOCALAPPDATA"]);
        Assert.False(startInfo.Environment.ContainsKey("PATH"));
        Assert.False(startInfo.Environment.ContainsKey("OPENAI_API_KEY"));
        Assert.False(startInfo.Environment.ContainsKey("OPENBURNBAR_SQLCIPHER_PATH"));
        Assert.False(startInfo.Environment.ContainsKey("OPENBURNBAR_SQLCIPHER_PASSPHRASE"));
        Assert.False(startInfo.Environment.ContainsKey("WINDOWS_UPDATE_SIGNING_KEY"));
        Assert.False(startInfo.Environment.ContainsKey("DIAGNOSTIC_CANARY_SECRET"));
    }

    [Fact]
    public void Direct_process_profiles_use_argument_vector_and_scrubbed_environment()
    {
        var source = new[]
        {
            new KeyValuePair<string, string?>("PATH", "/usr/bin"),
            new KeyValuePair<string, string?>("OPENAI_API_KEY", "forbidden"),
            new KeyValuePair<string, string?>("OPENBURNBAR_SQLCIPHER_PASSPHRASE", "forbidden"),
        };

        ProcessStartInfo startInfo = ChildProcessLaunchPolicy.CreateStartInfo(
            ChildProcessProfile.Chat,
            "/usr/bin/printf",
            new[] { "%s", "hello & goodbye" },
            redirectStandardOutput: true,
            sourceEnvironment: source);

        Assert.False(startInfo.UseShellExecute);
        Assert.Empty(startInfo.Arguments);
        Assert.Equal(new[] { "%s", "hello & goodbye" }, startInfo.ArgumentList.ToArray());
        Assert.True(startInfo.RedirectStandardOutput);
        Assert.Equal("/usr/bin", startInfo.Environment["PATH"]);
        Assert.False(startInfo.Environment.ContainsKey("OPENAI_API_KEY"));
        Assert.False(startInfo.Environment.ContainsKey("OPENBURNBAR_SQLCIPHER_PASSPHRASE"));
    }

    [Fact]
    public void Generated_statusline_wrapper_uses_policy_allowlist_without_secret_names()
    {
        string literal = ChildProcessLaunchPolicy.PowerShellEnvironmentNameArrayLiteral(ChildProcessProfile.Chat);

        Assert.Contains("'PATH'", literal, StringComparison.Ordinal);
        Assert.DoesNotContain("TOKEN", literal, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("SECRET", literal, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("SQLCIPHER", literal, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("SIGNING", literal, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void GatewayMayReceiveOnlyExplicitProviderCredentials()
    {
        var source = new[]
        {
            new KeyValuePair<string, string?>("PATH", "/usr/bin"),
            new KeyValuePair<string, string?>("OPENAI_API_KEY", "ambient-openai"),
            new KeyValuePair<string, string?>("FACTORY_API_KEY", "ambient-factory"),
        };
        var required = new[]
        {
            new KeyValuePair<string, string?>("OPENAI_API_KEY", "explicit-openai"),
            new KeyValuePair<string, string?>("FACTORY_API_KEY", "explicit-factory"),
            new KeyValuePair<string, string?>("OPENBURNBAR_FACTORY_STRICT_STANDARD", "1"),
        };

        IReadOnlyDictionary<string, string> environment = ChildProcessEnvironment.CreateAllowlisted(
            ChildProcessProfile.Gateway,
            source,
            required,
            ChildProcessHost.Linux);

        Assert.Equal("/usr/bin", environment["PATH"]);
        Assert.Equal("explicit-openai", environment["OPENAI_API_KEY"]);
        Assert.Equal("explicit-factory", environment["FACTORY_API_KEY"]);
        Assert.Equal("1", environment["OPENBURNBAR_FACTORY_STRICT_STANDARD"]);
    }

    [Fact]
    public void AmbientGatewayCredentialsRemainScrubbed()
    {
        var source = new[]
        {
            new KeyValuePair<string, string?>("PATH", "/usr/bin"),
            new KeyValuePair<string, string?>("OPENAI_API_KEY", "ambient-openai"),
            new KeyValuePair<string, string?>("FACTORY_API_KEY", "ambient-factory"),
        };

        IReadOnlyDictionary<string, string> environment = ChildProcessEnvironment.CreateAllowlisted(
            ChildProcessProfile.Gateway,
            source,
            host: ChildProcessHost.Linux);

        Assert.Equal("/usr/bin", environment["PATH"]);
        Assert.False(environment.ContainsKey("OPENAI_API_KEY"));
        Assert.False(environment.ContainsKey("FACTORY_API_KEY"));
    }

    [Fact]
    public void SwitcherProfileAllowsOnlyReviewedConfigurationEnvironment()
    {
        var source = new[]
        {
            new KeyValuePair<string, string?>("PATH", @"C:\Windows\System32"),
            new KeyValuePair<string, string?>("OPENAI_API_KEY", "ambient-secret"),
        };
        var required = new[]
        {
            new KeyValuePair<string, string?>("CODEX_HOME", @"C:\profiles\work"),
            new KeyValuePair<string, string?>("TERM", "xterm-256color"),
        };

        IReadOnlyDictionary<string, string> environment = ChildProcessEnvironment.CreateAllowlisted(
            ChildProcessProfile.Switcher,
            source,
            required,
            ChildProcessHost.Windows);

        Assert.Equal(@"C:\Windows\System32", environment["PATH"]);
        Assert.Equal(@"C:\profiles\work", environment["CODEX_HOME"]);
        Assert.Equal("xterm-256color", environment["TERM"]);
        Assert.False(environment.ContainsKey("OPENAI_API_KEY"));
    }

    [Theory]
    [InlineData(ChildProcessProfile.Chat, "OPENAI_API_KEY")]
    [InlineData(ChildProcessProfile.Chat, "FACTORY_API_KEY")]
    [InlineData(ChildProcessProfile.Gateway, "PROVIDER_TOKEN")]
    [InlineData(ChildProcessProfile.Gateway, "OPENAI_REFRESH_TOKEN")]
    public void RequiredSecretsOutsideNarrowGatewayAllowanceAreRejected(
        ChildProcessProfile profile,
        string name)
    {
        var required = new[] { new KeyValuePair<string, string?>(name, "secret") };

        Assert.Throws<SecretStoreException>(() => ChildProcessEnvironment.CreateAllowlisted(
            profile,
            Array.Empty<KeyValuePair<string, string?>>(),
            required,
            ChildProcessHost.Linux));
    }

    [Fact]
    public void Product_source_launch_primitives_are_policy_owned()
    {
        string appRoot = FindAppRoot();
        var expectedOwners = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["OpenBurnBar.App.Configuration/ChildProcessEnvironment.cs"] = "ChildProcessEnvironment",
            ["OpenBurnBar.App.Configuration/ChildProcessLaunchPolicy.cs"] = "ReviewedProductLaunches",
            ["OpenBurnBar.App.CloudSync/IBrowserLauncher.cs"] = "ChildProcessLaunchPolicy.StartDefaultBrowser",
            ["OpenBurnBar.App.Quota.Acquisition/ClaudeStatuslineHookInstaller.cs"] = "ChildProcessLaunchPolicy.PowerShellEnvironmentNameArrayLiteral",
            ["OpenBurnBar.App/Chat/ChatProcessRunner.cs"] = "ChildProcessLaunchPolicy.CreateStartInfo",
            ["OpenBurnBar.App/Cli/ConPtyCliStream.cs"] = "ChildProcessLaunchPolicy.CreateEnvironment",
            ["OpenBurnBar.App/Data/SwiftEngineInterim.cs"] = "ChildProcessLaunchPolicy.CreateStartInfo",
            ["OpenBurnBar.App/Gateway/WindowsProviderCliProcessRunner.cs"] = "ChildProcessLaunchPolicy.CreateStartInfo",
        };
        string[] needles =
        {
            "new ProcessStartInfo",
            "Process.Start(",
            "new Process { StartInfo",
            "ConPtySession.Spawn(",
            "System.Diagnostics.ProcessStartInfo",
            "[System.Diagnostics.Process]::Start",
        };

        var offenders = new List<string>();
        foreach (string file in Directory.EnumerateFiles(appRoot, "*.cs", SearchOption.AllDirectories))
        {
            string normalized = file.Replace('\\', '/');
            if (normalized.Contains("/bin/", StringComparison.Ordinal) || normalized.Contains("/obj/", StringComparison.Ordinal))
            {
                continue;
            }

            string text = File.ReadAllText(file);
            if (!needles.Any(needle => text.Contains(needle, StringComparison.Ordinal)))
            {
                continue;
            }

            string relative = Path.GetRelativePath(appRoot, file).Replace('\\', '/');
            if (!expectedOwners.TryGetValue(relative, out string? ownerToken) || !text.Contains(ownerToken, StringComparison.Ordinal))
            {
                offenders.Add(relative);
            }
        }

        Assert.Empty(offenders);
    }

    private static string FindAppRoot()
    {
        string? current = AppContext.BaseDirectory;
        for (int i = 0; i < 12 && current is not null; i++)
        {
            string candidate = Path.Combine(current, "windows", "app");
            if (Directory.Exists(candidate))
            {
                return candidate;
            }

            current = Directory.GetParent(current)?.FullName;
        }

        throw new DirectoryNotFoundException("Could not locate windows/app from " + AppContext.BaseDirectory);
    }
}
