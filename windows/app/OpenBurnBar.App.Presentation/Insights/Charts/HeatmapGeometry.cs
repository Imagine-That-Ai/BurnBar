using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.Insights.Charts;

/// <summary>
/// Pure layout + intensity binning for the heatmap — the math behind the macOS
/// <c>InsightHeatmapView</c>. Each cell's intensity is <c>value / max</c> over the whole grid,
/// and the fill alpha follows the Swift ramp <c>0.15 + 0.7·t</c> (so even a zero cell shows a
/// faint tint). Cells are laid out row-major inside the plot rect.
/// </summary>
public static class HeatmapGeometry
{
    /// <summary>The alpha ramp used for a normalized intensity (parity with Swift's <c>colorFor</c>).</summary>
    public static double AlphaFor(double intensity) => 0.15 + (0.7 * Math.Clamp(intensity, 0, 1));

    /// <summary>The largest value across every cell (used as the intensity denominator).</summary>
    public static double MaxValue(IReadOnlyList<IReadOnlyList<double>> cells)
    {
        double max = 0;
        bool any = false;
        foreach (IReadOnlyList<double> row in cells)
        {
            foreach (double v in row)
            {
                if (!any || v > max)
                {
                    max = v;
                    any = true;
                }
            }
        }

        return any ? max : 1;
    }

    /// <summary>Lay out every cell with its normalized intensity + fill alpha.</summary>
    public static IReadOnlyList<HeatmapCellGeometry> Layout(
        IReadOnlyList<IReadOnlyList<double>> cells,
        PlotRect rect,
        double cellGap = 1)
    {
        if (cells.Count == 0)
        {
            return Array.Empty<HeatmapCellGeometry>();
        }

        int rowCount = cells.Count;
        int colCount = 0;
        foreach (IReadOnlyList<double> row in cells)
        {
            colCount = Math.Max(colCount, row.Count);
        }

        if (colCount == 0)
        {
            return Array.Empty<HeatmapCellGeometry>();
        }

        double max = MaxValue(cells);
        if (max <= 0)
        {
            max = 1;
        }

        double cellWidth = rect.Width / colCount;
        double cellHeight = rect.Height / rowCount;

        var result = new List<HeatmapCellGeometry>(rowCount * colCount);
        for (int r = 0; r < rowCount; r++)
        {
            IReadOnlyList<double> row = cells[r];
            for (int c = 0; c < row.Count; c++)
            {
                double value = row[c];
                double intensity = Math.Clamp(value / max, 0, 1);
                double alpha = AlphaFor(intensity);
                double x = rect.X + (c * cellWidth);
                double y = rect.Y + (r * cellHeight);
                result.Add(new HeatmapCellGeometry(
                    r,
                    c,
                    value,
                    intensity,
                    alpha,
                    x,
                    y,
                    Math.Max(0, cellWidth - cellGap),
                    Math.Max(0, cellHeight - cellGap)));
            }
        }

        return result;
    }
}
