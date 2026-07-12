using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Theme;
using Windows.Foundation;
using Windows.UI;

namespace OpenBurnBar.App.Components;

/// <summary>
/// The battery-bar quota gauge. Windows peer of
/// <c>OpenBurnBarCore/.../UnifiedQuotaSignalView.swift</c>. Numeric text + the fraction/band come
/// from the parity-tested <see cref="QuotaBucket"/> / <see cref="QuotaFill"/> models; brand tints
/// come from <see cref="ProviderBrand"/>. Layout adapts to <see cref="Compact"/>.
/// </summary>
public sealed partial class UnifiedQuotaSignalView : UserControl
{
    // UnifiedDesignSystem.Colors.amber / .warning (dark) analogs.
    private static readonly Color AmberColor = Color.FromArgb(0xFF, 0xFB, 0xBF, 0x24);
    private static readonly Color WarningColor = Color.FromArgb(0xFF, 0xFB, 0x92, 0x3C);

    private double _fraction;

    public UnifiedQuotaSignalView()
    {
        InitializeComponent();
        Loaded += (_, _) => Rebuild();
    }

    /// <summary>The quota bucket to render. Swift: <c>bucket</c>.</summary>
    public QuotaBucket? Bucket
    {
        get => (QuotaBucket?)GetValue(BucketProperty);
        set => SetValue(BucketProperty, value);
    }

    public static readonly DependencyProperty BucketProperty = DependencyProperty.Register(
        nameof(Bucket), typeof(QuotaBucket), typeof(UnifiedQuotaSignalView),
        new PropertyMetadata(null, OnVisualChanged));

    /// <summary>The owning provider (drives brand tints). Swift: <c>provider</c>.</summary>
    public AgentProviderBrand Provider
    {
        get => (AgentProviderBrand)GetValue(ProviderProperty);
        set => SetValue(ProviderProperty, value);
    }

    public static readonly DependencyProperty ProviderProperty = DependencyProperty.Register(
        nameof(Provider), typeof(AgentProviderBrand), typeof(UnifiedQuotaSignalView),
        new PropertyMetadata(AgentProviderBrand.Factory, OnVisualChanged));

    /// <summary>Compact layout for tight strips. Swift: <c>compact</c>.</summary>
    public bool Compact
    {
        get => (bool)GetValue(CompactProperty);
        set => SetValue(CompactProperty, value);
    }

    public static readonly DependencyProperty CompactProperty = DependencyProperty.Register(
        nameof(Compact), typeof(bool), typeof(UnifiedQuotaSignalView),
        new PropertyMetadata(false, OnVisualChanged));

    /// <summary>Value formatting mode. Swift: <c>displayMode</c> (default "remainingPercent").</summary>
    public string DisplayMode
    {
        get => (string)GetValue(DisplayModeProperty);
        set => SetValue(DisplayModeProperty, value);
    }

    public static readonly DependencyProperty DisplayModeProperty = DependencyProperty.Register(
        nameof(DisplayMode), typeof(string), typeof(UnifiedQuotaSignalView),
        new PropertyMetadata("remainingPercent", OnVisualChanged));

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((UnifiedQuotaSignalView)d).Rebuild();

    private void Rebuild()
    {
        if (Container is null || Bucket is not { } bucket)
        {
            return;
        }

        Color primary = ProviderBrand.Primary(Provider);
        Color accent = ProviderBrand.Accent(Provider);

        _fraction = bucket.DisplayRemainingFraction ?? 0;
        QuotaFillBand band = QuotaFill.Band(_fraction);
        Color fill = FillColor(band, primary);
        QuotaSignalStatus status = QuotaSignalStatus.Resolve(_fraction);
        Color statusTint = TintFor(status.Tint, primary, accent);

        // Layout constants (Swift computed properties).
        bool compact = Compact;
        double batteryHeight = compact ? 28 : 36;
        double batteryRadius = compact ? 6 : 8;
        double terminalWidth = compact ? 4 : 5;
        double containerRadius = compact ? 14 : 16;

        Container.CornerRadius = new CornerRadius(containerRadius);
        Container.Background = ContainerGradient(primary);
        Container.BorderBrush = new SolidColorBrush(WithAlpha(primary, compact ? 0.14 : 0.18));
        Body.Spacing = compact ? 6 : 8;
        Container.Padding = new Thickness(compact ? 10 : 12);

        // Identity row.
        BucketName.Text = bucket.DisplayName;
        string? window = bucket.WindowLabel;
        if (window is { Length: > 0 })
        {
            WindowLabel.Text = window;
            WindowLabel.Foreground = new SolidColorBrush(WithAlpha(Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF), 0.55));
            WindowPill.BorderBrush = new SolidColorBrush(WithAlpha(primary, 0.18));
            WindowPill.Visibility = Visibility.Visible;
        }
        else
        {
            WindowPill.Visibility = Visibility.Collapsed;
        }

        PercentCompact.Text = bucket.RemainingPercentText;
        PercentCompact.Foreground = new SolidColorBrush(fill);
        PercentCompact.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;

        // Status row.
        StatusLabel.Text = status.Label.ToUpperInvariant();
        StatusLabel.Foreground = new SolidColorBrush(WithAlpha(statusTint, 0.86));
        RemainingCompact.Text = bucket.RemainingText(DisplayMode);
        RemainingCompact.Foreground = new SolidColorBrush(fill);
        RemainingCompact.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;

        // Status detail (non-compact only).
        StatusDetail.Text = status.Detail;
        StatusDetail.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;

        // Battery.
        BatteryTrackHost.Height = batteryHeight;
        BatteryTrack.CornerRadius = new CornerRadius(batteryRadius);
        BatteryTrack.Background = new SolidColorBrush(Color.FromArgb(0xBD, 0x00, 0x00, 0x00)); // black 0.74
        BatteryTrack.BorderBrush = new SolidColorBrush(WithAlpha(fill, 0.22));
        BatteryFill.CornerRadius = new CornerRadius(Math.Max(0, batteryRadius - 1.5));
        BatteryFill.Background = FillGradient(band, primary, accent);
        BatteryTerminal.Width = terminalWidth;
        BatteryTerminal.Height = batteryHeight * 0.38;
        BatteryTerminal.Background = new SolidColorBrush(WithAlpha(fill, 0.32));
        UpdateFillWidth();

        // Footer (non-compact only).
        FullRemaining.Text = bucket.FullRemainingText(DisplayMode);
        FullRemaining.Foreground = new SolidColorBrush(fill);
        UsageText.Text = bucket.UsageText;
        FooterRow.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;

        AutomationProperties.SetName(this, $"{ProviderMetadata.DisplayName(Provider)} quota: {bucket.FullRemainingText(DisplayMode)}");
    }

    private void OnTrackSizeChanged(object sender, SizeChangedEventArgs e) => UpdateFillWidth();

    private void UpdateFillWidth()
    {
        if (BatteryTrackHost is null || BatteryFill is null)
        {
            return;
        }

        double available = Math.Max(BatteryTrackHost.ActualWidth - 4, 0);
        BatteryFill.Width = _fraction > 0 ? available * _fraction : 0;
    }

    // MARK: color helpers (Swift fillColor / fillGradient / status tint)

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

    private static Brush ContainerGradient(Color primary)
    {
        var brush = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
        brush.GradientStops.Add(new GradientStop { Offset = 0, Color = Color.FromArgb(0xF5, 0x0A, 0x0A, 0x0E) });
        brush.GradientStops.Add(new GradientStop { Offset = 0.5, Color = Color.FromArgb(0xEB, 0x12, 0x12, 0x1A) });
        brush.GradientStops.Add(new GradientStop { Offset = 1, Color = WithAlpha(primary, 0.06) });
        return brush;
    }

    private static Color TintFor(QuotaTintRole role, Color primary, Color accent) => role switch
    {
        QuotaTintRole.Warning => WarningColor,
        QuotaTintRole.Amber => AmberColor,
        QuotaTintRole.ThemeAccent => accent,
        _ => primary,
    };

    private static Color WithAlpha(Color c, double alpha) =>
        Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), c.R, c.G, c.B);
}
