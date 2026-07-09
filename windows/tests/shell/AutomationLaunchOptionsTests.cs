using System;
using System.IO;
using System.Text.Json;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Shell;
using Xunit;

namespace OpenBurnBar.App.Shell.Tests;

public sealed class AutomationLaunchOptionsTests : IDisposable
{
    private readonly string _dir;
    private readonly string? _previousProfileRoot;

    public AutomationLaunchOptionsTests()
    {
        _previousProfileRoot = Environment.GetEnvironmentVariable(RuntimePaths.AutomationProfileRootEnvironmentVariable);
        _dir = Path.Combine(Path.GetTempPath(), "obb-automation-launch-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_dir);
    }

    public void Dispose()
    {
        Environment.SetEnvironmentVariable(RuntimePaths.AutomationProfileRootEnvironmentVariable, _previousProfileRoot);

        try
        {
            if (Directory.Exists(_dir))
            {
                Directory.Delete(_dir, recursive: true);
            }
        }
        catch (IOException)
        {
            // Best-effort temp cleanup; never fail a test on teardown.
        }
    }

    [Fact]
    public void Parse_ReturnsNull_WhenNoAutomationSwitchIsPresent()
    {
        Assert.Null(AutomationLaunchOptions.Parse("--route-smoke dashboard"));
    }

    [Fact]
    public void Parse_HandlesQuotedPathsAndMainWindowFlag()
    {
        string profile = Path.Combine(_dir, "profile root");
        string output = Path.Combine(_dir, "out root");

        var options = AutomationLaunchOptions.Parse(
            $"--automation-main-window --automation-profile \"{profile}\" --automation-out \"{output}\"");

        Assert.NotNull(options);
        Assert.True(options!.MainWindow);
        Assert.Equal(Path.GetFullPath(profile), options.ProfileRoot);
        Assert.Equal(Path.GetFullPath(output), options.OutputDirectory);
    }

    [Fact]
    public void ApplyEnvironment_SetsAutomationProfileRoot()
    {
        string profile = Path.Combine(_dir, "profile");
        var options = AutomationLaunchOptions.Parse($"--automation-profile \"{profile}\"");

        options!.ApplyEnvironment();

        Assert.Equal(Path.GetFullPath(profile), Environment.GetEnvironmentVariable(RuntimePaths.AutomationProfileRootEnvironmentVariable));
    }

    [Fact]
    public void WriteLaunchMarker_WritesRedirectionProof()
    {
        string profile = Path.Combine(_dir, "profile");
        string output = Path.Combine(_dir, "out");
        var options = AutomationLaunchOptions.Parse($"--automation-profile \"{profile}\" --automation-out \"{output}\"");

        options!.ApplyEnvironment();
        options.WriteLaunchMarker();

        string markerPath = Path.Combine(output, "automation-launch.json");
        Assert.True(File.Exists(markerPath));

        using JsonDocument marker = JsonDocument.Parse(File.ReadAllText(markerPath));
        Assert.Equal(Environment.ProcessId, marker.RootElement.GetProperty("pid").GetInt32());
        Assert.Equal(Path.GetFullPath(profile), marker.RootElement.GetProperty("profileRoot").GetString());
        Assert.Equal(Path.GetFullPath(profile), marker.RootElement.GetProperty("appDataDirectory").GetString());
        Assert.False(string.IsNullOrWhiteSpace(marker.RootElement.GetProperty("generatedAtUtc").GetString()));
    }
}
