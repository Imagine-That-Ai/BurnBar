using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Insights;
using OpenBurnBar.App.Presentation.Insights.Charts;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Real tests for the ranking bar-chart geometry: a known dataset produces known bar widths
/// and stacked y-positions, proportional to <c>value / max</c>.
/// </summary>
public sealed class BarChartGeometryTests
{
    private static readonly IReadOnlyList<RankingRow> Rows = new List<RankingRow>
    {
        new("a", "Alpha", 100),
        new("b", "Beta", 50),
        new("c", "Gamma", 25),
    };

    [Fact]
    public void Layout_ProducesProportionalWidths()
    {
        var rect = new PlotRect(0, 0, 200, 90);
        IReadOnlyList<BarRect> bars = BarChartGeometry.Layout(Rows, rect, rowGap: 0);

        Assert.Equal(3, bars.Count);
        Assert.Equal(200, bars[0].Width, 3); // 100/100 · 200
        Assert.Equal(100, bars[1].Width, 3); // 50/100 · 200
        Assert.Equal(50, bars[2].Width, 3);  // 25/100 · 200
    }

    [Fact]
    public void Layout_StacksRowsWithEqualSlots()
    {
        var rect = new PlotRect(0, 0, 200, 90);
        IReadOnlyList<BarRect> bars = BarChartGeometry.Layout(Rows, rect, rowGap: 0);

        Assert.Equal(0, bars[0].Y, 3);
        Assert.Equal(30, bars[1].Y, 3);
        Assert.Equal(60, bars[2].Y, 3);
        Assert.All(bars, b => Assert.Equal(30, b.Height, 3));
        Assert.All(bars, b => Assert.Equal(0, b.X, 3));
    }

    [Fact]
    public void Layout_HonorsRowGap()
    {
        var rect = new PlotRect(0, 0, 200, 90);
        IReadOnlyList<BarRect> bars = BarChartGeometry.Layout(Rows, rect, rowGap: 6);
        Assert.Equal(24, bars[0].Height, 3); // slot 30 − gap 6
        Assert.Equal(3, bars[0].Y, 3);       // centered in the slot
    }

    [Fact]
    public void Layout_MaxOverride_RescalesBars()
    {
        var rect = new PlotRect(0, 0, 200, 90);
        IReadOnlyList<BarRect> bars = BarChartGeometry.Layout(Rows, rect, rowGap: 0, maxOverride: 200);
        Assert.Equal(100, bars[0].Width, 3); // 100/200 · 200
    }

    [Fact]
    public void Layout_ResolvesExplicitColor()
    {
        var rows = new List<RankingRow> { new("x", "X", 10, ColorHex: "#FF0000") };
        IReadOnlyList<BarRect> bars = BarChartGeometry.Layout(rows, new PlotRect(0, 0, 100, 30));
        Assert.Equal(new InsightRgb(255, 0, 0), bars[0].Color);
    }

    [Fact]
    public void Layout_EmptyOrZeroRect_ReturnsEmpty()
    {
        Assert.Empty(BarChartGeometry.Layout(new List<RankingRow>(), new PlotRect(0, 0, 100, 30)));
        Assert.Empty(BarChartGeometry.Layout(Rows, new PlotRect(0, 0, 0, 30)));
    }
}
