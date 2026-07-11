using System;
using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Insights;
using OpenBurnBar.App.Presentation.Insights.Charts;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Real tests for the time-series domain math + point mapping: the padded y-domain, the x-span,
/// and the inverted pixel mapping (larger value → higher on screen).
/// </summary>
public sealed class LineChartGeometryTests
{
    private static readonly DateTimeOffset Anchor = new(2026, 7, 1, 0, 0, 0, TimeSpan.Zero);

    private static TimeSeriesData Ramp() => new(
        new List<TimeSeriesSeries>
        {
            new("s", "Series", new List<TimeSeriesPoint>
            {
                new(Anchor, 0),
                new(Anchor.AddDays(1), 50),
                new(Anchor.AddDays(2), 100),
            }),
        },
        "Day",
        "Cost",
        ValueFormat.Currency);

    [Fact]
    public void YDomain_PadsMaxByFifteenPercent()
    {
        (double min, double max) = LineChartGeometry.YDomain(Ramp().Series);
        Assert.Equal(0, min, 6);
        Assert.Equal(115, max, 6); // 100 · 1.15
    }

    [Fact]
    public void YDomain_IncludesNegativeMinimum()
    {
        var series = new List<TimeSeriesSeries>
        {
            new("s", "S", new List<TimeSeriesPoint> { new(Anchor, -10), new(Anchor.AddDays(1), 50) }),
        };
        (double min, double max) = LineChartGeometry.YDomain(series);
        Assert.Equal(-10, min, 6);
        Assert.Equal(57.5, max, 6);
    }

    [Fact]
    public void YDomain_EmptyCollapsesToUnit()
    {
        (double min, double max) = LineChartGeometry.YDomain(new List<TimeSeriesSeries>());
        Assert.Equal(0, min, 6);
        Assert.Equal(1, max, 6);
    }

    [Fact]
    public void XDomain_SpansMinToMax()
    {
        (DateTimeOffset min, DateTimeOffset max) = LineChartGeometry.XDomain(Ramp().Series);
        Assert.Equal(Anchor, min);
        Assert.Equal(Anchor.AddDays(2), max);
    }

    [Fact]
    public void Layout_MapsPointsWithInvertedY()
    {
        LineChartGeometryResult result = LineChartGeometry.Layout(Ramp(), new PlotRect(0, 0, 200, 100));
        IReadOnlyList<ChartPoint> pts = result.Lines[0].Points;

        // x spreads evenly; y is inverted against the padded domain [0,115].
        Assert.Equal(0, pts[0].X, 3);
        Assert.Equal(100, pts[0].Y, 3);            // value 0 → bottom
        Assert.Equal(100, pts[1].X, 3);            // midpoint in time
        Assert.Equal(100 - (50.0 / 115.0 * 100), pts[1].Y, 3);
        Assert.Equal(200, pts[2].X, 3);
        Assert.Equal(100 - (100.0 / 115.0 * 100), pts[2].Y, 3);
    }
}
