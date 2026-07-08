using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace OpenBurnBar.App.Components;

/// <summary>
/// A quota source/confidence capsule. Windows peer of the <c>QuotaSourceBadge</c> in
/// <c>ProviderQuotaStripViews.swift</c>. The label text is <see cref="QuotaFill.SourceLabel"/>;
/// the tint is chosen from <see cref="QuotaConfidence"/> (Swift: the <c>foreground</c> switch).
/// </summary>
public sealed partial class QuotaSourceBadge : UserControl
{
    // DesignSystem.Colors.success / .warning / .textMuted (dark) analogs.
    private static readonly Color SuccessColor = Color.FromArgb(0xFF, 0x30, 0xD1, 0x58);
    private static readonly Color WarningColor = Color.FromArgb(0xFF, 0xFF, 0x9F, 0x0A);
    private static readonly Color MutedColor = Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF);

    public QuotaSourceBadge()
    {
        InitializeComponent();
        Rebuild();
    }

    /// <summary>The quota provenance. Swift: <c>QuotaSourceBadge.source</c>.</summary>
    public QuotaSourceKind Source
    {
        get => (QuotaSourceKind)GetValue(SourceProperty);
        set => SetValue(SourceProperty, value);
    }

    public static readonly DependencyProperty SourceProperty = DependencyProperty.Register(
        nameof(Source), typeof(QuotaSourceKind), typeof(QuotaSourceBadge),
        new PropertyMetadata(QuotaSourceKind.Unavailable, OnVisualChanged));

    /// <summary>Confidence in the reading. Swift: <c>QuotaSourceBadge.confidence</c>.</summary>
    public QuotaConfidence Confidence
    {
        get => (QuotaConfidence)GetValue(ConfidenceProperty);
        set => SetValue(ConfidenceProperty, value);
    }

    public static readonly DependencyProperty ConfidenceProperty = DependencyProperty.Register(
        nameof(Confidence), typeof(QuotaConfidence), typeof(QuotaSourceBadge),
        new PropertyMetadata(QuotaConfidence.Unavailable, OnVisualChanged));

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((QuotaSourceBadge)d).Rebuild();

    private void Rebuild()
    {
        if (Label is null)
        {
            return;
        }

        Color foreground = Confidence switch
        {
            QuotaConfidence.Exact => SuccessColor,
            QuotaConfidence.Estimated => WarningColor,
            _ => MutedColor,
        };

        Label.Text = QuotaFill.SourceLabel(Source);
        Label.Foreground = new SolidColorBrush(foreground);
        Capsule.Background = new SolidColorBrush(WithAlpha(foreground, 0.08));
        Capsule.BorderBrush = new SolidColorBrush(WithAlpha(foreground, 0.14));
    }

    private static Color WithAlpha(Color c, double alpha) =>
        Color.FromArgb((byte)(alpha * 255), c.R, c.G, c.B);
}
