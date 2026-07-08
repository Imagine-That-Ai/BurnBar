using System.Linq;
using OpenBurnBar.App.Settings;
using Xunit;

namespace OpenBurnBar.App.Settings.Tests;

/// <summary>
/// Coverage for the ported results-view breadcrumb helpers
/// (AgentLens/Views/Settings/Search/SettingsSearchResultsView.swift).
/// </summary>
public sealed class SettingsRouteDisplayTests
{
    [Fact]
    public void PageDisplayName_RootsAreEmpty_DrillsAreNamed()
    {
        Assert.Equal(string.Empty, SettingsRouteDisplay.PageDisplayName(SettingsPageRoute.AccountRoot));
        Assert.Equal("Appearance", SettingsRouteDisplay.PageDisplayName(SettingsPageRoute.Appearance));
        Assert.Equal("HTTP Gateway", SettingsRouteDisplay.PageDisplayName(SettingsPageRoute.HttpGateway));
        Assert.Equal("Model Proxy", SettingsRouteDisplay.PageDisplayName(SettingsPageRoute.ModelProxyRoot));
        Assert.Equal("Pi Agent Instances", SettingsRouteDisplay.PageDisplayName(SettingsPageRoute.HermesPiAgent));
    }

    [Fact]
    public void Breadcrumb_UsesTabTitleForRootsAndTabArrowPageForDrills()
    {
        var glass = SettingsManifest.All.Single(i => i.Id == "general.appearance.glassTransparency");
        Assert.Equal("General › Appearance", SettingsRouteDisplay.Breadcrumb(glass));

        var cloud = SettingsManifest.All.Single(i => i.Id == "cloud.overview");
        Assert.Equal("Cloud", SettingsRouteDisplay.Breadcrumb(cloud)); // root route → tab title only
    }

    [Fact]
    public void Breadcrumb_IsNonEmptyForEveryManifestRow()
    {
        Assert.All(SettingsManifest.All, item =>
            Assert.False(string.IsNullOrWhiteSpace(SettingsRouteDisplay.Breadcrumb(item))));
    }
}
