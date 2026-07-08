using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.Insights.Charts;

/// <summary>
/// Pure geometry for the radar / spider chart — a direct port of the angle + polygon math in
/// the macOS <c>InsightRadarView</c>.
///
/// Axis <c>i</c> sits at angle <c>i·(2π/n) − π/2</c> (so axis 0 points straight up), and a
/// value <c>v ∈ [0,1]</c> maps to radius <c>r·clamp(v,0,1)</c>. Because this is exactly the
/// Swift math, the unit tests can assert hand-computed vertices (e.g. axis 0 at value 1 lands
/// at <c>(centerX, centerY − r)</c>).
/// </summary>
public static class RadarGeometry
{
    private const int DefaultRings = 4;

    /// <summary>The angle (radians) of axis <paramref name="index"/> for an <paramref name="axisCount"/>-axis radar.</summary>
    public static double AngleFor(int index, int axisCount)
    {
        int count = Math.Max(1, axisCount);
        return (index * (2 * Math.PI / count)) - (Math.PI / 2);
    }

    /// <summary>The pixel point for a normalized <paramref name="value"/> along a given axis.</summary>
    public static ChartPoint PointFor(int index, double value, ChartPoint center, double radius, int axisCount)
    {
        double angle = AngleFor(index, axisCount);
        double r = radius * Math.Clamp(value, 0, 1);
        return new ChartPoint(center.X + (Math.Cos(angle) * r), center.Y + (Math.Sin(angle) * r));
    }

    /// <summary>
    /// Compute the full radar layout: the grid rings, axis endpoints (at value 1), and one
    /// closed polygon per series. <paramref name="radius"/> defaults to inset from the plot rect.
    /// </summary>
    public static RadarGeometryResult Layout(
        RadarData data,
        PlotRect rect,
        double axisInset = 28,
        int rings = DefaultRings)
    {
        double side = Math.Min(rect.Width, rect.Height);
        double radius = Math.Max(0, (side / 2) - axisInset);
        var center = new ChartPoint(rect.CenterX, rect.CenterY);
        int axisCount = Math.Max(1, data.Axes.Count);

        var axisEndpoints = new List<ChartPoint>(axisCount);
        for (int i = 0; i < axisCount; i++)
        {
            axisEndpoints.Add(PointFor(i, 1.0, center, radius, axisCount));
        }

        var gridRings = new List<IReadOnlyList<ChartPoint>>(rings);
        for (int ring = 1; ring <= rings; ring++)
        {
            double r = radius * ring / rings;
            var vertices = new List<ChartPoint>(axisCount);
            for (int i = 0; i < axisCount; i++)
            {
                vertices.Add(PointFor(i, 1.0, center, r, axisCount));
            }

            gridRings.Add(vertices);
        }

        var series = new List<RadarPolygon>(data.Series.Count);
        foreach (RadarSeries s in data.Series)
        {
            var verts = new List<ChartPoint>(s.Values.Count);
            for (int i = 0; i < s.Values.Count; i++)
            {
                verts.Add(PointFor(i, s.Values[i], center, radius, axisCount));
            }

            InsightRgb color = InsightFormatting.ResolveColor(s.ColorHex, s.Id);
            series.Add(new RadarPolygon(s.Id, s.Name, verts, color));
        }

        return new RadarGeometryResult(center, radius, axisEndpoints, gridRings, series);
    }
}
