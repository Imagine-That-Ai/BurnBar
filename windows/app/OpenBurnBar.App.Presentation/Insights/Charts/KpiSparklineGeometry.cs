using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Insights.Charts;

/// <summary>
/// Pure normalization for the KPI-tile sparkline — the mini line drawn under the headline
/// number in the macOS <c>InsightKPITileView</c>. Values are min–max normalized into the plot
/// rect (y inverted). A flat series maps to the vertical midline. The unit tests assert the
/// mapped points for a known series.
/// </summary>
public static class KpiSparklineGeometry
{
    /// <summary>Map sparkline values into pixel points inside <paramref name="rect"/> (evenly spaced on x).</summary>
    public static IReadOnlyList<ChartPoint> Layout(IReadOnlyList<double> values, PlotRect rect)
    {
        if (values.Count == 0 || rect.Width <= 0 || rect.Height <= 0)
        {
            return Array.Empty<ChartPoint>();
        }

        double min = values.Min();
        double max = values.Max();
        double span = max - min;

        var result = new List<ChartPoint>(values.Count);
        double stepX = values.Count > 1 ? rect.Width / (values.Count - 1) : 0;
        for (int i = 0; i < values.Count; i++)
        {
            double normalized = span > 0 ? (values[i] - min) / span : 0.5;
            double x = rect.X + (i * stepX);
            double y = rect.Bottom - (normalized * rect.Height);
            result.Add(new ChartPoint(x, y));
        }

        return result;
    }
}
