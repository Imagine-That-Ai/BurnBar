using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Interop;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.SharedUi;
using OpenBurnBar.App.Shell;
using OpenBurnBar.App.Theme;
using OpenBurnBar.App.UsageRuntime;

namespace OpenBurnBar.App;

/// <summary>
/// The full OpenBurnBar window (opened from the tray). Liquid-Glass backed via
/// <see cref="LiquidGlass.ApplyWindowBackdrop"/>. Content: the shared Linux desktop UI in a
/// WebView2 (<see cref="SharedUiHost"/>) so Windows and Linux render the identical frontend —
/// set <c>OPENBURNBAR_XAML_SHELL=1</c> to fall back to the native XAML <see cref="AppShell"/>.
/// The appearance follows the shared <see cref="ThemeService"/>.
/// </summary>
public sealed partial class MainWindow : Window
{
    private readonly ThemeService _theme;
    private readonly AppShell? _xamlShell;

    public MainWindow(
        ThemeService theme,
        IUsageRuntime? usageRuntime = null,
        LocalHttpGatewayHost? gateway = null,
        string? gatewayToken = null,
        bool forceXamlShell = false)
    {
        _theme = theme;
        InitializeComponent();

        var appWindow = WindowChrome.GetAppWindow(this);
        appWindow.Resize(new Windows.Graphics.SizeInt32(1040, 720));

        // Custom draggable title bar (WinUI window-level title-bar API).
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);

        if (forceXamlShell ||
            string.Equals(Environment.GetEnvironmentVariable("OPENBURNBAR_XAML_SHELL"), "1", StringComparison.Ordinal))
        {
            _xamlShell = new AppShell();
            ContentHost.Children.Add(_xamlShell);
            _xamlShell.BindTheme(theme);
            _xamlShell.BindUsageRuntime(usageRuntime);
        }
        else
        {
            ContentHost.Children.Add(new SharedUiHost(theme, usageRuntime, gateway, gatewayToken));
        }

        // Glass window backdrop + blend scrim through the single Liquid Glass chokepoint.
        ApplyGlassChrome();
        LiquidGlassEnvironment.PreferencesChanged += OnGlassPreferencesChanged;

        theme.Register(this);

        Closed += OnClosed;
    }

    /// <summary>The native XAML app frame when OPENBURNBAR_XAML_SHELL=1; null under the shared UI.</summary>
    public AppShell? Shell => _xamlShell;

    private void ApplyGlassChrome()
    {
        LiquidGlass.ApplyWindowBackdrop(this, LiquidGlassEnvironment.Current);
        LiquidGlassWindowBlend.ApplyScrim(WindowBlendScrim, LiquidGlassEnvironment.Current);
    }

    private void OnGlassPreferencesChanged(object? sender, EventArgs e)
    {
        // ThemeService.Register already re-applies backdrop on Changed; also refresh the scrim.
        LiquidGlassWindowBlend.ApplyScrim(WindowBlendScrim, LiquidGlassEnvironment.Current);
        if (_theme.Mode.AllowsBackdrop() && !_theme.EffectiveReduceTransparency)
        {
            LiquidGlass.ApplyWindowBackdrop(this, LiquidGlassEnvironment.Current);
        }
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        LiquidGlassEnvironment.PreferencesChanged -= OnGlassPreferencesChanged;
        Closed -= OnClosed;
    }
}
