using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.ElderWand;

// PORTED (faithful) from the row-breaking + sizing math in
//   AgentLens/Views/Chat/ElderWand/ElderWandFlowLayout.swift
//
// The WinUI ElderWandFlowPanel (a Windows-only Microsoft.UI.Xaml Panel) delegates its
// MeasureOverride/ArrangeOverride wrapping decisions to this pure math so the exact
// left-aligned wrap behavior — chips flow horizontally and wrap to a new row when the
// next chip would exceed the proposed width — is unit-tested on macOS, independent of
// the GPU/XAML layout pass. Mirrors the Swift computeRows / sizeThatFits logic.

/// <summary>A measured item size, WinUI-free (no <c>Windows.Foundation.Size</c> dependency).</summary>
public readonly record struct FlowSize(double Width, double Height);

/// <summary>Pure wrapping-flow geometry. Swift: <c>ElderWandFlowLayout</c>.</summary>
public static class ElderWandFlowLayoutMath
{
    /// <summary>
    /// Groups item indices into rows given a maximum row width and horizontal spacing.
    /// Each item lands on the current row unless the row is non-empty and adding the item
    /// (plus spacing) would exceed <paramref name="maxWidth"/>, in which case a new row
    /// starts. Faithful to the Swift <c>computeRows(maxWidth:subviews:)</c> pass (empty rows
    /// are dropped). Pass <see cref="double.PositiveInfinity"/> for an unconstrained width.
    /// </summary>
    public static IReadOnlyList<IReadOnlyList<int>> ComputeRows(
        double maxWidth,
        double horizontalSpacing,
        IReadOnlyList<FlowSize> sizes)
    {
        if (sizes is null)
        {
            throw new ArgumentNullException(nameof(sizes));
        }

        var rows = new List<List<int>> { new() };
        double currentRowWidth = 0;

        for (int i = 0; i < sizes.Count; i++)
        {
            double width = sizes[i].Width;
            bool isRowEmpty = rows[^1].Count == 0;
            double projectedWidth = width + (isRowEmpty ? 0 : horizontalSpacing);

            if (!isRowEmpty && currentRowWidth + projectedWidth > maxWidth)
            {
                rows.Add(new List<int>());
                currentRowWidth = 0;
            }

            bool nowEmpty = rows[^1].Count == 0;
            rows[^1].Add(i);
            currentRowWidth += width + (nowEmpty ? 0 : horizontalSpacing);
        }

        return rows
            .Where(row => row.Count > 0)
            .Select(row => (IReadOnlyList<int>)row)
            .ToList();
    }

    /// <summary>
    /// The total size the flow occupies. Height sums each row's tallest item plus vertical
    /// spacing between rows; width is the constrained width, or (when unconstrained) the
    /// widest row. Faithful to the Swift <c>sizeThatFits(proposal:subviews:)</c>.
    /// </summary>
    public static FlowSize Measure(
        double maxWidth,
        double horizontalSpacing,
        double verticalSpacing,
        IReadOnlyList<FlowSize> sizes)
    {
        var rows = ComputeRows(maxWidth, horizontalSpacing, sizes);
        if (rows.Count == 0)
        {
            return new FlowSize(0, 0);
        }

        double height = 0;
        for (int r = 0; r < rows.Count; r++)
        {
            double rowHeight = rows[r].Max(i => sizes[i].Height);
            height += rowHeight + (r > 0 ? verticalSpacing : 0);
        }

        double width;
        if (!double.IsInfinity(maxWidth))
        {
            width = maxWidth;
        }
        else
        {
            width = rows.Max(row =>
            {
                double rowWidth = 0;
                for (int j = 0; j < row.Count; j++)
                {
                    rowWidth += sizes[row[j]].Width + (j > 0 ? horizontalSpacing : 0);
                }

                return rowWidth;
            });
        }

        return new FlowSize(width, height);
    }
}
