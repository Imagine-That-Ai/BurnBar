using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Insights.Charts;

/// <summary>
/// Pure layout for the Top-N ranking chart — the math behind the macOS
/// <c>InsightRankingView</c> (a horizontal <c>BarMark</c> per row). Bar length is proportional
/// to <c>value / maxValue</c> exactly like Swift Charts' auto-scaled domain; rows are stacked
/// top-to-bottom in insertion order.
///
/// The engine returns pixel rectangles inside a caller-supplied plot rect, so the unit tests
/// assert a known dataset → known bar widths, and the Win2D renderer draws the identical rects.
/// </summary>
public static class BarChartGeometry
{
    /// <summary>
    /// Lay out one horizontal bar per row.
    /// </summary>
    /// <param name="rows">Ranking rows in display order (top first).</param>
    /// <param name="rect">Plot rectangle to fill.</param>
    /// <param name="rowGap">Vertical gap between bars, in pixels.</param>
    /// <param name="maxOverride">Optional fixed max for the value axis; defaults to the largest row value.</param>
    public static IReadOnlyList<BarRect> Layout(
        IReadOnlyList<RankingRow> rows,
        PlotRect rect,
        double rowGap = 6,
        double? maxOverride = null)
    {
        if (rows.Count == 0 || rect.Width <= 0 || rect.Height <= 0)
        {
            return Array.Empty<BarRect>();
        }

        double max = maxOverride ?? rows.Max(r => r.Value);
        if (max <= 0)
        {
            max = 1;
        }

        double slot = rect.Height / rows.Count;
        double barHeight = Math.Max(1, slot - rowGap);

        var result = new List<BarRect>(rows.Count);
        for (int i = 0; i < rows.Count; i++)
        {
            RankingRow row = rows[i];
            double fraction = Math.Clamp(row.Value / max, 0, 1);
            double width = fraction * rect.Width;
            double y = rect.Y + (i * slot) + ((slot - barHeight) / 2);
            InsightRgb color = InsightFormatting.ResolveColor(row.ColorHex, row.Id);
            result.Add(new BarRect(row.Id, row.Label, rect.X, y, width, barHeight, row.Value, color));
        }

        return result;
    }
}
