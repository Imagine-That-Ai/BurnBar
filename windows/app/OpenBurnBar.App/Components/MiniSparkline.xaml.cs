using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Path = Microsoft.UI.Xaml.Shapes.Path;
using Ellipse = Microsoft.UI.Xaml.Shapes.Ellipse;
using Windows.UI;

namespace OpenBurnBar.App.Components;

/// <summary>
/// A compact area+line sparkline. Windows peer of
/// <c>AgentLens/Views/Components/MiniSparkline.swift</c>. The smoothing matches the SwiftUI
/// Charts <c>.catmullRom</c> interpolation via the parity-tested
/// <see cref="SparklineGeometry"/>. Assign <see cref="Data"/> and (optionally)
/// <see cref="LineColor"/>; the default tint is ember, as in Swift.
/// </summary>
public sealed partial class MiniSparkline : UserControl
{
    // DesignSystem.Colors.ember (dark) — the Swift default `color`.
    private static readonly Color EmberDark = Color.FromArgb(0xFF, 0xFA, 0x50, 0x53);

    public MiniSparkline()
    {
        InitializeComponent();
    }

    /// <summary>The series to plot. Swift: <c>MiniSparkline.data</c>.</summary>
    public IReadOnlyList<double>? Data
    {
        get => (IReadOnlyList<double>?)GetValue(DataProperty);
        set => SetValue(DataProperty, value);
    }

    public static readonly DependencyProperty DataProperty = DependencyProperty.Register(
        nameof(Data), typeof(IReadOnlyList<double>), typeof(MiniSparkline),
        new PropertyMetadata(null, OnVisualChanged));

    /// <summary>Line + fill tint. Swift: <c>MiniSparkline.color</c> (default ember).</summary>
    public Color LineColor
    {
        get => (Color)GetValue(LineColorProperty);
        set => SetValue(LineColorProperty, value);
    }

    public static readonly DependencyProperty LineColorProperty = DependencyProperty.Register(
        nameof(LineColor), typeof(Color), typeof(MiniSparkline),
        new PropertyMetadata(EmberDark, OnVisualChanged));

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((MiniSparkline)d).Rebuild();

    private void OnCanvasSizeChanged(object sender, SizeChangedEventArgs e) => Rebuild();

    private void Rebuild()
    {
        if (ChartCanvas is null)
        {
            return;
        }

        ChartCanvas.Children.Clear();

        double width = ChartCanvas.Width;
        double height = ChartCanvas.Height;
        if (Data is not { Count: > 0 } data || width <= 0 || height <= 0)
        {
            return;
        }

        IReadOnlyList<SparkPoint> points = SparklineGeometry.NormalizedPoints(data, width, height);
        IReadOnlyList<SparkBezier> beziers = SparklineGeometry.CatmullRomBeziers(points);

        // Area fill: the curve, then down to the baseline and back, closed + gradient-filled.
        if (points.Count >= 2)
        {
            var areaFigure = new PathFigure { StartPoint = ToPoint(points[0]), IsClosed = true };
            AppendBeziers(areaFigure, beziers);
            areaFigure.Segments.Add(new LineSegment { Point = new Point(points[^1].X, height) });
            areaFigure.Segments.Add(new LineSegment { Point = new Point(points[0].X, height) });

            var areaGeometry = new PathGeometry();
            areaGeometry.Figures.Add(areaFigure);
            ChartCanvas.Children.Add(new Path
            {
                Data = areaGeometry,
                Fill = AreaGradient(),
            });

            // Line on top.
            var lineFigure = new PathFigure { StartPoint = ToPoint(points[0]) };
            AppendBeziers(lineFigure, beziers);
            var lineGeometry = new PathGeometry();
            lineGeometry.Figures.Add(lineFigure);
            ChartCanvas.Children.Add(new Path
            {
                Data = lineGeometry,
                Stroke = new SolidColorBrush(LineColor),
                StrokeThickness = 1.5,
                StrokeLineJoin = PenLineJoin.Round,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
            });
        }

        // End-point cap (Swift PointMark on the last value).
        SparkPoint last = points[^1];
        var cap = new Ellipse { Width = 3.4, Height = 3.4, Fill = new SolidColorBrush(LineColor) };
        Canvas.SetLeft(cap, last.X - 1.7);
        Canvas.SetTop(cap, last.Y - 1.7);
        ChartCanvas.Children.Add(cap);
    }

    private static void AppendBeziers(PathFigure figure, IReadOnlyList<SparkBezier> beziers)
    {
        foreach (SparkBezier b in beziers)
        {
            figure.Segments.Add(new BezierSegment
            {
                Point1 = ToPoint(b.Control1),
                Point2 = ToPoint(b.Control2),
                Point3 = ToPoint(b.End),
            });
        }
    }

    private LinearGradientBrush AreaGradient()
    {
        // Swift: LinearGradient(colors: [color.opacity(0.22), color.opacity(0.0)], top→bottom).
        var brush = new LinearGradientBrush { StartPoint = new Point(0.5, 0), EndPoint = new Point(0.5, 1) };
        brush.GradientStops.Add(new GradientStop { Offset = 0, Color = WithAlpha(LineColor, 0.22) });
        brush.GradientStops.Add(new GradientStop { Offset = 1, Color = WithAlpha(LineColor, 0.0) });
        return brush;
    }

    private static Color WithAlpha(Color c, double alpha) =>
        Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), c.R, c.G, c.B);

    private static Point ToPoint(SparkPoint p) => new(p.X, p.Y);
}
