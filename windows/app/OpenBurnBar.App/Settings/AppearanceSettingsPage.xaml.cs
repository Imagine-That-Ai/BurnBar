// Code-behind for General → Appearance. Registers each anchored row under its
// SettingsAnchor id, then consumes the router's pending anchor on Loaded so a chosen
// search result scrolls straight to the exact control and pulses it.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Settings;

namespace OpenBurnBar.App.Settings.Winui;

public sealed partial class AppearanceSettingsPage : Page, ISettingsAnchorTarget
{
    private readonly SettingsAnchorScroller _scroller = new();
    private SettingsPageContext? _context;

    public AppearanceSettingsPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _context = e.Parameter as SettingsPageContext;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        RegisterAnchors();
        SettingsLeafPageSupport.ConsumePending(_context?.Router, _scroller);
    }

    public void ScrollToAnchor(string anchorId, string? focusId) => _scroller.ScrollTo(anchorId, focusId);

    private void RegisterAnchors()
    {
        _scroller.RegisterAnchor(SettingsAnchor.AppearanceTheme, ThemeCard);
        _scroller.RegisterAnchor(SettingsAnchor.AppearanceSkin, SkinCard);
        _scroller.RegisterAnchor(SettingsAnchor.AppearanceGlassTransparency, GlassCard);
        _scroller.RegisterAnchor(SettingsAnchor.AppearanceMenuBar, MenuBarCard);
        _scroller.RegisterAnchor(SettingsAnchor.AppearanceLaunchAtLogin, LaunchAtLoginCard);
        _scroller.RegisterAnchor(SettingsAnchor.UsePremiumSotaUx, PremiumSotaCard);
        _scroller.RegisterAnchor(SettingsAnchor.UseWebsiteBackground, SwarmBackgroundCard);
        _scroller.RegisterAnchor(SettingsAnchor.UseConstellationBackground, ConstellationCard);
        _scroller.RegisterAnchor(SettingsAnchor.UseKernelBackdrop, KernelBackdropCard);
        _scroller.RegisterAnchor(SettingsAnchor.BackdropKernel, BackdropKernelCard);
        _scroller.RegisterAnchor(SettingsAnchor.DesktopWallpaperEnabled, DesktopWallpaperExpander);
        _scroller.RegisterAnchor(SettingsAnchor.DesktopWallpaperBackground, WallpaperBackgroundCard);
        _scroller.RegisterAnchor(SettingsAnchor.DesktopWallpaperSpeed, WallpaperSpeedCard);
        _scroller.RegisterAnchor(SettingsAnchor.DesktopWallpaperProviderGlyphs, WallpaperGlyphsCard);
        _scroller.RegisterAnchor(SettingsAnchor.DesktopWallpaperClickCycle, WallpaperClickCycleCard);
    }
}
