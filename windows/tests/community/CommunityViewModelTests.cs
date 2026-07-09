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
    public void OptedOutL2_ShowsInviteWithoutFabricatedCohort()
    {
        var vm = new CommunityViewModel(new CommunityConsentStore(Path.Combine(Path.GetTempPath(), $"obb-community-{Guid.NewGuid():N}.json")));

        Assert.True(vm.ShowInviteEmptyState);
        Assert.False(vm.IsPreviewData);
        Assert.Empty(vm.PeerCohortTokens);
        Assert.All(vm.Leaderboards, card => Assert.Empty(card.Entries));
    }
}