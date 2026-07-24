using System.Linq;
using OpenBurnBar.App.Shell;
using Xunit;

namespace OpenBurnBar.App.Shell.Tests;

/// <summary>
/// Route scaffolding: database + projects are product pages (IA-2/IA-4), not deferred stubs.
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
    }

    [Fact]
    public void All_KeysAreUnique()
    {
        Assert.Equal(NavCatalog.All.Count, NavCatalog.All.Select(d => d.Key).Distinct().Count());
    }

    [Fact]
    public void All_HasFifteenKeys_AfterCalendar()
    {
        Assert.Equal(15, NavCatalog.All.Count);
        Assert.Single(NavCatalog.Auxiliary);
        Assert.Equal("elderWand", NavCatalog.Auxiliary[0].Key);
    }

    [Theory]
    [InlineData("database", "DatabasePage")]
    [InlineData("projects", "ProjectsPage")]
    [InlineData("calendar", "CalendarPage")]
    public void ProductRoutes_ResolveToProductPages_NotStub(string key, string logical)
    {
        Assert.False(SurfaceRouteMap.IsIa1DeferredDisclosure(key));
        Assert.Equal(logical, SurfaceRouteMap.LogicalPageType(key));
        Assert.NotEqual(SurfaceRouteMap.DeferredStubPage, SurfaceRouteMap.LogicalPageType(key));
        Assert.Contains(logical, SurfaceRouteMap.ProductLogicalPageNames);
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
                Assert.Contains(logical, SurfaceRouteMap.ProductLogicalPageNames);
            }
        }
    }

    [Fact]
    public void ProductLogicalPageNames_IncludesDatabaseAndProjects()
    {
        Assert.Contains("DatabasePage", SurfaceRouteMap.ProductLogicalPageNames);
        Assert.Contains("ProjectsPage", SurfaceRouteMap.ProductLogicalPageNames);
        Assert.DoesNotContain(SurfaceRouteMap.DeferredStubPage, SurfaceRouteMap.ProductLogicalPageNames);
    }

    [Fact]
    public void All_IncludesCalendar_AfterChat()
    {
        Assert.Contains(NavCatalog.All, d => d.Key == "calendar" && d.Title == "Calendar");
        Assert.Equal("Calendar", NavCatalog.Find("calendar")!.Title);
        Assert.Contains("CalendarPage", SurfaceRouteMap.ProductLogicalPageNames);
    }

    [Fact]
    public void AssertWinUiBindingsCoverProductLogicalNames_FailsWhenMissing()
    {
        var incomplete = new[] { "BudgetPage" };
        var ex = Assert.Throws<System.InvalidOperationException>(
            () => SurfaceRouteMap.AssertWinUiBindingsCoverProductLogicalNames(incomplete));
        Assert.Contains("missing WinUI bindings", ex.Message, System.StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void AssertWinUiBindingsCoverProductLogicalNames_PassesWhenComplete()
    {
        SurfaceRouteMap.AssertWinUiBindingsCoverProductLogicalNames(SurfaceRouteMap.ProductLogicalPageNames);
    }
}
