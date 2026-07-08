using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Insights;
using OpenBurnBar.App.Presentation.Insights.Charts;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Real tests for the funnel geometry: each step's width is a fraction of the widest step and
/// the bar is centered so the classic taper appears.
/// </summary>
public sealed class FunnelGeometryTests
{
    private static readonly IReadOnlyList<FunnelStep> Steps = new List<FunnelStep>
    {
        new("s0", "Opened", 1000),
        new("s1", "Prompted", 600),
        new("s2", "Ran", 300),
        new("s3", "Kept", 150),
    };

    [Fact]
    public void Layout_FractionsRelativeToWidestStep()
    {
        IReadOnlyList<FunnelBarGeometry> bars = FunnelGeometry.Layout(Steps, new PlotRect(0, 0, 300, 120), rowGap: 0);
        Assert.Equal(1.0, bars[0].Fraction, 3);
        Assert.Equal(0.6, bars[1].Fraction, 3);
        Assert.Equal(0.3, bars[2].Fraction, 3);
        Assert.Equal(0.15, bars[3].Fraction, 3);
    }

    [Fact]
    public void Layout_CentersBarsHorizontally()
    {
        IReadOnlyList<FunnelBarGeometry> bars = FunnelGeometry.Layout(Steps, new PlotRect(0, 0, 300, 120), rowGap: 0);
        Assert.Equal(300, bars[0].Width, 3);
        Assert.Equal(0, bars[0].X, 3);
        Assert.Equal(180, bars[1].Width, 3);
        Assert.Equal(60, bars[1].X, 3);   // (300 − 180)/2
        Assert.Equal(45, bars[3].Width, 3);
        Assert.Equal(127.5, bars[3].X, 3); // (300 − 45)/2
    }

    [Fact]
    public void Layout_Empty_ReturnsEmpty()
        => Assert.Empty(FunnelGeometry.Layout(new List<FunnelStep>(), new PlotRect(0, 0, 300, 120)));
}
