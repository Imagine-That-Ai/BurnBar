using OpenBurnBar.App.Configuration;
using Xunit;

namespace OpenBurnBar.App.Configuration.Tests;

/// <summary>
/// Serializes test classes that mutate the process-global LOCALAPPDATA
/// environment variable. xUnit runs distinct collections in parallel, so
/// without this, one class restoring LOCALAPPDATA to null (its CI default on
/// Linux) races another class between its set and its assertion.
/// </summary>
[CollectionDefinition(Name)]
public sealed class LocalAppDataEnvironmentCollection
{
    public const string Name = "LOCALAPPDATA environment";
}

// Shares a collection with AppConfigurationTests: both mutate the
// process-global LOCALAPPDATA variable, so they must never run in parallel
// with each other.
[Collection(LocalAppDataEnvironmentCollection.Name)]
public sealed class RuntimePathsTests
{
    [Fact]
    public void AppDataDirectory_UsesAutomationProfileRoot_WhenPresent()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-runtime-paths-" + Guid.NewGuid().ToString("N"));
        string? previous = Environment.GetEnvironmentVariable(RuntimePaths.AutomationProfileRootEnvironmentVariable);
        Environment.SetEnvironmentVariable(RuntimePaths.AutomationProfileRootEnvironmentVariable, root);

        try
        {
            Assert.Equal(Path.GetFullPath(root), RuntimePaths.AppDataDirectory());
            Assert.Equal(Path.Combine(Path.GetFullPath(root), "app_config.json"), RuntimePaths.AppDataFile("app_config.json"));
            Assert.Equal(Path.Combine(Path.GetFullPath(root), "logs"), RuntimePaths.AppDataSubdirectory("logs"));
        }
        finally
        {
            Environment.SetEnvironmentVariable(RuntimePaths.AutomationProfileRootEnvironmentVariable, previous);
        }
    }

    [Fact]
    public void AppDataDirectory_FallsBackToLocalAppDataOpenBurnBar()
    {
        string localAppData = Path.Combine(Path.GetTempPath(), "obb-local-app-data-" + Guid.NewGuid().ToString("N"));
        string? previousAutomation = Environment.GetEnvironmentVariable(RuntimePaths.AutomationProfileRootEnvironmentVariable);
        string? previousLocal = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        Environment.SetEnvironmentVariable(RuntimePaths.AutomationProfileRootEnvironmentVariable, null);
        Environment.SetEnvironmentVariable("LOCALAPPDATA", localAppData);

        try
        {
            Assert.Equal(Path.Combine(localAppData, "OpenBurnBar"), RuntimePaths.AppDataDirectory());
        }
        finally
        {
            Environment.SetEnvironmentVariable(RuntimePaths.AutomationProfileRootEnvironmentVariable, previousAutomation);
            Environment.SetEnvironmentVariable("LOCALAPPDATA", previousLocal);
        }
    }
}
