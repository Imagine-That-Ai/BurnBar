using System;
using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Insights;
using OpenBurnBar.App.Presentation.Insights.Charts;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Real tests for the radar geometry: axis 0 points straight up (−π/2) and the value→radius
/// mapping lands vertices at hand-computed pixel coordinates.
/// </summary>
public sealed class RadarGeometryTests
{
    [Fact]
    public void AngleFor_FourAxes_StartsAtTopAndAdvancesClockwise()
    {
        Assert.Equal(-Math.PI / 2, RadarGeometry.AngleFor(0, 4), 6);
        Assert.Equal(0, RadarGeometry.AngleFor(1, 4), 6);
        Assert.Equal(Math.PI / 2, RadarGeometry.AngleFor(2, 4), 6);
        Assert.Equal(Math.PI, RadarGeometry.AngleFor(3, 4), 6);
    }

    [Fact]
    public void PointFor_FourAxesAtFullValue_LandsOnCardinalPoints()
    {
        var center = new ChartPoint(100, 100);
        ChartPoint top = RadarGeometry.PointFor(0, 1, center, 50, 4);
        ChartPoint right = RadarGeometry.PointFor(1, 1, center, 50, 4);
        ChartPoint bottom = RadarGeometry.PointFor(2, 1, center, 50, 4);
        ChartPoint left = RadarGeometry.PointFor(3, 1, center, 50, 4);

        AssertPoint(100, 50, top);
        AssertPoint(150, 100, right);
        AssertPoint(100, 150, bottom);
        AssertPoint(50, 100, left);
    }

    [Fact]
    public void PointFor_ClampsValueToUnitRadius()
    {
        var center = new ChartPoint(0, 0);
        AssertPoint(0, -50, RadarGeometry.PointFor(0, 2.0, center, 50, 4)); // clamp to 1
        AssertPoint(0, 0, RadarGeometry.PointFor(0, 0.0, center, 50, 4));   // origin
    }

    [Fact]
    public void Layout_ComputesRadiusAndSeriesPolygon()
    {
        var data = new RadarData(
            new List<string> { "A", "B", "C", "D" },
            new List<RadarSeries> { new("s", "Series", new List<double> { 1, 1, 1, 1 }) });

        RadarGeometryResult result = RadarGeometry.Layout(data, new PlotRect(0, 0, 200, 200), axisInset: 28, rings: 4);

        Assert.Equal(72, result.Radius, 3); // 200/2 − 28
        AssertPoint(100, 100, result.Center);
        Assert.Single(result.Series);
        Assert.Equal(4, result.Series[0].Vertices.Count);
        AssertPoint(100, 28, result.Series[0].Vertices[0]); // top vertex at full radius
        Assert.Equal(4, result.GridRings.Count);
        // Outermost ring coincides with the value-1 axis endpoints.
        AssertPoint(result.AxisEndpoints[0].X, result.AxisEndpoints[0].Y, result.GridRings[3][0]);
    }

    private static void AssertPoint(double x, double y, ChartPoint p)
    {
        Assert.Equal(x, p.X, 3);
        Assert.Equal(y, p.Y, 3);
    }
}
