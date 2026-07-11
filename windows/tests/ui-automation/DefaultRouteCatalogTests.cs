using OpenBurnBar.UiAutomationHarness.Core;
using Xunit;

namespace OpenBurnBar.UiAutomationHarness.Tests;

public sealed class DefaultRouteCatalogTests
{
    [Fact]
    public void All_DefaultRoutesHaveStableAutomationIdsAndXamlFiles()
    {
        string repoRoot = FindRepoRoot();

        foreach (UiHarnessRoute route in DefaultRouteCatalog.All)
        {
            Assert.False(string.IsNullOrWhiteSpace(route.Key));
            Assert.StartsWith("RouteRoot.", route.ExpectedAutomationId, StringComparison.Ordinal);

            string xamlPath = Path.Combine(repoRoot, route.XamlPath.Replace('/', Path.DirectorySeparatorChar));
            Assert.True(File.Exists(xamlPath), $"Missing XAML file for route {route.Key}: {xamlPath}");

            string xaml = File.ReadAllText(xamlPath);
            Assert.Contains($"AutomationProperties.AutomationId=\"{route.ExpectedAutomationId}\"", xaml);
        }
    }

    [Fact]
    public void Select_RejectsUnknownRoute()
    {
        var ex = Assert.Throws<ArgumentException>(() => DefaultRouteCatalog.Select(new[] { "dashboard", "notARealRoute" }));

        Assert.Contains("notARealRoute", ex.Message);
        Assert.Contains("dashboard", ex.Message);
    }

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "windows", "OpenBurnBar.sln"))
                && File.Exists(Path.Combine(dir.FullName, "AGENTS.md")))
            {
                return dir.FullName;
            }

            dir = dir.Parent;
        }

        throw new DirectoryNotFoundException("Could not find repository root from test base directory.");
    }
}
