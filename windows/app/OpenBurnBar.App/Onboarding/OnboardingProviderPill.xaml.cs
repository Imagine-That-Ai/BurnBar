using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Theme;
using Windows.UI;

namespace OpenBurnBar.App.Onboarding;

/// <summary>
/// Provider selection pill. Windows peer of <c>OnboardingProviderPill.swift</c>: a
/// brand-colored badge + display name in a capsule, toggled by tap, with selected +
/// detected visual states applied from code. Brand color comes from the parity-tested
/// <see cref="ProviderBrand"/> table.
/// </summary>
public sealed partial class OnboardingProviderPill : UserControl
{
    private AgentProviderBrand _provider;
    private bool _isSelected;

    public OnboardingProviderPill()
    {
        InitializeComponent();
    }

    /// <summary>Raised when the pill is tapped — the host toggles the model's selection.</summary>
    public event EventHandler? Toggled;

    /// <summary>The provider this pill represents.</summary>
    public AgentProviderBrand Provider => _provider;

    /// <summary>Populate the pill and apply its initial visual state.</summary>
    public void Configure(AgentProviderBrand provider, string displayName, bool isSelected, bool isDetected)
    {
        _provider = provider;
        NameText.Text = displayName;
        AutomationProperties.SetName(this, displayName);
        DetectedDot.Visibility = isDetected ? Visibility.Visible : Visibility.Collapsed;
        LogoBadge.Background = new SolidColorBrush(ProviderBrand.Primary(provider));
        SetSelected(isSelected);
    }

    /// <summary>Apply the selected/unselected look (Swift: brand tint fill + 0.6 stroke at
    /// 1.5px when selected, else the neutral surface + 0.5px stroke).</summary>
    public void SetSelected(bool selected)
    {
        _isSelected = selected;
        Color brand = ProviderBrand.Primary(_provider);

        if (selected)
        {
            PillBorder.Background = new SolidColorBrush(WithAlpha(brand, 0x1A));   // ~0.10
            PillBorder.BorderBrush = new SolidColorBrush(WithAlpha(brand, 0x99));  // ~0.60
            PillBorder.BorderThickness = new Thickness(1.5);
        }
        else
        {
            PillBorder.Background = ResourceBrush("OBBSurfaceBrush");
            PillBorder.BorderBrush = ResourceBrush("OBBStrokeBrush");
            PillBorder.BorderThickness = new Thickness(0.5);
        }

        AutomationProperties.SetHelpText(this, selected ? "Selected" : "Not selected");
    }

    private void OnTapped(object sender, TappedRoutedEventArgs e) =>
        Toggled?.Invoke(this, EventArgs.Empty);

    private void OnPointerEntered(object sender, PointerRoutedEventArgs e) =>
        PillBorder.Opacity = 0.88;

    private void OnPointerExited(object sender, PointerRoutedEventArgs e) =>
        PillBorder.Opacity = 1.0;

    private static Color WithAlpha(Color color, byte alpha) =>
        Color.FromArgb(alpha, color.R, color.G, color.B);

    private static Brush ResourceBrush(string key) =>
        (Brush)Application.Current.Resources[key];
}
