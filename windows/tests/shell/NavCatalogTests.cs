using System.Linq;
using OpenBurnBar.App.Shell;
using Xunit;

namespace OpenBurnBar.App.Shell.Tests;

/// <summary>
/// IA-1 route scaffolding: database + projects keys must appear in the catalog and
/// map to deferred SurfaceStubPage logical registration (depth remains deferred).
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

    [Fact]
    public void All_HasFourteenKeys_AfterIa1()
    {
        Assert.Equal(14, NavCatalog.All.Count);
        Assert.Single(NavCatalog.Auxiliary);
        Assert.Equal("elderWand", NavCatalog.Auxiliary[0].Key);
    }

    [Theory]
    [InlineData("database")]
    [InlineData("projects")]
    public void Ia1Keys_ResolveToDeferredStub_NotProductPages(string key)
    {
        Assert.True(SurfaceRouteMap.IsIa1DeferredDisclosure(key));
        Assert.Equal(SurfaceRouteMap.DeferredStubPage, SurfaceRouteMap.LogicalPageType(key));
        Assert.NotEqual("InsightsPage", SurfaceRouteMap.LogicalPageType(key));
        Assert.NotEqual("DashboardPage", SurfaceRouteMap.LogicalPageType(key));
        Assert.Contains(key, SurfaceRouteMap.Ia1DeferredDisclosureKeys);
    }

    [Fact]
    public void EveryNavCatalogKey_HasIntentionalLogicalRegistration()
    {
        foreach (NavDestination destination in NavCatalog.All.Concat(NavCatalog.Auxiliary))
        {
            string logical = SurfaceRouteMap.LogicalPageType(destination.Key);
            Assert.False(string.IsNullOrWhiteSpace(logical), destination.Key);
            if (SurfaceRouteMap.IsIa1DeferredDisclosure(destination.Key))
            {
                Assert.Equal(SurfaceRouteMap.DeferredStubPage, logical);
            }
            else
            {
                Assert.NotEqual(SurfaceRouteMap.DeferredStubPage, logical);
            }
        }
    }
}
