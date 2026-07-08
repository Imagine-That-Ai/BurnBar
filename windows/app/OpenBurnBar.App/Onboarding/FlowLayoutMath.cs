// PORTED (portable, unit-tested) from AgentLens/Views/Onboarding/FlowLayout.swift
//   struct FlowLayout: Layout — the wrapping-flow row computation + centered placement.
//
// The row-wrapping + centering MATH is separated here (System-only, NO WinUI) so it is
// asserted by a real `dotnet test`. The WinUI Panel (FlowLayoutPanel.cs) is a thin
// Measure/Arrange shell over these functions and is Windows-only (type-checked at the
// XamlCompiler gate). Keeping the math portable means the parity-critical wrapping/
// centering behavior — including the "over-wide single chip starts at the left edge"
// clamp — is proven off-Windows.

using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Onboarding;

/// <summary>A measured child size (Swift <c>LayoutSubview.sizeThatFits</c>).</summary>
public readonly struct FlowSize
{
    public FlowSize(double width, double height)
    {
        Width = width;
        Height = height;
    }

    public double Width { get; }

    public double Height { get; }
}

/// <summary>A resolved child placement rectangle (Swift <c>subview.place(at:)</c>).</summary>
public readonly struct FlowPlacement
{
    public FlowPlacement(int index, double x, double y, double width, double height)
    {
        Index = index;
        X = x;
        Y = y;
        Width = width;
        Height = height;
    }

    /// <summary>Index of the child in the input order.</summary>
    public int Index { get; }

    public double X { get; }

    public double Y { get; }

    public double Width { get; }

    public double Height { get; }
}

/// <summary>
/// Pure wrapping-flow layout math. Items flow left-to-right and wrap to the next row;
/// rows are horizontally centered (with a non-negative clamp so an over-wide single item
/// starts at the left edge instead of being centered off-screen). Byte-for-byte with the
/// Swift <c>FlowLayout</c>.
/// </summary>
public static class FlowLayoutMath
{
    /// <summary>
    /// Partition items into rows. Swift <c>computeRows</c>: an item wraps when the running
    /// row width plus the item (and its leading spacing) would exceed <paramref name="maxWidth"/>,
    /// unless the row is still empty (a single over-wide item stays on its own row).
    /// </summary>
    public static IReadOnlyList<IReadOnlyList<int>> ComputeRows(
        IReadOnlyList<FlowSize> items,
        double horizontalSpacing,
        double maxWidth)
    {
        if (items is null)
        {
            throw new ArgumentNullException(nameof(items));
        }

        var rows = new List<List<int>> { new() };
        double currentRowWidth = 0;

        for (int i = 0; i < items.Count; i++)
        {
            List<int> currentRow = rows[^1];
            double size = items[i].Width;
            double itemWidth = size + (currentRow.Count == 0 ? 0 : horizontalSpacing);

            if (currentRowWidth + itemWidth > maxWidth && currentRow.Count > 0)
            {
                currentRow = new List<int>();
                rows.Add(currentRow);
                currentRowWidth = 0;
            }

            currentRow.Add(i);
            currentRowWidth += (currentRow.Count == 1 ? 0 : horizontalSpacing) + size;
        }

        return rows;
    }

    /// <summary>
    /// The size the flow occupies. Swift <c>sizeThatFits</c>: height is the sum of each
    /// row's tallest child plus inter-row spacing; width is <paramref name="proposedWidth"/>
    /// when given, else the widest natural row.
    /// </summary>
    public static FlowSize Measure(
        IReadOnlyList<FlowSize> items,
        double horizontalSpacing,
        double verticalSpacing,
        double? proposedWidth)
    {
        double maxWidth = proposedWidth ?? double.PositiveInfinity;
        IReadOnlyList<IReadOnlyList<int>> rows = ComputeRows(items, horizontalSpacing, maxWidth);
        if (rows.Count == 0 || (rows.Count == 1 && rows[0].Count == 0))
        {
            return new FlowSize(0, 0);
        }

        double height = 0;
        double widestRow = 0;
        for (int r = 0; r < rows.Count; r++)
        {
            IReadOnlyList<int> row = rows[r];
            double rowHeight = 0;
            double rowWidth = 0;
            for (int c = 0; c < row.Count; c++)
            {
                FlowSize item = items[row[c]];
                rowHeight = Math.Max(rowHeight, item.Height);
                rowWidth += item.Width + (c > 0 ? horizontalSpacing : 0);
            }

            height += rowHeight + (r > 0 ? verticalSpacing : 0);
            widestRow = Math.Max(widestRow, rowWidth);
        }

        double width = proposedWidth ?? widestRow;
        return new FlowSize(width, height);
    }

    /// <summary>
    /// Resolve each child's placement rectangle inside a bounds of width
    /// <paramref name="boundsWidth"/>. Swift <c>placeSubviews</c>: rows are centered
    /// (clamped non-negative) and each child is vertically centered within its row height.
    /// </summary>
    public static IReadOnlyList<FlowPlacement> Arrange(
        IReadOnlyList<FlowSize> items,
        double horizontalSpacing,
        double verticalSpacing,
        double boundsWidth,
        double boundsMinX = 0,
        double boundsMinY = 0)
    {
        IReadOnlyList<IReadOnlyList<int>> rows = ComputeRows(items, horizontalSpacing, boundsWidth);
        var placements = new List<FlowPlacement>(items.Count);
        double y = boundsMinY;

        foreach (IReadOnlyList<int> row in rows)
        {
            double rowHeight = 0;
            double rowWidth = 0;
            for (int c = 0; c < row.Count; c++)
            {
                FlowSize item = items[row[c]];
                rowHeight = Math.Max(rowHeight, item.Height);
                rowWidth += item.Width + (c > 0 ? horizontalSpacing : 0);
            }

            // Clamp the centering offset to be non-negative so a row wider than the bounds
            // (e.g. a single over-wide chip) starts at the left edge, not centered off-screen.
            double x = boundsMinX + Math.Max(0, (boundsWidth - rowWidth) / 2);

            foreach (int index in row)
            {
                FlowSize item = items[index];
                double yOffset = (rowHeight - item.Height) / 2;
                placements.Add(new FlowPlacement(index, x, y + yOffset, item.Width, item.Height));
                x += item.Width + horizontalSpacing;
            }

            y += rowHeight + verticalSpacing;
        }

        return placements;
    }
}
