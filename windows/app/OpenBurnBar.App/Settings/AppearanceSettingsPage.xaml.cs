// Code-behind for General → Appearance. Registers each anchored row under its
// SettingsAnchor id, then consumes the router's pending anchor on Loaded so a chosen
// search result scrolls straight to the exact control and pulses it.
// Liquid Glass Transparency + kernel backdrop bind to LiquidGlassEnvironment.Current.

using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Dashboard;
using OpenBurnBar.App.Settings;
using OpenBurnBar.App.Theme;

namespace OpenBurnBar.App.Settings.Winui;

public sealed partial class AppearanceSettingsPage : Page, ISettingsAnchorTarget
{
    private readonly SettingsAnchorScroller _scroller = new();
    private SettingsPageContext? _context;
    private bool _suppressHandlers;

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
        PopulateKernelCombo();
        LoadGlassPreferences();
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

    private void PopulateKernelCombo()
    {
        _suppressHandlers = true;
        KernelCombo.Items.Clear();
        string selected = LiquidGlassEnvironment.Current.GetString(
            KernelBackdropPreferences.KernelKey, KernelCatalog.DefaultId);
        int selectIndex = 0;
        for (int i = 0; i < KernelCatalog.All.Count; i++)
        {
            var entry = KernelCatalog.All[i];
            KernelCombo.Items.Add(new ComboBoxItem
            {
                Content = entry.Label,
                Tag = entry.Id,
            });
            if (string.Equals(entry.Id, selected, StringComparison.Ordinal))
            {
                selectIndex = i;
            }
        }

        KernelCombo.SelectedIndex = selectIndex;
        _suppressHandlers = false;
    }

    private void LoadGlassPreferences()
    {
        _suppressHandlers = true;
        var env = LiquidGlassEnvironment.Current;

        // Slider is −100…+100 UI for t ∈ [−1, 1].
        GlassSlider.Value = env.RawTransparency * 100.0;
        UpdateGlassLabel(env.RawTransparency);

        ContentSurfacesToggle.IsOn = env.ContentSurfacesEnabled;
        KernelEnabledToggle.IsOn = env.GetBool(KernelBackdropPreferences.EnabledKey, false);
        KernelCombo.IsEnabled = KernelEnabledToggle.IsOn;

        _suppressHandlers = false;
    }

    private void GlassSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_suppressHandlers)
        {
            return;
        }

        double t = e.NewValue / 100.0;
        LiquidGlassEnvironment.Current.RawTransparency = t;
        UpdateGlassLabel(t);
    }

    private void ContentSurfacesToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_suppressHandlers)
        {
            return;
        }

        LiquidGlassEnvironment.Current.ContentSurfacesEnabled = ContentSurfacesToggle.IsOn;
    }

    private void KernelEnabledToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_suppressHandlers)
        {
            return;
        }

        LiquidGlassEnvironment.Current.SetBool(KernelBackdropPreferences.EnabledKey, KernelEnabledToggle.IsOn);
        KernelCombo.IsEnabled = KernelEnabledToggle.IsOn;
    }

    private void KernelCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressHandlers)
        {
            return;
        }

        if (KernelCombo.SelectedItem is ComboBoxItem { Tag: string id })
        {
            LiquidGlassEnvironment.Current.SetString(KernelBackdropPreferences.KernelKey, KernelCatalog.Resolve(id));
        }
    }

    private void ThemeCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // Appearance mode is owned by ThemeService via AppearanceModeControl in the shell flyout;
        // this combo is a visual peer — leave ThemeService as source of truth for now.
    }

    private void UpdateGlassLabel(double t)
    {
        if (Math.Abs(t) < 0.02)
        {
            GlassValueLabel.Text = "System";
        }
        else if (t > 0)
        {
            GlassValueLabel.Text = $"Clearer  {t:0.00}";
        }
        else
        {
            GlassValueLabel.Text = $"Frostier  {t:0.00}";
        }
    }
}
