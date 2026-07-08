using System;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using OpenBurnBar.App.Theme;
using Windows.UI;

namespace OpenBurnBar.App.Components;

/// <summary>
/// A provider's logo, preferring the bundled asset and falling back to a branded Segoe glyph.
/// Windows peer of <c>ProviderLogoView.swift</c> + <c>UnifiedProviderLogoView.swift</c>. Solid-dark
/// logos get a light backdrop disc (<see cref="ProviderMetadata.NeedsMonochromeLogoBackdrop"/>).
/// </summary>
public sealed partial class ProviderLogoView : UserControl
{
    public ProviderLogoView()
    {
        InitializeComponent();
        Loaded += (_, _) => Rebuild();
    }

    /// <summary>The provider whose logo to show. Swift: <c>provider</c>.</summary>
    public AgentProviderBrand Provider
    {
        get => (AgentProviderBrand)GetValue(ProviderProperty);
        set => SetValue(ProviderProperty, value);
    }

    public static readonly DependencyProperty ProviderProperty = DependencyProperty.Register(
        nameof(Provider), typeof(AgentProviderBrand), typeof(ProviderLogoView),
        new PropertyMetadata(AgentProviderBrand.Factory, OnVisualChanged));

    /// <summary>Edge length in DIPs. Swift: <c>size</c> (default 24).</summary>
    public double LogoSize
    {
        get => (double)GetValue(LogoSizeProperty);
        set => SetValue(LogoSizeProperty, value);
    }

    public static readonly DependencyProperty LogoSizeProperty = DependencyProperty.Register(
        nameof(LogoSize), typeof(double), typeof(ProviderLogoView),
        new PropertyMetadata(24.0, OnVisualChanged));

    /// <summary>Tint the fallback glyph with the provider's brand color. Swift: <c>useFallbackColor</c>.</summary>
    public bool UseFallbackColor
    {
        get => (bool)GetValue(UseFallbackColorProperty);
        set => SetValue(UseFallbackColorProperty, value);
    }

    public static readonly DependencyProperty UseFallbackColorProperty = DependencyProperty.Register(
        nameof(UseFallbackColor), typeof(bool), typeof(ProviderLogoView),
        new PropertyMetadata(true, OnVisualChanged));

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((ProviderLogoView)d).Rebuild();

    private void Rebuild()
    {
        if (ClipBorder is null)
        {
            return;
        }

        double size = LogoSize;
        double radius = size * ProviderMetadata.LogoCornerRadiusFactor;

        Width = size;
        Height = size;
        ClipBorder.Width = size;
        ClipBorder.Height = size;
        ClipBorder.CornerRadius = new CornerRadius(radius);

        // Dark-first shell: decide the light-disc backdrop treatment.
        bool needsBackdrop = ProviderMetadata.NeedsMonochromeLogoBackdrop(Provider, isDark: true);
        Backdrop.CornerRadius = new CornerRadius(radius);
        Backdrop.Background = new SolidColorBrush(Color.FromArgb(0xEB, 0xFF, 0xFF, 0xFF)); // white 0.92
        Backdrop.BorderBrush = new SolidColorBrush(Color.FromArgb(0x0F, 0x00, 0x00, 0x00)); // black 0.06
        Backdrop.Visibility = needsBackdrop ? Visibility.Visible : Visibility.Collapsed;
        Logo.Margin = needsBackdrop ? new Thickness(size * 0.08) : new Thickness(0);

        // Prefer the bundled asset; ImageFailed swaps in the glyph fallback.
        string asset = ProviderMetadata.BundledLogoName(Provider);
        Logo.Visibility = Visibility.Visible;
        Fallback.Visibility = Visibility.Collapsed;
        try
        {
            Logo.Source = new BitmapImage(new Uri($"ms-appx:///Assets/ProviderLogos/{asset}.png"));
        }
        catch (Exception)
        {
            ShowFallback();
        }

        // Prepare the fallback glyph up front so ImageFailed just flips visibility.
        Fallback.Glyph = ProviderMetadata.FallbackGlyph(Provider);
        Fallback.FontSize = size * 0.6;
        Fallback.Foreground = UseFallbackColor
            ? new SolidColorBrush(ProviderBrand.Primary(Provider))
            : new SolidColorBrush(Colors.White);
    }

    private void OnImageFailed(object sender, ExceptionRoutedEventArgs e) => ShowFallback();

    private void OnImageOpened(object sender, RoutedEventArgs e)
    {
        Logo.Visibility = Visibility.Visible;
        Fallback.Visibility = Visibility.Collapsed;
    }

    private void ShowFallback()
    {
        Logo.Visibility = Visibility.Collapsed;
        Fallback.Visibility = Visibility.Visible;
    }
}
