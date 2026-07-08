using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Insights.Charts;

/// <summary>
/// Pure sector math for the donut / pie chart — the angular layout behind the macOS
/// <c>InsightDistributionView</c>'s <c>SectorMark</c>. Each slice sweeps
/// <c>value/total · 360°</c>, sectors accumulate clockwise starting at the top (−90°). The
/// unit tests assert that N equal slices each get <c>360/N</c> degrees at the expected offsets.
/// </summary>
public static class DonutGeometry
{
    /// <summary>0° = 12 o'clock; sweeps proceed clockwise from here.</summary>
    public const double StartOffsetDeg = -90;

    /// <summary>Compute the start + sweep angle (degrees) for every slice.</summary>
    public static IReadOnlyList<DonutSliceGeometry> Layout(IReadOnlyList<DistributionSlice> slices)
    {
        if (slices.Count == 0)
        {
            return Array.Empty<DonutSliceGeometry>();
        }

        double total = slices.Where(s => s.Value > 0).Sum(s => s.Value);
        if (total <= 0)
        {
            return Array.Empty<DonutSliceGeometry>();
        }

        var result = new List<DonutSliceGeometry>(slices.Count);
        double cursor = StartOffsetDeg;
        foreach (DistributionSlice slice in slices)
        {
            double value = Math.Max(0, slice.Value);
            double sweep = value / total * 360.0;
            InsightRgb color = InsightFormatting.ResolveColor(slice.ColorHex, slice.Id);
            result.Add(new DonutSliceGeometry(slice.Id, slice.Label, cursor, sweep, slice.Value, color));
            cursor += sweep;
        }

        return result;
    }

    /// <summary>The pixel point on the arc at a given angle (degrees) + radius from a center.</summary>
    public static ChartPoint PointOnArc(ChartPoint center, double radius, double angleDeg)
    {
        double rad = angleDeg * Math.PI / 180.0;
        return new ChartPoint(center.X + (Math.Cos(rad) * radius), center.Y + (Math.Sin(rad) * radius));
    }
}
