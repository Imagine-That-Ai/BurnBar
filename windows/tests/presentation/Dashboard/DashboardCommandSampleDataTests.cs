using OpenBurnBar.App.Presentation.Dashboard;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Dashboard;

/// <summary>Locks the Command-sidebar sample snapshot shape for DashboardSidebarView parity.</summary>
public sealed class DashboardCommandSampleDataTests
{
    [Fact]
    public void Snapshot_HasProvidersAndModels()
    {
        DashboardCommandSnapshot snap = DashboardCommandSampleData.Snapshot();
        Assert.Equal(DashboardUsageOrigin.Sample, snap.Origin);
        Assert.True(snap.Providers.Count >= 4);
        Assert.True(snap.Models.Count >= 5);
        Assert.Equal(snap.Providers.Count, snap.ActiveProviderCount);
        Assert.False(string.IsNullOrWhiteSpace(snap.OverviewMetricLabel));
        Assert.False(string.IsNullOrWhiteSpace(snap.TimeRangeDisplayName));
    }

    [Fact]
    public void Snapshot_ProviderIds_AreStableKeys()
    {
        DashboardCommandSnapshot snap = DashboardCommandSampleData.Snapshot();
        Assert.Contains(snap.Providers, p => p.Id == "openai");
        Assert.Contains(snap.Providers, p => p.Id == "anthropic");
        Assert.Contains(snap.Providers, p => p.Id == "cursor");
    }

    [Fact]
    public void Empty_IsHonestZero()
    {
        DashboardCommandSnapshot empty = DashboardCommandSnapshot.Empty;
        Assert.Equal(DashboardUsageOrigin.Empty, empty.Origin);
        Assert.Empty(empty.Providers);
        Assert.Empty(empty.Models);
        Assert.Equal(0, empty.SessionCount);
    }

    [Theory]
    [InlineData(DashboardCommandViewMode.Agents)]
    [InlineData(DashboardCommandViewMode.Models)]
    public void ViewMode_Enum_IsStable(DashboardCommandViewMode mode)
    {
        Assert.True(System.Enum.IsDefined(typeof(DashboardCommandViewMode), mode));
    }
}
