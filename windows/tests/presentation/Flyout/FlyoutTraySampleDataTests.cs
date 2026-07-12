using OpenBurnBar.App.Presentation.Flyout;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Flyout;

public sealed class FlyoutTraySampleDataTests
{
    [Fact]
    public void Snapshot_HasSummaryProvidersInsights()
    {
        FlyoutTraySnapshot snap = FlyoutTraySampleData.Snapshot();
        Assert.False(string.IsNullOrWhiteSpace(snap.TodayMetricLabel));
        Assert.True(snap.Providers.Count >= 4);
        Assert.True(snap.Insights.Count >= 1);
        Assert.True(snap.Sparkline.Count >= 2);
    }
}
