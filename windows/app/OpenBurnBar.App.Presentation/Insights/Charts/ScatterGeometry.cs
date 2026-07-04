using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Insights.Charts;

/// <summary>One laid-out scatter bubble in pixel space.</summary>
public readonly record struct ScatterBubble(
    string Id,
    string Label,
    double CenterX,
    double CenterY,
    double Radius,
    InsightRgb Color);

/// <summary>
/// Pure layout for the scatter / bubble chart — the math behind the macOS
/// <c>InsightScatterView</c>. X/Y are min–max normalized into the plot rect (y inverted so a
/// larger value sits higher), and the bubble radius scales with the point's <c>Size</c>. The
/// unit tests pin the mapped centers for a known dataset.
/// </summary>
public static class ScatterGeometry
{
    /// <summary>Lay out every scatter point as a bubble inside <paramref name="rect"/>.</summary>
    public static IReadOnlyList<ScatterBubble> Layout(
        IReadOnlyList<ScatterPoint> points,
        PlotRect rect,
        double minRadius = 3,
        double maxRadius = 12)
    {
        if (points.Count == 0 || rect.Width <= 0 || rect.Height <= 0)
        {
            return Array.Empty<ScatterBubble>();
        }

        double xMin = points.Min(p => p.X);
        double xMax = points.Max(p => p.X);
        double yMin = points.Min(p => p.Y);
        double yMax = points.Max(p => p.Y);
        double sizeMin = points.Min(p => p.Size);
        double sizeMax = points.Max(p => p.Size);

        double xSpan = xMax - xMin;
        double ySpan = yMax - yMin;
        double sizeSpan = sizeMax - sizeMin;

        var result = new List<ScatterBubble>(points.Count);
        foreach (ScatterPoint p in points)
        {
            double tx = xSpan > 0 ? (p.X - xMin) / xSpan : 0.5;
            double ty = ySpan > 0 ? (p.Y - yMin) / ySpan : 0.5;
            double ts = sizeSpan > 0 ? (p.Size - sizeMin) / sizeSpan : 0.5;
            double cx = rect.X + (tx * rect.Width);
            double cy = rect.Bottom - (ty * rect.Height);
            double radius = minRadius + (ts * (maxRadius - minRadius));
            InsightRgb color = InsightFormatting.ResolveColor(p.ColorHex, p.Id);
            result.Add(new ScatterBubble(p.Id, p.Label, cx, cy, radius, color));
        }

        return result;
    }
}
