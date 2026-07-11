using System.Collections.Generic;
using OpenBurnBar.App.Components;
using Xunit;

namespace OpenBurnBar.App.Components.Tests;

/// <summary>Asserts the sparkline layout + Catmull-Rom smoothing (MiniSparkline.swift).</summary>
public sealed class SparklineGeometryTests
{
    [Fact]
    public void NormalizedPoints_empty_is_empty() =>
        Assert.Empty(SparklineGeometry.NormalizedPoints(new List<double>(), 60, 20));

    [Fact]
    public void NormalizedPoints_flip_puts_max_at_top_and_min_at_bottom()
    {
        var pts = SparklineGeometry.NormalizedPoints(new List<double> { 0, 10 }, 60, 20);
        Assert.Equal(2, pts.Count);
        // x spread across full width.
        Assert.Equal(0, pts[0].X, 6);
        Assert.Equal(60, pts[1].X, 6);
        // min value -> bottom (y == height); max -> top (y == 0).
        Assert.Equal(20, pts[0].Y, 6);
        Assert.Equal(0, pts[1].Y, 6);
    }

    [Fact]
    public void NormalizedPoints_flat_series_pins_to_middle()
    {
        var pts = SparklineGeometry.NormalizedPoints(new List<double> { 5, 5, 5 }, 60, 20);
        foreach (SparkPoint p in pts)
        {
            Assert.Equal(10, p.Y, 6); // height/2
        }
    }

    [Fact]
    public void NormalizedPoints_single_point_sits_at_full_width()
    {
        var pts = SparklineGeometry.NormalizedPoints(new List<double> { 7 }, 60, 20);
        Assert.Single(pts);
        Assert.Equal(60, pts[0].X, 6);
    }

    [Fact]
    public void CatmullRom_produces_n_minus_one_segments_anchored_at_endpoints()
    {
        var pts = new List<SparkPoint>
        {
            new(0, 10),
            new(20, 0),
            new(40, 15),
            new(60, 5),
        };

        IReadOnlyList<SparkBezier> segs = SparklineGeometry.CatmullRomBeziers(pts);
        Assert.Equal(3, segs.Count);
        Assert.Equal(pts[0], segs[0].Start);
        Assert.Equal(pts[3], segs[2].End);
    }

    [Fact]
    public void CatmullRom_control_points_use_the_one_sixth_tension()
    {
        // Interior segment P1->P2 with neighbors P0, P3:
        //   C1 = P1 + (P2 - P0)/6 ; C2 = P2 - (P3 - P1)/6
        var pts = new List<SparkPoint>
        {
            new(0, 0),
            new(6, 0),
            new(12, 6),
            new(18, 6),
        };

        SparkBezier mid = SparklineGeometry.CatmullRomBeziers(pts)[1]; // P1(6,0) -> P2(12,6)
        // C1 = (6,0) + ((12,6)-(0,0))/6 = (6+2, 0+1) = (8,1)
        Assert.Equal(8, mid.Control1.X, 6);
        Assert.Equal(1, mid.Control1.Y, 6);
        // C2 = (12,6) - ((18,6)-(6,0))/6 = (12-2, 6-1) = (10,5)
        Assert.Equal(10, mid.Control2.X, 6);
        Assert.Equal(5, mid.Control2.Y, 6);
    }

    [Fact]
    public void CatmullRom_under_two_points_is_empty() =>
        Assert.Empty(SparklineGeometry.CatmullRomBeziers(new List<SparkPoint> { new(0, 0) }));
}
