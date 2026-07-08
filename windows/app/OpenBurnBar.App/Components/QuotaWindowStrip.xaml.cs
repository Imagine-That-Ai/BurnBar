using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Theme;
using Windows.Foundation;
using Windows.UI;

namespace OpenBurnBar.App.Components;

/// <summary>
/// A compact two-window quota strip (short slot 5h/24h, long slot 7d/30d). Windows peer of
/// <c>QuotaDualWindowStrip</c> in <c>ProviderQuotaStripViews.swift</c>. Slot selection, labels,
/// fractions, and fill bands come from the parity-tested <see cref="QuotaBucket"/> /
/// <see cref="QuotaFill"/>; brand tints from <see cref="ProviderBrand"/>.
/// </summary>
public sealed partial class QuotaWindowStrip : UserControl
{
    private static readonly Color AmberColor = Color.FromArgb(0xFF, 0xFB, 0xBF, 0x24);
    private static readonly Color WarningColor = Color.FromArgb(0xFF, 0xFB, 0x92, 0x3C);
    private static readonly Color NegativeSpace = Color.FromArgb(0xBD, 0x00, 0x00, 0x00); // black 0.74

    private double _shortFraction;
    private double _longFraction;

    public QuotaWindowStrip()
    {
        InitializeComponent();
        Loaded += (_, _) => Rebuild();
    }

    /// <summary>The 5h/hourly window, if present. Swift: <c>hourlyBucket</c>.</summary>
    public QuotaBucket? HourlyBucket
    {
        get => (QuotaBucket?)GetValue(HourlyBucketProperty);
        set => SetValue(HourlyBucketProperty, value);
    }

    public static readonly DependencyProperty HourlyBucketProperty = DependencyProperty.Register(
        nameof(HourlyBucket), typeof(QuotaBucket), typeof(QuotaWindowStrip),
        new PropertyMetadata(null, OnVisualChanged));

    /// <summary>The 7d/weekly window, if present. Swift: <c>weeklyBucket</c>.</summary>
    public QuotaBucket? WeeklyBucket
    {
        get => (QuotaBucket?)GetValue(WeeklyBucketProperty);
        set => SetValue(WeeklyBucketProperty, value);
    }

    public static readonly DependencyProperty WeeklyBucketProperty = DependencyProperty.Register(
        nameof(WeeklyBucket), typeof(QuotaBucket), typeof(QuotaWindowStrip),
        new PropertyMetadata(null, OnVisualChanged));

    /// <summary>A fallback window used when hourly/weekly are missing. Swift: <c>fallbackBucket</c>.</summary>
    public QuotaBucket? FallbackBucket
    {
        get => (QuotaBucket?)GetValue(FallbackBucketProperty);
        set => SetValue(FallbackBucketProperty, value);
    }

    public static readonly DependencyProperty FallbackBucketProperty = DependencyProperty.Register(
        nameof(FallbackBucket), typeof(QuotaBucket), typeof(QuotaWindowStrip),
        new PropertyMetadata(null, OnVisualChanged));

    /// <summary>The owning provider (drives brand tints). Swift: <c>provider</c>.</summary>
    public AgentProviderBrand Provider
    {
        get => (AgentProviderBrand)GetValue(ProviderProperty);
        set => SetValue(ProviderProperty, value);
    }

    public static readonly DependencyProperty ProviderProperty = DependencyProperty.Register(
        nameof(Provider), typeof(AgentProviderBrand), typeof(QuotaWindowStrip),
        new PropertyMetadata(AgentProviderBrand.Factory, OnVisualChanged));

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((QuotaWindowStrip)d).Rebuild();

    /// <summary>Short slot: prefer the hourly bucket; else a daily fallback. Swift: <c>shortSlotBucket</c>.</summary>
    private QuotaBucket? ShortSlot()
    {
        if (HourlyBucket is not null)
        {
            return HourlyBucket;
        }

        if (FallbackBucket is { } fb && fb.WindowKind == QuotaWindowKind.Daily)
        {
            return fb;
        }

        return null;
    }

    /// <summary>Long slot: prefer the weekly bucket; else the fallback. Swift: <c>longSlotBucket</c>.</summary>
    private QuotaBucket? LongSlot() => WeeklyBucket ?? FallbackBucket;

    private void Rebuild()
    {
        if (Container is null)
        {
            return;
        }

        Color primary = ProviderBrand.Primary(Provider);

        Container.BorderBrush = new SolidColorBrush(WithAlpha(primary, 0.14));

        _shortFraction = ConfigureRow(ShortSlot(), "5h", ShortLabel, ShortRemaining, ShortTrack, ShortFill, primary);
        _longFraction = ConfigureRow(LongSlot(), "7d", LongLabel, LongRemaining, LongTrack, LongFill, primary);
        UpdateFill(ShortTrackHost, ShortFill, _shortFraction);
        UpdateFill(LongTrackHost, LongFill, _longFraction);
    }

    private double ConfigureRow(
        QuotaBucket? bucket, string defaultLabel,
        TextBlock label, TextBlock remaining, Border track, Border fill, Color primary)
    {
        Color accent = ProviderBrand.Accent(Provider);

        if (bucket is null)
        {
            label.Text = defaultLabel;
            remaining.Text = "—";
            remaining.Foreground = new SolidColorBrush(WithAlpha(Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF), 0.55));
            track.Background = new SolidColorBrush(NegativeSpace);
            track.BorderBrush = new SolidColorBrush(WithAlpha(primary, 0.08));
            fill.Width = 0;
            return 0;
        }

        double fraction = bucket.DisplayRemainingFraction ?? 0;
        QuotaFillBand band = QuotaFill.Band(fraction);
        Color fillColor = FillColor(band, primary);

        label.Text = LabelFor(bucket.WindowKind, defaultLabel);
        remaining.Text = bucket.RemainingText();
        remaining.Foreground = new SolidColorBrush(fillColor);
        track.Background = new SolidColorBrush(NegativeSpace);
        track.BorderBrush = new SolidColorBrush(WithAlpha(fillColor, 0.18));
        fill.Background = FillGradient(band, primary, accent);
        return fraction;
    }

    private static string LabelFor(QuotaWindowKind kind, string defaultLabel) => kind switch
    {
        QuotaWindowKind.RollingHours => "5h",
        QuotaWindowKind.Daily => "24h",
        QuotaWindowKind.Weekly => "7d",
        QuotaWindowKind.RollingDays => "7d",
        QuotaWindowKind.Monthly => "30d",
        QuotaWindowKind.Lifetime => "All",
        _ => defaultLabel,
    };

    private void OnShortTrackSizeChanged(object sender, SizeChangedEventArgs e) =>
        UpdateFill(ShortTrackHost, ShortFill, _shortFraction);

    private void OnLongTrackSizeChanged(object sender, SizeChangedEventArgs e) =>
        UpdateFill(LongTrackHost, LongFill, _longFraction);

    private static void UpdateFill(Grid host, Border fill, double fraction)
    {
        if (host is null || fill is null)
        {
            return;
        }

        fill.Height = host.ActualHeight;
        fill.Width = fraction > 0 ? host.ActualWidth * fraction : 0;
    }

    private static Color FillColor(QuotaFillBand band, Color primary) => band switch
    {
        QuotaFillBand.Wide => primary,
        QuotaFillBand.Comfortable => WithAlpha(primary, 0.72),
        QuotaFillBand.Narrowing => AmberColor,
        _ => WarningColor,
    };

    private static Brush FillGradient(QuotaFillBand band, Color primary, Color accent)
    {
        (Color a, Color b) = band switch
        {
            QuotaFillBand.Wide => (primary, accent),
            QuotaFillBand.Comfortable => (WithAlpha(primary, 0.72), WithAlpha(accent, 0.56)),
            QuotaFillBand.Narrowing => (WithAlpha(primary, 0.48), AmberColor),
            _ => (AmberColor, WarningColor),
        };

        var brush = new LinearGradientBrush { StartPoint = new Point(0, 0.5), EndPoint = new Point(1, 0.5) };
        brush.GradientStops.Add(new GradientStop { Offset = 0, Color = a });
        brush.GradientStops.Add(new GradientStop { Offset = 1, Color = b });
        return brush;
    }

    private static Color WithAlpha(Color c, double alpha) =>
        Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), c.R, c.G, c.B);
}
