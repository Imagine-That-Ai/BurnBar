using System;
using System.Collections.Generic;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace OpenBurnBar.App.Components;

/// <summary>
/// The dashboard action toolbar glyphs (import-from-logs / sweep-recount). Windows peer of
/// <c>AgentLens/Views/Components/DashboardActionGlyphs.swift</c>. Renders the parity-tested
/// <see cref="DashboardGlyphGeometry"/> figures as stroked WinUI paths, one per figure so the
/// per-figure line weights survive. Set <see cref="Kind"/> and <see cref="GlyphSize"/>.
/// </summary>
public sealed partial class DashboardActionGlyph : UserControl
{
    public DashboardActionGlyph()
    {
        InitializeComponent();
    }

    /// <summary>Which glyph to draw. Swift: <c>DashboardActionGlyphKind</c>.</summary>
    public DashboardActionGlyphKind Kind
    {
        get => (DashboardActionGlyphKind)GetValue(KindProperty);
        set => SetValue(KindProperty, value);
    }

    public static readonly DependencyProperty KindProperty = DependencyProperty.Register(
        nameof(Kind), typeof(DashboardActionGlyphKind), typeof(DashboardActionGlyph),
        new PropertyMetadata(DashboardActionGlyphKind.ImportFromLogs, OnVisualChanged));

    /// <summary>Edge length in DIPs. Swift: <c>DashboardActionGlyph.size</c> (default 14).</summary>
    public double GlyphSize
    {
        get => (double)GetValue(GlyphSizeProperty);
        set => SetValue(GlyphSizeProperty, value);
    }

    public static readonly DependencyProperty GlyphSizeProperty = DependencyProperty.Register(
        nameof(GlyphSize), typeof(double), typeof(DashboardActionGlyph),
        new PropertyMetadata(14.0, OnSizeChanged));

    /// <summary>Stroke color. Defaults to the text-base token brush.</summary>
    public Brush? GlyphStroke
    {
        get => (Brush?)GetValue(GlyphStrokeProperty);
        set => SetValue(GlyphStrokeProperty, value);
    }

    public static readonly DependencyProperty GlyphStrokeProperty = DependencyProperty.Register(
        nameof(GlyphStroke), typeof(Brush), typeof(DashboardActionGlyph),
        new PropertyMetadata(null, OnVisualChanged));

    private static void OnSizeChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var view = (DashboardActionGlyph)d;
        double size = (double)e.NewValue;
        view.GlyphCanvas.Width = size;
        view.GlyphCanvas.Height = size;
        view.Rebuild();
    }

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((DashboardActionGlyph)d).Rebuild();

    private void OnCanvasSizeChanged(object sender, SizeChangedEventArgs e) => Rebuild();

    private void Rebuild()
    {
        if (GlyphCanvas is null)
        {
            return;
        }

        GlyphCanvas.Children.Clear();

        double s = Math.Min(GlyphCanvas.Width, GlyphCanvas.Height);
        if (s <= 0 || double.IsNaN(s))
        {
            return;
        }

        double w = s / 24.0; // Swift stroke-weight unit.
        var transform = new GlyphTransform(0, 0, s, s);
        Brush stroke = GlyphStroke ?? DefaultStroke();

        foreach (GlyphFigure figure in DashboardGlyphGeometry.Figures(Kind))
        {
            double thickness = Math.Max(0.75, figure.StrokeScale * w);
            Shape shape = figure.IsEllipse
                ? BuildEllipse(figure, transform)
                : BuildPath(figure, transform);

            shape.Stroke = stroke;
            shape.StrokeThickness = thickness;
            shape.StrokeStartLineCap = PenLineCap.Round;
            shape.StrokeEndLineCap = PenLineCap.Round;
            shape.StrokeLineJoin = PenLineJoin.Round;
            GlyphCanvas.Children.Add(shape);
        }
    }

    private static Ellipse BuildEllipse(GlyphFigure figure, GlyphTransform transform)
    {
        (double cx, double cy) = transform.Map(figure.Center);
        double r = transform.Scale(figure.Radius);
        var ellipse = new Ellipse { Width = 2 * r, Height = 2 * r };
        Canvas.SetLeft(ellipse, cx - r);
        Canvas.SetTop(ellipse, cy - r);
        return ellipse;
    }

    private static Path BuildPath(GlyphFigure figure, GlyphTransform transform)
    {
        (double sx, double sy) = transform.Map(figure.Start);
        var pathFigure = new PathFigure
        {
            StartPoint = new Point(sx, sy),
            IsClosed = figure.IsClosed,
        };

        foreach (GlyphSegment seg in figure.Segments)
        {
            (double ex, double ey) = transform.Map(seg.End);
            if (seg.Kind == GlyphSegmentKind.Quad)
            {
                (double cx, double cy) = transform.Map(seg.Control);
                pathFigure.Segments.Add(new QuadraticBezierSegment
                {
                    Point1 = new Point(cx, cy),
                    Point2 = new Point(ex, ey),
                });
            }
            else
            {
                pathFigure.Segments.Add(new LineSegment { Point = new Point(ex, ey) });
            }
        }

        var geometry = new PathGeometry();
        geometry.Figures.Add(pathFigure);
        return new Path { Data = geometry };
    }

    private static Brush DefaultStroke() => new SolidColorBrush(Colors.White);
}
