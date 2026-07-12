using OpenBurnBar.App.Configuration;
using Xunit;

namespace OpenBurnBar.App.Configuration.Tests;

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
