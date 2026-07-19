using System;
using System.IO;
using OpenBurnBar.Windows.Ci;
using Xunit;

namespace OpenBurnBar.Windows.Ci.Tests;

public sealed class WindowsFullGateCompositionTests
{
    [Fact]
    public void Validate_RepoRoot_PassesForThisCheckout()
    {
        string root = FindRepoRoot();
        WindowsFullGateValidation result = WindowsFullGateComposition.Validate(root);
        Assert.True(result.IsValid, result.Error);
        Assert.NotNull(result.WorkflowPath);
        Assert.True(File.Exists(result.WorkflowPath));
    }

    [Fact]
    public void Validate_MissingRoot_FailsClosed()
    {
        WindowsFullGateValidation result = WindowsFullGateComposition.Validate(
            Path.Combine(Path.GetTempPath(), "obb-no-such-root-" + Path.GetRandomFileName()));
        Assert.False(result.IsValid);
        Assert.Equal("repo_root_missing", result.Error);
    }

    [Fact]
    public void RuntimeSafetyInterlock_StartsBeforePrivilegedProcessesAndUsesVersionedBroker()
    {
        string root = FindRepoRoot();
        string app = File.ReadAllText(Path.Combine(root, "windows", "app", "OpenBurnBar.App", "App.xaml.cs"));
        int safetyStart = app.IndexOf("StartWindowsRuntimeSafetyConfig();", StringComparison.Ordinal);
        int watchdogStart = app.IndexOf("StartComputerUseWatchdog();", StringComparison.Ordinal);
        int brokerStart = app.IndexOf("StartPrivilegedInputBroker();", StringComparison.Ordinal);

        Assert.True(safetyStart >= 0, "Windows runtime safety monitor is not started.");
        Assert.True(safetyStart < watchdogStart, "Runtime safety must close before the watchdog starts.");
        Assert.True(safetyStart < brokerStart, "Runtime safety must close before the input broker starts.");

        string endpoint = File.ReadAllText(Path.Combine(
            root,
            "windows",
            "pal",
            "ipc-windows",
            "PrivilegedInputBrokerEndpoint.cs"));
        Assert.Contains("OpenBurnBar.PrivilegedInputBroker.v2.", endpoint, StringComparison.Ordinal);
    }

    [Fact]
    public void RuntimeSafetyCallable_RequiresAuthAndAppCheckAndIsExported()
    {
        string root = FindRepoRoot();
        string callable = File.ReadAllText(Path.Combine(
            root,
            "functions",
            "src",
            "callables",
            "windowsRuntimeSafetyConfig.ts"));
        string index = File.ReadAllText(Path.Combine(root, "functions", "src", "index.ts"));

        Assert.Contains("enforceAuthAndAppCheck(request, uid)", callable, StringComparison.Ordinal);
        Assert.Contains("enforceAppCheck: getConfig().enforceAppCheck", callable, StringComparison.Ordinal);
        Assert.Contains("getWindowsRuntimeSafetyConfig", index, StringComparison.Ordinal);
    }

    private static string FindRepoRoot()
    {
        string dir = Directory.GetCurrentDirectory();
        while (!string.IsNullOrEmpty(dir))
        {
            if (File.Exists(Path.Combine(dir, ".github", "workflows", "pr-windows-full.yml")))
            {
                return dir;
            }

            string? parent = Directory.GetParent(dir)?.FullName;
            if (parent is null || parent == dir)
            {
                break;
            }

            dir = parent;
        }

        // Fallback: walk up from test assembly base
        dir = AppContext.BaseDirectory;
        for (int i = 0; i < 12; i++)
        {
            if (File.Exists(Path.Combine(dir, ".github", "workflows", "pr-windows-full.yml")))
            {
                return dir;
            }

            dir = Path.GetFullPath(Path.Combine(dir, ".."));
        }

        throw new DirectoryNotFoundException("Could not locate repo root with pr-windows-full.yml");
    }
}
