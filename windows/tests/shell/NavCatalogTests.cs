using System.Linq;
using OpenBurnBar.App.Shell;
using Xunit;

namespace OpenBurnBar.App.Shell.Tests;

/// <summary>
/// IA-1 route scaffolding: database + projects keys must appear in the catalog and
/// be resolvable for palette/switcher parity (depth remains deferred disclosure).
/// </summary>
public sealed class NavCatalogTests
{
    [Fact]
    public void All_IncludesMacPrimaryDatabaseAndProjectsKeys()
    {
        Assert.Contains(NavCatalog.All, d => d.Key == "database");
        Assert.Contains(NavCatalog.All, d => d.Key == "projects");
    }

    [Fact]
    public void Find_ResolvesDatabaseAndProjects()
    {
        Assert.Equal("Database", NavCatalog.Find("database")!.Title);
        Assert.Equal("Projects", NavCatalog.Find("projects")!.Title);
        Assert.Contains("deferred", NavCatalog.Find("database")!.Subtitle, System.StringComparison.OrdinalIgnoreCase);
        Assert.Contains("deferred", NavCatalog.Find("projects")!.Subtitle, System.StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void All_KeysAreUnique()
    {
        Assert.Equal(NavCatalog.All.Count, NavCatalog.All.Select(d => d.Key).Distinct().Count());
    }
}
