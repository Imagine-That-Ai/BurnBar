using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.ElderWand;
using Windows.Foundation;

namespace OpenBurnBar.App.ElderWand;

/// <summary>
/// A left-aligned wrapping flow panel — the Windows render of
/// <c>AgentLens/Views/Chat/ElderWand/ElderWandFlowLayout.swift</c>. Chips flow
/// left-to-right and wrap onto a new row when the next chip would overflow the available
/// width; each row's items are vertically centered against the tallest item in the row.
///
/// The wrap + sizing decisions delegate to the platform-agnostic
/// <see cref="ElderWandFlowLayoutMath"/> (unit-tested on macOS), so this panel is a thin
/// Microsoft.UI.Xaml measure/arrange shell over proven geometry. Windows-only; on the
/// macOS authoring host it is Roslyn syntax-checked and the app build reaches the
/// XamlCompiler gate — the documented WinUI verification ceiling.
/// </summary>
public sealed class ElderWandFlowPanel : Panel
{
    /// <summary>Horizontal gap between chips. Swift: <c>horizontalSpacing</c> (Spacing.sm).</summary>
    public double HorizontalSpacing { get; set; } = 8;

    /// <summary>Vertical gap between rows. Swift: <c>verticalSpacing</c> (Spacing.sm).</summary>
    public double VerticalSpacing { get; set; } = 8;

    protected override Size MeasureOverride(Size availableSize)
    {
        var sizes = new List<FlowSize>(Children.Count);
        foreach (var child in Children)
        {
            child.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            sizes.Add(new FlowSize(child.DesiredSize.Width, child.DesiredSize.Height));
        }

        double maxWidth = double.IsInfinity(availableSize.Width) || double.IsNaN(availableSize.Width)
            ? double.PositiveInfinity
            : availableSize.Width;

        var measured = ElderWandFlowLayoutMath.Measure(maxWidth, HorizontalSpacing, VerticalSpacing, sizes);
        return new Size(measured.Width, measured.Height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var sizes = new List<FlowSize>(Children.Count);
        foreach (var child in Children)
        {
            sizes.Add(new FlowSize(child.DesiredSize.Width, child.DesiredSize.Height));
        }

        var rows = ElderWandFlowLayoutMath.ComputeRows(finalSize.Width, HorizontalSpacing, sizes);
        double y = 0;

        foreach (var row in rows)
        {
            double rowHeight = 0;
            foreach (int index in row)
            {
                rowHeight = Math.Max(rowHeight, sizes[index].Height);
            }

            double x = 0;
            foreach (int index in row)
            {
                var child = Children[index];
                double yOffset = (rowHeight - sizes[index].Height) / 2;
                child.Arrange(new Rect(x, y + yOffset, sizes[index].Width, sizes[index].Height));
                x += sizes[index].Width + HorizontalSpacing;
            }

            y += rowHeight + VerticalSpacing;
        }

        return finalSize;
    }
}
