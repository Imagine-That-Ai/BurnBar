using System;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using OpenBurnBar.App.Components;
using OpenBurnBar.App.Theme;
using Windows.Foundation;
using Windows.UI;

namespace OpenBurnBar.App.Quota;

/// <summary>
/// One constellation orb — a provider's plan health as a ring around its logo. Windows peer of the
/// private <c>SubscriptionOrb</c> in <c>SubscriptionConstellationHero.swift</c>. The ring fill
/// fraction + band (or dashed-muted) comes from the parity-tested <see cref="SubscriptionOrbRing"/>.
/// Tapping raises <see cref="OrbTapped"/> so the hero toggles the provider focus.
/// </summary>
public sealed partial class SubscriptionOrb : UserControl
{
    private static readonly Color Amber = Color.FromArgb(0xFF, 0xFB, 0xBF, 0x24);
    private static readonly Color Warning = Color.FromArgb(0xFF, 0xFB, 0x92, 0x3C);
    private static readonly Color Track = Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF);   // white 0.10
    private static readonly Color Muted = Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF);   // white 0.55
    private static readonly Color TextBright = Color.FromArgb(0xFF, 0xF4, 0xF4, 0xF5);

    private const double Host = 64;
    private const double RingRadius = 27;  // 54px ring
    private const double HaloRadius = 30;
    private const double RingWidth = 3;

    public SubscriptionOrb()
    {
        InitializeComponent();
        Loaded += (_, _) => Rebuild();
        Root.PointerEntered += (_, _) => SetHover(true);
        Root.PointerExited += (_, _) => SetHover(false);
    }

    /// <summary>Raised when the orb is tapped, carrying its provider. The hero toggles focus.</summary>
    public event EventHandler<AgentProviderBrand>? OrbTapped;

    /// <summary>The subscription this orb represents. Swift: <c>entry</c>.</summary>
    public SubscriptionEntry? Entry
    {
        get => (SubscriptionEntry?)GetValue(EntryProperty);
        set => SetValue(EntryProperty, value);
    }

    public static readonly DependencyProperty EntryProperty = DependencyProperty.Register(
        nameof(Entry), typeof(SubscriptionEntry), typeof(SubscriptionOrb),
        new PropertyMetadata(null, OnVisualChanged));

    /// <summary>Whether this orb's provider is the focused one. Swift: <c>isSelected</c>.</summary>
    public bool IsSelected
    {
        get => (bool)GetValue(IsSelectedProperty);
        set => SetValue(IsSelectedProperty, value);
    }

    public static readonly DependencyProperty IsSelectedProperty = DependencyProperty.Register(
        nameof(IsSelected), typeof(bool), typeof(SubscriptionOrb),
        new PropertyMetadata(false, OnVisualChanged));

    /// <summary>Whether another provider is focused, so this orb dims. Swift: <c>isDimmed</c>.</summary>
    public bool IsDimmed
    {
        get => (bool)GetValue(IsDimmedProperty);
        set => SetValue(IsDimmedProperty, value);
    }

    public static readonly DependencyProperty IsDimmedProperty = DependencyProperty.Register(
        nameof(IsDimmed), typeof(bool), typeof(SubscriptionOrb),
        new PropertyMetadata(false, OnVisualChanged));

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((SubscriptionOrb)d).Rebuild();

    private void OnTapped(object sender, TappedRoutedEventArgs e)
    {
        if (Entry is { } entry)
        {
            OrbTapped?.Invoke(this, entry.Provider);
        }
    }

    private void SetHover(bool hovering)
    {
        LiftTransform.Y = hovering ? -4 : 0;
    }

    private void Rebuild()
    {
        if (RingCanvas is null || Entry is not { } entry)
        {
            return;
        }

        RingCanvas.Children.Clear();

        Logo.Provider = entry.Provider;
        SubscriptionOrbRing ring = SubscriptionOrbRing.From(entry);
        Color ringColor = RingColor(ring, entry.Provider);
        double center = Host / 2;

        // Selection halo (Swift: outer stroke ringColor 0.5 when selected).
        if (IsSelected)
        {
            AddCircle(center, HaloRadius, new SolidColorBrush(WithAlpha(ringColor, 0.50)), 1.5, dash: null);
        }

        // Track ring.
        AddCircle(center, RingRadius, new SolidColorBrush(Track), RingWidth, dash: null);

        // Fill ring — muted providers draw nothing over the track (ring reads as empty/dim).
        if (!ring.IsMuted)
        {
            double fraction = Math.Clamp(ring.RemainingFraction, 0, 1);
            if (fraction >= 0.999)
            {
                AddCircle(center, RingRadius, new SolidColorBrush(ringColor), RingWidth, dash: null);
            }
            else if (fraction > 0.001)
            {
                AddArc(center, RingRadius, fraction, RingWidth, new SolidColorBrush(ringColor));
            }
        }

        // Labels.
        NameText.Text = entry.DisplayName;
        NameText.FontWeight = IsSelected ? FontWeights.SemiBold : FontWeights.Normal;
        NameText.Foreground = new SolidColorBrush(IsSelected ? TextBright : Color.FromArgb(0xCC, 0xFF, 0xFF, 0xFF));
        PercentText.Text = entry.RemainingPercentText;
        PercentText.Foreground = new SolidColorBrush(ringColor);

        // Selection scale + dim (Swift: scaleEffect 1.04 when selected, opacity 0.38 when dimmed).
        RootScale.ScaleX = RootScale.ScaleY = IsSelected ? 1.04 : 1.0;
        Root.Opacity = IsDimmed ? 0.38 : 1.0;
    }

    private Color RingColor(SubscriptionOrbRing ring, AgentProviderBrand provider)
    {
        if (ring.IsMuted)
        {
            return Muted;
        }

        Color primary = ProviderBrand.Primary(provider);
        return ring.Band switch
        {
            QuotaFillBand.Wide => primary,
            QuotaFillBand.Comfortable => WithAlpha(primary, 0.78),
            QuotaFillBand.Narrowing => Amber,
            _ => Warning,
        };
    }

    private void AddCircle(double center, double radius, Brush stroke, double thickness, double[]? dash)
    {
        var ellipse = new Ellipse
        {
            Width = radius * 2,
            Height = radius * 2,
            Stroke = stroke,
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

        var figure = new PathFigure { StartPoint = new Point(startX, startY), IsClosed = false };
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
        });
    }

    private static Color WithAlpha(Color c, double alpha) =>
        Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), c.R, c.G, c.B);
}
