using System.Linq;
using OpenBurnBar.App.Settings;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.App.Settings.ViewModels.Agents;
using OpenBurnBar.App.Settings.ViewModels.Daemon;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

public sealed class SettingsTabViewModelCatalogTests
{
    private static readonly SettingsTab[] ExpectedRealTabs =
    {
        SettingsTab.Daemon, SettingsTab.Agents, SettingsTab.ModelProxy, SettingsTab.Alerts,
        SettingsTab.Notifications, SettingsTab.TextExpansion, SettingsTab.ComputerUse, SettingsTab.Pets,
        SettingsTab.Account, SettingsTab.Cloud, SettingsTab.DevicesAndSync,
    };

    [Fact]
    public void RealViewModelTabs_AreTheElevenThisWaveShips()
    {
        Assert.Equal(ExpectedRealTabs.OrderBy(t => t), SettingsTabViewModelCatalog.RealViewModelTabs.OrderBy(t => t));
        Assert.Equal(11, SettingsTabViewModelCatalog.Descriptors.Count);
    }

    [Fact]
    public void Media_StaysAPlaceholder()
    {
        // Media's Mercury core is deferred, so it is intentionally NOT made real here.
        Assert.False(SettingsTabViewModelCatalog.HasRealViewModel(SettingsTab.Media));
        Assert.Null(SettingsTabViewModelCatalog.Descriptor(SettingsTab.Media));
    }

    [Fact]
    public void AlreadyRealTabs_AreNotClaimedByThisCatalog()
    {
        // General / Updates / DataPrivacy already resolve to real WinUI leaf pages; Home is
        // the landing. This portable catalog only covers the newly-real placeholder tabs.
        Assert.False(SettingsTabViewModelCatalog.HasRealViewModel(SettingsTab.General));
        Assert.False(SettingsTabViewModelCatalog.HasRealViewModel(SettingsTab.Updates));
        Assert.False(SettingsTabViewModelCatalog.HasRealViewModel(SettingsTab.DataPrivacy));
        Assert.False(SettingsTabViewModelCatalog.HasRealViewModel(SettingsTab.Home));
    }

    [Fact]
    public void LiveAndDataGatedSplit_IsCorrect()
    {
        var expectedLive = new[]
        {
            SettingsTab.Daemon, SettingsTab.Agents, SettingsTab.ModelProxy, SettingsTab.Alerts,
            SettingsTab.Notifications, SettingsTab.TextExpansion, SettingsTab.ComputerUse, SettingsTab.Pets,
        };
        var expectedGated = new[] { SettingsTab.Account, SettingsTab.Cloud, SettingsTab.DevicesAndSync };

        Assert.Equal(expectedLive.OrderBy(t => t), SettingsTabViewModelCatalog.LiveTabs.OrderBy(t => t));
        Assert.Equal(expectedGated.OrderBy(t => t), SettingsTabViewModelCatalog.DataGatedTabs.OrderBy(t => t));
    }

    [Fact]
    public void EveryRealTab_IsIndexedInTheSearchManifest()
    {
        // Search must be able to reach every tab we just made real — otherwise a user
        // could never navigate to it from the search box.
        foreach (var tab in SettingsTabViewModelCatalog.RealViewModelTabs)
        {
            Assert.Contains(SettingsManifest.All, item => item.Tab == tab);
        }
    }

    [Fact]
    public void EveryRealTab_IsReachableFromSearch()
    {
        // For each newly-real tab, searching one of its own indexed row titles must return
        // a result that lands on that tab — proving search can navigate to it.
        foreach (var tab in SettingsTabViewModelCatalog.RealViewModelTabs)
        {
            var row = SettingsManifest.All.First(item => item.Tab == tab);
            var results = SettingsSearchEngine.Search(row.Title, SettingsManifest.All);
            Assert.Contains(results, r => r.Tab == tab);
        }
    }

    [Fact]
    public void EveryDescriptor_CitesAViewModelAndOracle()
    {
        Assert.All(SettingsTabViewModelCatalog.Descriptors, d =>
        {
            Assert.False(string.IsNullOrWhiteSpace(d.ViewModelName));
            Assert.False(string.IsNullOrWhiteSpace(d.MacOsOracle));
        });
    }

    [Fact]
    public void CreateSample_ProducesTheRightViewModelForEveryRealTab()
    {
        Assert.IsType<DaemonSettingsViewModel>(SettingsTabViewModelCatalog.CreateSample(SettingsTab.Daemon));
        Assert.IsType<AgentsSettingsViewModel>(SettingsTabViewModelCatalog.CreateSample(SettingsTab.Agents));
        Assert.IsType<ModelProxySettingsViewModel>(SettingsTabViewModelCatalog.CreateSample(SettingsTab.ModelProxy));
        Assert.IsType<AlertsSettingsViewModel>(SettingsTabViewModelCatalog.CreateSample(SettingsTab.Alerts));
        Assert.IsType<NotificationsSettingsViewModel>(SettingsTabViewModelCatalog.CreateSample(SettingsTab.Notifications));
        Assert.IsType<TextExpansionSettingsViewModel>(SettingsTabViewModelCatalog.CreateSample(SettingsTab.TextExpansion));
        Assert.IsType<ComputerUseSettingsViewModel>(SettingsTabViewModelCatalog.CreateSample(SettingsTab.ComputerUse));
        Assert.IsType<PetsSettingsViewModel>(SettingsTabViewModelCatalog.CreateSample(SettingsTab.Pets));
        Assert.IsType<AccountSettingsViewModel>(SettingsTabViewModelCatalog.CreateSample(SettingsTab.Account));
        Assert.IsType<CloudSettingsViewModel>(SettingsTabViewModelCatalog.CreateSample(SettingsTab.Cloud));
        Assert.IsType<DevicesAndSyncSettingsViewModel>(SettingsTabViewModelCatalog.CreateSample(SettingsTab.DevicesAndSync));
    }

    [Fact]
    public void CreateSample_ThrowsForAPlaceholderTab()
    {
        Assert.Throws<System.ArgumentOutOfRangeException>(() =>
            SettingsTabViewModelCatalog.CreateSample(SettingsTab.Media));
    }
}
