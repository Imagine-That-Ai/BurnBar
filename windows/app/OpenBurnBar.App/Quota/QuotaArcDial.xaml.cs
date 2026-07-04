using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using OpenBurnBar.App.Components;
using OpenBurnBar.App.Theme;
using Windows.Foundation;
using Windows.UI;

namespace OpenBurnBar.App.Quota;

/// <summary>
/// Twin concentric quota rings. Windows peer of
/// <c>AgentLens/Views/Dashboard/Quota/QuotaArcDial.swift</c>. The outer ring tracks the longer-
/// horizon bucket, the inner ring the shorter one; each is either a band-tinted fill arc or a
/// dashed-muted ring when its bucket is unavailable, with a pace marker at the ideal fill-edge.
/// Every fraction / label / marker angle comes from the parity-tested
/// <see cref="QuotaArcDialModel"/> / <see cref="QuotaArcGeometry"/> / <see cref="PacingMath"/>;
/// this control only paints them. The 0→actual entrance sweep animates <see cref="AnimatedProgress"/>.
/// </summary>
public sealed partial class QuotaArcDial : UserControl
{
    private static readonly Color Amber = Color.FromArgb(0xFF, 0xFB, 0xBF, 0x24);
    private static readonly Color Warning = Color.FromArgb(0xFF, 0xFB, 0x92, 0x3C);
    private static readonly Color TrackColor = Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF); // white 0.10
    private static readonly Color TextMuted = Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF);  // white 0.55

    private const double OuterInset = 2;
    private const double OuterWidth = 8;
    private const double InnerInset = 20;
    private const double InnerWidth = 6;

    private QuotaArcDialModel? _model;
    private bool _entranceStarted;

    public QuotaArcDial()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    /// <summary>The longer-horizon bucket (outer ring), or null → dashed. Swift: <c>outer</c>.</summary>
    public QuotaDialBucket? OuterBucket
    {
        get => (QuotaDialBucket?)GetValue(OuterBucketProperty);
        set => SetValue(OuterBucketProperty, value);
    }

    public static readonly DependencyProperty OuterBucketProperty = DependencyProperty.Register(
        nameof(OuterBucket), typeof(QuotaDialBucket), typeof(QuotaArcDial),
        new PropertyMetadata(null, OnModelChanged));

    /// <summary>The shorter-horizon bucket (inner ring), or null → dashed. Swift: <c>inner</c>.</summary>
    public QuotaDialBucket? InnerBucket
    {
        get => (QuotaDialBucket?)GetValue(InnerBucketProperty);
        set => SetValue(InnerBucketProperty, value);
    }

    public static readonly DependencyProperty InnerBucketProperty = DependencyProperty.Register(
        nameof(InnerBucket), typeof(QuotaDialBucket), typeof(QuotaArcDial),
        new PropertyMetadata(null, OnModelChanged));

    /// <summary>The owning provider (drives brand tints). Swift: <c>provider</c>.</summary>
    public AgentProviderBrand Provider
    {
        get => (AgentProviderBrand)GetValue(ProviderProperty);
        set => SetValue(ProviderProperty, value);
    }

    public static readonly DependencyProperty ProviderProperty = DependencyProperty.Register(
        nameof(Provider), typeof(AgentProviderBrand), typeof(QuotaArcDial),
        new PropertyMetadata(AgentProviderBrand.Factory, OnModelChanged));

    /// <summary>Edge length of the dial in DIPs. Swift: <c>diameter</c> (default 140).</summary>
    public double Diameter
    {
        get => (double)GetValue(DiameterProperty);
        set => SetValue(DiameterProperty, value);
    }

    public static readonly DependencyProperty DiameterProperty = DependencyProperty.Register(
        nameof(Diameter), typeof(double), typeof(QuotaArcDial),
        new PropertyMetadata(140.0, OnDiameterChanged));

    /// <summary>Entrance sweep progress (0→1). Defaults to 1 so a non-animated host still renders
    /// the full dial; the load Storyboard animates it from 0. Swift: <c>animateProgress</c>.</summary>
    public double AnimatedProgress
    {
        get => (double)GetValue(AnimatedProgressProperty);
        set => SetValue(AnimatedProgressProperty, value);
    }

    public static readonly DependencyProperty AnimatedProgressProperty = DependencyProperty.Register(
        nameof(AnimatedProgress), typeof(double), typeof(QuotaArcDial),
        new PropertyMetadata(1.0, OnModelChanged));

    private static void OnModelChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((QuotaArcDial)d).Rebuild();

    private static void OnDiameterChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var dial = (QuotaArcDial)d;
        dial.Root.Width = dial.Diameter;
        dial.Root.Height = dial.Diameter;
        dial.Rebuild();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        Root.Width = Diameter;
        Root.Height = Diameter;
        Rebuild();
        StartEntrance();
    }

    private void StartEntrance()
    {
        if (_entranceStarted)
        {
            return;
        }

        _entranceStarted = true;
        var animation = new DoubleAnimation
        {
            From = 0,
            To = 1,
            Duration = new Duration(TimeSpan.FromSeconds(0.55)),
            BeginTime = TimeSpan.FromSeconds(0.05),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            EnableDependentAnimation = true,
        };
        Storyboard.SetTarget(animation, this);
        Storyboard.SetTargetProperty(animation, "AnimatedProgress");
        var storyboard = new Storyboard();
        storyboard.Children.Add(animation);
        storyboard.Begin();
    }

    private void Rebuild()
    {
        if (RingCanvas is null)
        {
            return;
        }

        RingCanvas.Children.Clear();

        double diameter = Diameter;
        double center = diameter / 2;
        _model = QuotaArcDialModel.Build(OuterBucket, InnerBucket, DateTimeOffset.Now);

        Color primary = ProviderBrand.Primary(Provider);
        Color accent = ProviderBrand.Accent(Provider);

        // Outer ring uses primary→accent; inner ring the reverse (Swift pressureGradient args).
        DrawRing(_model.Outer, OuterInset, OuterWidth, primary, accent, center);
        DrawRing(_model.Inner, InnerInset, InnerWidth, accent, primary, center);

        UpdateCenter(_model, primary);
    }

    private void UpdateCenter(QuotaArcDialModel model, Color primary)
    {
        CenterText.Text = model.CenterText;
        CenterText.Foreground = new SolidColorBrush(model.HasSignal ? primary : TextMuted);
        CenterSubtitle.Text = model.CenterSubtitle;
    }

    private void DrawRing(QuotaRingModel ring, double inset, double lineWidth, Color color, Color accent, double center)
    {
        double radius = center - inset - lineWidth / 2;
        if (radius <= 0)
        {
            return;
        }

        // Track ring (always drawn behind the fill).
        AddEllipse(center, radius, TrackColor, lineWidth, dash: null);

        if (!ring.IsAvailable)
        {
            // Dashed-muted ring — a missing bucket must not read as "fully exhausted".
            AddEllipse(center, radius, WithAlpha(color, inset > 10 ? 0.12 : 0.15), lineWidth,
                dash: inset > 10 ? new double[] { 3, 5 } : new double[] { 4, 6 });
            return;
        }

        double fraction = Math.Clamp(ring.RemainingFraction * Math.Clamp(AnimatedProgress, 0, 1), 0, 1);
        if (fraction >= 0.999)
        {
            AddEllipse(center, radius, default, lineWidth, dash: null, gradient: BandGradient(ring.Band, color, accent));
        }
        else if (fraction > 0.001)
        {
            AddArc(center, radius, fraction, lineWidth, BandGradient(ring.Band, color, accent));
        }

        // Pace marker appears once the entrance sweep has settled (Swift: only when animateProgress).
        if (AnimatedProgress >= 0.999 && ring.MarkerFraction is { } markerFraction)
        {
            AddMarker(center, radius, markerFraction, lineWidth, color);
        }
    }

    private void AddEllipse(double center, double radius, Color stroke, double thickness, double[]? dash, Brush? gradient = null)
    {
        var ellipse = new Ellipse
        {
            Width = radius * 2,
            Height = radius * 2,
            Stroke = gradient ?? new SolidColorBrush(stroke),
            StrokeThickness = thickness,
        };
        if (dash is not null)
        {
            var collection = new DoubleCollection();
            foreach (double value in dash)
            {
                collection.Add(value);
            }

            ellipse.StrokeDashArray = collection;
        }

        Canvas.SetLeft(ellipse, center - radius);
        Canvas.SetTop(ellipse, center - radius);
        RingCanvas.Children.Add(ellipse);
    }

    private void AddArc(double center, double radius, double fraction, double thickness, Brush stroke)
    {
        (double startX, double startY) = QuotaArcGeometry.PointOnRing(center, center, radius, 0);
        (double endX, double endY) = QuotaArcGeometry.PointOnRing(center, center, radius, fraction);

        var figure = new PathFigure
        {
            StartPoint = new Point(startX, startY),
            IsClosed = false,
        };
        figure.Segments.Add(new ArcSegment
        {
            Point = new Point(endX, endY),
            Size = new Size(radius, radius),
            SweepDirection = SweepDirection.Clockwise,
            IsLargeArc = QuotaArcGeometry.IsLargeArc(fraction),
        });

        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);

        RingCanvas.Children.Add(new Path
        {
            Data = geometry,
            Stroke = stroke,
            StrokeThickness = thickness,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round,
        });
    }

    private void AddMarker(double center, double radius, double fraction, double lineWidth, Color tint)
    {
        (double x, double y) = QuotaArcGeometry.PointOnRing(center, center, radius, fraction);

        double haloSize = lineWidth + 4;
        var halo = new Ellipse
        {
            Width = haloSize,
            Height = haloSize,
            Fill = new SolidColorBrush(WithAlpha(tint, 0.25)),
        };
        Canvas.SetLeft(halo, x - haloSize / 2);
        Canvas.SetTop(halo, y - haloSize / 2);
        RingCanvas.Children.Add(halo);

        double dotSize = Math.Max(lineWidth - 2, 2);
        var dot = new Ellipse
        {
            Width = dotSize,
            Height = dotSize,
            Fill = new SolidColorBrush(Colors.White),
            Stroke = new SolidColorBrush(WithAlpha(tint, 0.9)),
            StrokeThickness = 1,
        };
        Canvas.SetLeft(dot, x - dotSize / 2);
        Canvas.SetTop(dot, y - dotSize / 2);
        RingCanvas.Children.Add(dot);
    }

    private static Brush BandGradient(QuotaFillBand band, Color color, Color accent)
    {
        (Color a, Color b) = band switch
        {
            QuotaFillBand.Wide => (color, accent),
            QuotaFillBand.Comfortable => (WithAlpha(color, 0.78), WithAlpha(accent, 0.62)),
            QuotaFillBand.Narrowing => (WithAlpha(color, 0.55), Amber),
            _ => (Amber, Warning),
        };

        var brush = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
        brush.GradientStops.Add(new GradientStop { Offset = 0, Color = a });
        brush.GradientStops.Add(new GradientStop { Offset = 1, Color = b });
        return brush;
    }

    private static Color WithAlpha(Color c, double alpha) =>
        Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), c.R, c.G, c.B);
}
