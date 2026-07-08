using System;
using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Insights;
using OpenBurnBar.App.Presentation.Insights.Charts;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Real tests for the donut sector angles + the KPI sparkline normalization.
/// </summary>
public sealed class DonutAndSparklineGeometryTests
{
    [Fact]
    public void Donut_EqualSlices_EachSweepsQuarterTurn()
    {
        var slices = new List<DistributionSlice>
        {
            new("a", "A", 10),
            new("b", "B", 10),
            new("c", "C", 10),
            new("d", "D", 10),
        };
        IReadOnlyList<DonutSliceGeometry> laid = DonutGeometry.Layout(slices);

        Assert.All(laid, s => Assert.Equal(90, s.SweepAngleDeg, 6));
        Assert.Equal(-90, laid[0].StartAngleDeg, 6);
        Assert.Equal(0, laid[1].StartAngleDeg, 6);
        Assert.Equal(90, laid[2].StartAngleDeg, 6);
        Assert.Equal(180, laid[3].StartAngleDeg, 6);
    }

    [Fact]
    public void Donut_UnequalSlices_ProportionalSweeps()
    {
        var slices = new List<DistributionSlice> { new("a", "A", 30), new("b", "B", 10) };
        IReadOnlyList<DonutSliceGeometry> laid = DonutGeometry.Layout(slices);
        Assert.Equal(270, laid[0].SweepAngleDeg, 6);
        Assert.Equal(90, laid[1].SweepAngleDeg, 6);
        Assert.Equal(180, laid[1].StartAngleDeg, 6);
    }

    [Fact]
    public void Donut_ZeroTotal_ReturnsEmpty()
        => Assert.Empty(DonutGeometry.Layout(new List<DistributionSlice> { new("a", "A", 0) }));

    [Fact]
    public void Donut_PointOnArc_TopAndRight()
    {
        var center = new ChartPoint(0, 0);
        ChartPoint right = DonutGeometry.PointOnArc(center, 10, 0);
        ChartPoint top = DonutGeometry.PointOnArc(center, 10, -90);
        Assert.Equal(10, right.X, 3);
        Assert.Equal(0, right.Y, 3);
        Assert.Equal(0, top.X, 3);
        Assert.Equal(-10, top.Y, 3);
    }

    [Fact]
    public void Sparkline_NormalizesAndInvertsY()
    {
        IReadOnlyList<ChartPoint> pts = KpiSparklineGeometry.Layout(
            new List<double> { 0, 5, 10 }, new PlotRect(0, 0, 100, 50));
        Assert.Equal(3, pts.Count);
        Assert.Equal(0, pts[0].X, 3);
        Assert.Equal(50, pts[0].Y, 3);  // min → bottom
        Assert.Equal(50, pts[1].X, 3);
        Assert.Equal(25, pts[1].Y, 3);  // mid
        Assert.Equal(100, pts[2].X, 3);
        Assert.Equal(0, pts[2].Y, 3);   // max → top
    }

    [Fact]
    public void Sparkline_FlatSeries_MapsToMidline()
    {
        IReadOnlyList<ChartPoint> pts = KpiSparklineGeometry.Layout(
            new List<double> { 5, 5, 5 }, new PlotRect(0, 0, 100, 50));
        Assert.All(pts, p => Assert.Equal(25, p.Y, 3));
    }

    [Fact]
    public void Sparkline_Empty_ReturnsEmpty()
        => Assert.Empty(KpiSparklineGeometry.Layout(Array.Empty<double>(), new PlotRect(0, 0, 100, 50)));
}
