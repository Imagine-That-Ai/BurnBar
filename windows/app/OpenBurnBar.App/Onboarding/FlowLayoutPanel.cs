using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace OpenBurnBar.App.Onboarding;

/// <summary>
/// A wrapping-flow <see cref="Panel"/> — the WinUI peer of the SwiftUI
/// <c>FlowLayout</c> used for the onboarding provider cloud. Items flow left-to-right and
/// wrap; rows are horizontally centered. The parity-critical row/centering MATH lives in
/// the portable, unit-tested <see cref="FlowLayoutMath"/>; this class is a thin
/// Measure/Arrange shell over it (WinUI has no built-in wrap panel outside the Community
/// Toolkit, so this keeps the port dependency-free).
/// </summary>
public sealed partial class FlowLayoutPanel : Panel
{
    /// <summary>Horizontal gap between chips. Mirrors the Swift <c>horizontalSpacing</c>
    /// (default <c>DesignSystem.Spacing.sm</c> = 8).</summary>
    public double HorizontalSpacing
    {
        get => (double)GetValue(HorizontalSpacingProperty);
        set => SetValue(HorizontalSpacingProperty, value);
    }

    public static readonly DependencyProperty HorizontalSpacingProperty =
        DependencyProperty.Register(
            nameof(HorizontalSpacing),
            typeof(double),
            typeof(FlowLayoutPanel),
            new PropertyMetadata(8.0, OnSpacingChanged));

    /// <summary>Vertical gap between rows. Mirrors the Swift <c>verticalSpacing</c> (8).</summary>
    public double VerticalSpacing
    {
        get => (double)GetValue(VerticalSpacingProperty);
        set => SetValue(VerticalSpacingProperty, value);
    }

    public static readonly DependencyProperty VerticalSpacingProperty =
        DependencyProperty.Register(
            nameof(VerticalSpacing),
            typeof(double),
            typeof(FlowLayoutPanel),
            new PropertyMetadata(8.0, OnSpacingChanged));

    private static void OnSpacingChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is FlowLayoutPanel panel)
        {
            panel.InvalidateMeasure();
            panel.InvalidateArrange();
        }
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        // Measure each child unconstrained to get its natural size — the analog of the
        // Swift `subview.sizeThatFits(ProposedViewSize(width: nil, height: nil))`.
        var items = new List<FlowSize>(Children.Count);
        foreach (UIElement child in Children)
        {
            child.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            items.Add(new FlowSize(child.DesiredSize.Width, child.DesiredSize.Height));
        }

        double? proposedWidth = double.IsInfinity(availableSize.Width) ? null : availableSize.Width;
        FlowSize measured = FlowLayoutMath.Measure(items, HorizontalSpacing, VerticalSpacing, proposedWidth);
        return new Size(measured.Width, measured.Height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var items = new List<FlowSize>(Children.Count);
        foreach (UIElement child in Children)
        {
            items.Add(new FlowSize(child.DesiredSize.Width, child.DesiredSize.Height));
        }

        IReadOnlyList<FlowPlacement> placements =
            FlowLayoutMath.Arrange(items, HorizontalSpacing, VerticalSpacing, finalSize.Width);

        foreach (FlowPlacement placement in placements)
        {
            UIElement child = Children[placement.Index];
            child.Arrange(new Rect(placement.X, placement.Y, placement.Width, placement.Height));
        }

        return finalSize;
    }
}
