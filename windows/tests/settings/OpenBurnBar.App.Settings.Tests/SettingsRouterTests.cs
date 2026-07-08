using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Settings;
using Xunit;

namespace OpenBurnBar.App.Settings.Tests;

/// <summary>
/// Real coverage for the ported router
/// (AgentLens/Views/Settings/Search/SettingsRouter.swift): the pure route→path map,
/// jump-to-anchor navigation state, consume/reset, and the deep-link resolver.
/// </summary>
public sealed class SettingsRouterTests
{
    // ── PathForRoute (pure) ───────────────────────────────────────────────────

    [Theory]
    [InlineData(SettingsPageRoute.HomeRoot)]
    [InlineData(SettingsPageRoute.GeneralRoot)]
    [InlineData(SettingsPageRoute.DaemonRoot)]
    [InlineData(SettingsPageRoute.UpdatesRoot)]
    [InlineData(SettingsPageRoute.AccountRoot)]
    [InlineData(SettingsPageRoute.CloudRoot)]
    [InlineData(SettingsPageRoute.AgentsRoot)]
    [InlineData(SettingsPageRoute.ModelProxyRoot)]
    [InlineData(SettingsPageRoute.PetsRoot)]
    [InlineData(SettingsPageRoute.ConnectionsRoot)] // legacy root → agents landing
    [InlineData(SettingsPageRoute.HermesRoot)]      // legacy root → agents landing
    public void RootRoutes_ProduceEmptyPath(SettingsPageRoute route)
    {
        Assert.Empty(SettingsRouter.PathForRoute(route));
    }

    [Theory]
    [InlineData(SettingsPageRoute.Appearance)]
    [InlineData(SettingsPageRoute.HttpGateway)]
    [InlineData(SettingsPageRoute.AgentsAdvanced)]
    [InlineData(SettingsPageRoute.AnalysisConfigurator)]
    [InlineData(SettingsPageRoute.FusionImpact)]
    public void DrillRoutes_ProduceSingleSelfPath(SettingsPageRoute route)
    {
        Assert.Equal(new[] { route }, SettingsRouter.PathForRoute(route));
    }

    [Fact]
    public void LegacyHermesDetailRoutes_ForwardToAgentsDetail()
    {
        Assert.Equal(new[] { SettingsPageRoute.AgentsAdvanced },
            SettingsRouter.PathForRoute(SettingsPageRoute.HermesChatEngines));
        Assert.Equal(new[] { SettingsPageRoute.AgentsRuntimes },
            SettingsRouter.PathForRoute(SettingsPageRoute.HermesGateway));
        Assert.Equal(new[] { SettingsPageRoute.AgentsRuntimes },
            SettingsRouter.PathForRoute(SettingsPageRoute.HermesPiRelay));
    }

    // ── Navigate: jump-to-anchor state ────────────────────────────────────────

    [Fact]
    public void Navigate_PrimesTabAnchorFocusHighlightAndPath()
    {
        var router = new SettingsRouter { Query = "gateway" };
        var item = SettingsManifest.All.Single(i => i.Id == "daemon.gateway.host");

        router.Navigate(item);

        Assert.Equal(SettingsTab.Daemon, router.SelectedTab);
        Assert.Equal(SettingsAnchor.GatewayHost, router.PendingAnchor);
        Assert.Equal(SettingsAnchor.GatewayHost, router.HighlightedAnchor);
        Assert.Equal(SettingsFocus.GatewayHost, router.PendingFocus);
        Assert.Equal(new[] { SettingsPageRoute.HttpGateway }, router.Path);
        Assert.Equal(string.Empty, router.Query);     // query cleared so the detail shows
        Assert.False(router.IsSearching);
    }

    [Fact]
    public void EndToEnd_SearchThenNavigate_LandsOnTheExactAnchor()
    {
        // The load-bearing "search a manifest, assert jump-to-anchor" flow.
        var results = SettingsSearchEngine.Search("liquid glass transparency", SettingsManifest.All);
        Assert.NotEmpty(results);

        var top = results[0];
        Assert.Equal("general.appearance.glassTransparency", top.Id);
        Assert.Equal(SettingsAnchor.AppearanceGlassTransparency, top.AnchorId);
        Assert.Equal(SettingsTab.General, top.Tab);
        Assert.Equal(SettingsPageRoute.Appearance, top.PageRoute);

        var router = new SettingsRouter();
        router.Navigate(top);

        Assert.Equal(SettingsTab.General, router.SelectedTab);
        Assert.Equal(SettingsAnchor.AppearanceGlassTransparency, router.PendingAnchor);
        Assert.Equal(new[] { SettingsPageRoute.Appearance }, router.Path);
    }

    [Fact]
    public void Navigate_NoFocusId_LeavesPendingFocusNull()
    {
        var router = new SettingsRouter();
        var item = SettingsManifest.All.Single(i => i.Id == "general.appearance.theme");
        router.Navigate(item);
        Assert.Null(router.PendingFocus);
        Assert.Equal(SettingsAnchor.AppearanceTheme, router.PendingAnchor);
    }

    // ── Consume / reset ───────────────────────────────────────────────────────

    [Fact]
    public void ConsumePendingAnchor_ClearsOnlyTheMatchingAnchor()
    {
        var router = new SettingsRouter();
        router.Navigate(SettingsManifest.All.Single(i => i.Id == "daemon.gateway.port"));

        router.ConsumePendingAnchor("some.other.anchor");
        Assert.Equal(SettingsAnchor.GatewayPort, router.PendingAnchor); // unchanged

        router.ConsumePendingAnchor(SettingsAnchor.GatewayPort);
        Assert.Null(router.PendingAnchor);
    }

    [Fact]
    public void ConsumePendingFocus_ClearsOnlyTheMatchingFocus()
    {
        var router = new SettingsRouter();
        router.Navigate(SettingsManifest.All.Single(i => i.Id == "daemon.gateway.port"));

        router.ConsumePendingFocus("nope");
        Assert.Equal(SettingsFocus.GatewayPort, router.PendingFocus);

        router.ConsumePendingFocus(SettingsFocus.GatewayPort);
        Assert.Null(router.PendingFocus);
    }

    [Fact]
    public void Reset_ClearsAllPendingState()
    {
        var router = new SettingsRouter { Query = "abc" };
        router.Navigate(SettingsManifest.All.Single(i => i.Id == "daemon.gateway.host"));
        router.Query = "still typing";

        router.Reset();

        Assert.Equal(string.Empty, router.Query);
        Assert.Null(router.PendingAnchor);
        Assert.Null(router.PendingFocus);
        Assert.Null(router.HighlightedAnchor);
        Assert.Empty(router.Path);
    }

    [Fact]
    public void IsSearching_TracksNonBlankQuery()
    {
        var router = new SettingsRouter();
        Assert.False(router.IsSearching);
        router.Query = "  ";
        Assert.False(router.IsSearching);
        router.Query = "glass";
        Assert.True(router.IsSearching);
    }

    [Fact]
    public void Results_RankAgainstTheLiveManifest()
    {
        var router = new SettingsRouter { Query = "telegram" };
        var results = router.Results();
        Assert.Contains(results, r => r.Id == "notifications.telegram");
    }

    [Fact]
    public void HighlightScheduler_FiresTheFadeAndClearsHighlight()
    {
        var scheduler = new ManualHighlightScheduler();
        var router = new SettingsRouter(scheduler);
        var item = SettingsManifest.All.Single(i => i.Id == "daemon.gateway.host");

        router.Navigate(item);
        Assert.Equal(SettingsAnchor.GatewayHost, router.HighlightedAnchor);
        Assert.Equal(SettingsRouter.HighlightFadeSeconds, scheduler.LastDelaySeconds);

        scheduler.FirePending(); // simulate the 1.4s elapsing
        Assert.Null(router.HighlightedAnchor);
        Assert.Equal(SettingsAnchor.GatewayHost, router.PendingAnchor); // fade is independent of scroll
    }

    // ── Deep-link resolver ────────────────────────────────────────────────────

    [Fact]
    public void DeepLink_Item_ResolvesTrimmedIdsAndRejectsUnknown()
    {
        Assert.Equal("agents.quotaDisplay", SettingsDeepLink.Item("  agents.quotaDisplay  ")?.Id);
        Assert.Null(SettingsDeepLink.Item(null));
        Assert.Null(SettingsDeepLink.Item("   "));
        Assert.Null(SettingsDeepLink.Item("does.not.exist"));
    }

    [Fact]
    public void DeepLink_Route_RaisesOpenRequestForKnownItemsOnly()
    {
        string? seen = null;
        void Handler(string id) => seen = id;
        SettingsDeepLink.OpenSettingsItemRequested += Handler;
        try
        {
            Assert.True(SettingsDeepLink.Route("account.signIn"));
            Assert.Equal("account.signIn", seen);

            seen = null;
            Assert.False(SettingsDeepLink.Route("nope.nope"));
            Assert.Null(seen);
        }
        finally
        {
            SettingsDeepLink.OpenSettingsItemRequested -= Handler;
        }
    }

    private sealed class ManualHighlightScheduler : IHighlightScheduler
    {
        private Action? _pending;

        public double LastDelaySeconds { get; private set; }

        public void Schedule(double seconds, Action action)
        {
            LastDelaySeconds = seconds;
            _pending = action;
        }

        public void FirePending()
        {
            var action = _pending;
            _pending = null;
            action?.Invoke();
        }
    }
}
