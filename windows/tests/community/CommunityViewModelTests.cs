using Xunit;
using OpenBurnBar.App.Community;

namespace OpenBurnBar.App.Community.Tests;

public sealed class CommunityViewModelTests
{
    [Fact]
    public void OptedInL2_UsesPreviewOnlyEmptyLeaderboards()
    {
        var store = new CommunityConsentStore(Path.Combine(Path.GetTempPath(), $"obb-community-{Guid.NewGuid():N}.json"));
        store.Replace(store.State with
        {
            L2Rankings = ConsentTriState.Granted,
            L2Tiers = new CommunityTierConsent(
                World: ConsentTriState.Granted,
                Country: ConsentTriState.Granted,
                Region: ConsentTriState.Granted,
                City: ConsentTriState.Granted),
            LocationConsent = ConsentTriState.Granted,
            ManualCityInput = "Portland",
        });

        var vm = new CommunityViewModel(store);

        Assert.True(vm.IsPreviewData);
        Assert.All(vm.Leaderboards, card =>
        {
            Assert.True(card.BelowThreshold);
            Assert.Empty(card.Entries);
            Assert.Null(card.YourRank);
        });
        Assert.Equal("Portland", vm.Leaderboards.First(c => c.Tier == GeographyTier.City).GeoLabel);
        Assert.Contains("Manual city label", vm.Leaderboards.First(c => c.Tier == GeographyTier.City).GeoConfidenceCopy);
        Assert.Contains("locale/timezone", vm.Leaderboards.First(c => c.Tier == GeographyTier.Country).GeoConfidenceCopy);
        Assert.DoesNotContain("ember-fox", vm.Leaderboards.SelectMany(c => c.Entries).Select(e => e.Handle));
    }

    [Fact]
    public void OptedInL2_RendersInjectedLiveSnapshotAndLeaderboard()
    {
        var store = new CommunityConsentStore(Path.Combine(Path.GetTempPath(), $"obb-community-{Guid.NewGuid():N}.json"));
        store.Replace(store.State with
        {
            L2Rankings = ConsentTriState.Granted,
            L2Tiers = new CommunityTierConsent(
                World: ConsentTriState.Granted,
                Country: ConsentTriState.Granted,
                Region: ConsentTriState.Granted,
                City: ConsentTriState.Granted),
            LocationConsent = ConsentTriState.Granted,
            ManualCityInput = "Portland",
        });
        var live = new CommunityLiveData(
            ShareSnapshot: new CommunityShareSnapshotDoc(
                new CommunityWindowTotals(
                    new CommunityUsageTotal(100, 0.1),
                    new CommunityUsageTotal(700, 0.7),
                    new CommunityUsageTotal(12_500, 12.5),
                    new CommunityUsageTotal(30_000, 30),
                    new CommunityUsageTotal(100_000, 100)),
                new Dictionary<string, double> { ["sonnet"] = 0.7, ["opus"] = 0.3 },
                new Dictionary<string, double> { ["coding"] = 8, ["research"] = 2 }),
            Leaderboards: new[]
            {
                new CommunityLeaderboardCard(
                    GeographyTier.World,
                    "World",
                    "World ranking needs no location.",
                    new[]
                    {
                        new LeaderboardEntry(1, "anon-a", 20_000, 20, RankMovement.Up),
                        new LeaderboardEntry(2, "anon-b", 12_500, 12.5, RankMovement.Same),
                    },
                    new PercentileBands(10_000, 15_000, 20_000, 25_000),
                    12,
                    BelowThreshold: false,
                    KThreshold: 10,
                    YourRank: 2,
                    YourMovement: RankMovement.Same),
            });

        var vm = new CommunityViewModel(store, live);

        Assert.False(vm.IsPreviewData);
        Assert.Contains("Live community data synced", vm.StatusMessage);
        Assert.Equal(12_500, vm.HeroTokens);
        Assert.Contains("sonnet 70%", vm.ModelMixSummary);
        Assert.Equal(new[] { 20_000d, 12_500d }, vm.PeerCohortTokens);
        Assert.Equal(new[] { "coding", "research" }, vm.PurposeBreakdown.Select(slice => slice.Category));
    }

    [Fact]
    public void OptedOutL2_ShowsInviteWithoutFabricatedCohort()
    {
        var vm = new CommunityViewModel(new CommunityConsentStore(Path.Combine(Path.GetTempPath(), $"obb-community-{Guid.NewGuid():N}.json")));

        Assert.True(vm.ShowInviteEmptyState);
        Assert.False(vm.IsPreviewData);
        Assert.Empty(vm.PeerCohortTokens);
        Assert.All(vm.Leaderboards, card => Assert.Empty(card.Entries));
    }

    [Fact]
    public void OptingOutL2_ClearsStaleStatusMessage()
    {
        var store = new CommunityConsentStore(Path.Combine(Path.GetTempPath(), $"obb-community-{Guid.NewGuid():N}.json"));
        store.Replace(store.State with
        {
            L2Rankings = ConsentTriState.Granted,
            L2Tiers = new CommunityTierConsent(World: ConsentTriState.Granted),
        });
        var vm = new CommunityViewModel(store);
        Assert.NotEmpty(vm.StatusMessage);

        vm.CycleL2Rankings();
        vm.CycleL2Rankings();

        Assert.True(vm.ShowInviteEmptyState);
        Assert.Equal(string.Empty, vm.StatusMessage);
    }

    [Fact]
    public void ManualCityInput_PreservesSpacesWhileTyping()
    {
        var store = new CommunityConsentStore(Path.Combine(Path.GetTempPath(), $"obb-community-{Guid.NewGuid():N}.json"));
        store.Replace(store.State with
        {
            L2Rankings = ConsentTriState.Granted,
            L2Tiers = new CommunityTierConsent(City: ConsentTriState.Granted),
            LocationConsent = ConsentTriState.Granted,
        });
        var vm = new CommunityViewModel(store);

        vm.SetManualCityInput("San ");
        Assert.Equal("San ", vm.Consent.ManualCityInput);

        vm.SetManualCityInput("San Francisco");
        Assert.Equal("San Francisco", vm.Consent.ManualCityInput);
        Assert.Contains("manual city label", vm.CityConfidenceCopy, StringComparison.OrdinalIgnoreCase);
    }
}
