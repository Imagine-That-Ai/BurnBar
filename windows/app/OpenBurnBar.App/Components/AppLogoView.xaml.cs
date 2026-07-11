using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Components;

/// <summary>
/// OpenBurnBar brand mark from the app asset (<c>AppLogo</c>). Windows peer of
/// <c>AgentLens/Views/Components/AppLogoView.swift</c>. Set <see cref="Size"/> to size it
/// (default 24), mirroring the SwiftUI <c>size</c> parameter.
/// </summary>
public sealed partial class AppLogoView : UserControl
{
    public AppLogoView()
    {
        InitializeComponent();
    }

    /// <summary>Edge length of the square logo, in DIPs. Swift: <c>AppLogoView.size</c>.</summary>
    public double Size
    {
        get => (double)GetValue(SizeProperty);
        set => SetValue(SizeProperty, value);
    }

    public static readonly DependencyProperty SizeProperty = DependencyProperty.Register(
        nameof(Size), typeof(double), typeof(AppLogoView),
        new PropertyMetadata(24.0, OnSizeChanged));

    private static void OnSizeChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var view = (AppLogoView)d;
        double size = (double)e.NewValue;
        view.LogoImage.Width = size;
        view.LogoImage.Height = size;
    }
}
