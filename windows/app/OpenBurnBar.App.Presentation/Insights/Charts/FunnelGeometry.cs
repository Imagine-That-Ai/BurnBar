using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Insights.Charts;

/// <summary>
/// Pure layout for the funnel chart. Each step is a horizontal bar whose width is
/// proportional to <c>count / maxCount</c> (the widest step, normally the first), centered
/// horizontally so the classic funnel taper appears. Steps stack top-to-bottom in order.
/// </summary>
public static class FunnelGeometry
{
    /// <summary>Lay out one centered bar per funnel step.</summary>
    public static IReadOnlyList<FunnelBarGeometry> Layout(
        IReadOnlyList<FunnelStep> steps,
        PlotRect rect,
        double rowGap = 8)
    {
        if (steps.Count == 0 || rect.Width <= 0 || rect.Height <= 0)
        {
            return Array.Empty<FunnelBarGeometry>();
        }

        double max = steps.Max(s => s.Count);
        if (max <= 0)
        {
            max = 1;
        }

        double slot = rect.Height / steps.Count;
        double barHeight = Math.Max(1, slot - rowGap);

        var result = new List<FunnelBarGeometry>(steps.Count);
        for (int i = 0; i < steps.Count; i++)
        {
            FunnelStep step = steps[i];
            double fraction = Math.Clamp(step.Count / max, 0, 1);
            double width = fraction * rect.Width;
            double x = rect.X + ((rect.Width - width) / 2);
            double y = rect.Y + (i * slot) + ((slot - barHeight) / 2);
            InsightRgb color = InsightFormatting.SeriesColor(step.Id);
            result.Add(new FunnelBarGeometry(step.Id, step.Label, fraction, step.Count, x, y, width, barHeight, color));
        }

        return result;
    }
}
