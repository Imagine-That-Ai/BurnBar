using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace OpenBurnBar.App.Insights;

/// <summary>
/// A custom <see cref="Panel"/> that positions its children into a fixed-column grid — the
/// Windows analog of the macOS <c>InsightsCanvasGridLayout</c> (a SwiftUI <c>Layout</c>). Each
/// child carries its <see cref="CellPlacement"/> via the attached
/// <c>Column</c>/<c>Row</c>/<c>ColSpan</c>/<c>RowSpan</c> properties; the panel derives the
/// column width from its own width and lays every tile into its cell rectangle.
/// </summary>
/// <remarks>
/// The placement values come straight from the parity-tested
/// <c>OpenBurnBar.App.Presentation.Insights.InsightLayout</c>, so the arithmetic here is only
/// the pixel projection (column width × span + gaps) — deliberately trivial, because the
/// packing/reflow logic is unit-tested off any UI host.
/// </remarks>
public sealed partial class InsightsCanvasPanel : Panel
{
    /// <summary>Number of columns in the grid (macOS uses 12).</summary>
    public int ColumnCount
    {
        get => (int)GetValue(ColumnCountProperty);
        set => SetValue(ColumnCountProperty, value);
    }

    public static readonly DependencyProperty ColumnCountProperty = DependencyProperty.Register(
        nameof(ColumnCount), typeof(int), typeof(InsightsCanvasPanel), new PropertyMetadata(12, OnLayoutChanged));

    /// <summary>Height of a single grid row, in DIPs.</summary>
    public double RowHeight
    {
        get => (double)GetValue(RowHeightProperty);
        set => SetValue(RowHeightProperty, value);
    }

    public static readonly DependencyProperty RowHeightProperty = DependencyProperty.Register(
        nameof(RowHeight), typeof(double), typeof(InsightsCanvasPanel), new PropertyMetadata(96.0, OnLayoutChanged));

    /// <summary>Gap between cells, in DIPs.</summary>
    public double Gap
    {
        get => (double)GetValue(GapProperty);
        set => SetValue(GapProperty, value);
    }

    public static readonly DependencyProperty GapProperty = DependencyProperty.Register(
        nameof(Gap), typeof(double), typeof(InsightsCanvasPanel), new PropertyMetadata(12.0, OnLayoutChanged));

    // ── Attached placement properties (0-indexed column/row; 1-based spans) ────────

    public static readonly DependencyProperty ColumnProperty = DependencyProperty.RegisterAttached(
        "Column", typeof(int), typeof(InsightsCanvasPanel), new PropertyMetadata(0, OnLayoutChanged));

    public static readonly DependencyProperty RowProperty = DependencyProperty.RegisterAttached(
        "Row", typeof(int), typeof(InsightsCanvasPanel), new PropertyMetadata(0, OnLayoutChanged));

    public static readonly DependencyProperty ColSpanProperty = DependencyProperty.RegisterAttached(
        "ColSpan", typeof(int), typeof(InsightsCanvasPanel), new PropertyMetadata(1, OnLayoutChanged));

    public static readonly DependencyProperty RowSpanProperty = DependencyProperty.RegisterAttached(
        "RowSpan", typeof(int), typeof(InsightsCanvasPanel), new PropertyMetadata(1, OnLayoutChanged));

    public static void SetColumn(DependencyObject element, int value) => element.SetValue(ColumnProperty, value);

    public static int GetColumn(DependencyObject element) => (int)element.GetValue(ColumnProperty);

    public static void SetRow(DependencyObject element, int value) => element.SetValue(RowProperty, value);

    public static int GetRow(DependencyObject element) => (int)element.GetValue(RowProperty);

    public static void SetColSpan(DependencyObject element, int value) => element.SetValue(ColSpanProperty, value);

    public static int GetColSpan(DependencyObject element) => (int)element.GetValue(ColSpanProperty);

    public static void SetRowSpan(DependencyObject element, int value) => element.SetValue(RowSpanProperty, value);

    public static int GetRowSpan(DependencyObject element) => (int)element.GetValue(RowSpanProperty);

    protected override Size MeasureOverride(Size availableSize)
    {
        int columns = Math.Max(1, ColumnCount);
        double width = double.IsInfinity(availableSize.Width) ? 0 : availableSize.Width;
        double columnWidth = ColumnWidth(width, columns);

        int maxRow = 0;
        foreach (UIElement child in Children)
        {
            int colSpan = Math.Max(1, Math.Min(GetColSpan(child), columns));
            int rowSpan = Math.Max(1, GetRowSpan(child));
            int row = Math.Max(0, GetRow(child));

            double cellWidth = (colSpan * columnWidth) + ((colSpan - 1) * Gap);
            double cellHeight = (rowSpan * RowHeight) + ((rowSpan - 1) * Gap);
            child.Measure(new Size(Math.Max(0, cellWidth), Math.Max(0, cellHeight)));

            maxRow = Math.Max(maxRow, row + rowSpan);
        }

        double totalHeight = maxRow > 0 ? (maxRow * RowHeight) + ((maxRow - 1) * Gap) : 0;
        return new Size(width, Math.Max(0, totalHeight));
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        int columns = Math.Max(1, ColumnCount);
        double columnWidth = ColumnWidth(finalSize.Width, columns);

        foreach (UIElement child in Children)
        {
            int column = Math.Max(0, GetColumn(child));
            int row = Math.Max(0, GetRow(child));
            int colSpan = Math.Max(1, Math.Min(GetColSpan(child), columns));
            int rowSpan = Math.Max(1, GetRowSpan(child));

            double x = column * (columnWidth + Gap);
            double y = row * (RowHeight + Gap);
            double w = (colSpan * columnWidth) + ((colSpan - 1) * Gap);
            double h = (rowSpan * RowHeight) + ((rowSpan - 1) * Gap);
            child.Arrange(new Windows.Foundation.Rect(x, y, Math.Max(0, w), Math.Max(0, h)));
        }

        return finalSize;
    }

    private double ColumnWidth(double totalWidth, int columns)
        => Math.Max(0, (totalWidth - ((columns - 1) * Gap)) / columns);

    private static void OnLayoutChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is InsightsCanvasPanel panel)
        {
            panel.InvalidateMeasure();
            panel.InvalidateArrange();
        }
        else if (VisualTreeHelperParent(d) is InsightsCanvasPanel parent)
        {
            parent.InvalidateMeasure();
            parent.InvalidateArrange();
        }
    }

    private static DependencyObject? VisualTreeHelperParent(DependencyObject d)
        => d is FrameworkElement fe ? fe.Parent : null;
}
