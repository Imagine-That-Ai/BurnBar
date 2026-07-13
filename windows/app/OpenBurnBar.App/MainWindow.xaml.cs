using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Interop;
using OpenBurnBar.App.Shell;
using OpenBurnBar.App.Theme;
using OpenBurnBar.App.UsageRuntime;

namespace OpenBurnBar.App;

/// <summary>
/// The full OpenBurnBar window (opened from the tray). Liquid-Glass backed via
/// <see cref="LiquidGlass.ApplyWindowBackdrop"/>, with a custom draggable title bar
/// hosting the <see cref="AppShell"/> NavigationView app frame — the Windows analog
/// of the macOS NavigationSplitView. The appearance follows the shared <see cref="ThemeService"/>.
/// </summary>
public sealed partial class MainWindow : Window
{
    private readonly ThemeService _theme;

    public MainWindow(ThemeService theme, IUsageRuntime? usageRuntime = null)
    {
        _theme = theme;
        InitializeComponent();

        var appWindow = WindowChrome.GetAppWindow(this);
        appWindow.Resize(new Windows.Graphics.SizeInt32(1040, 720));

        // Custom draggable title bar (WinUI window-level title-bar API).
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);

        // Glass window backdrop + blend scrim through the single Liquid Glass chokepoint.
        ApplyGlassChrome();
        LiquidGlassEnvironment.PreferencesChanged += OnGlassPreferencesChanged;

        // Wire the shell's Appearance flyout to the shared theme service, then let the theme
        // service own this window's element theme + backdrop (Mica vs solid).
        ShellControl.BindTheme(theme);
        ShellControl.BindUsageRuntime(usageRuntime);
        theme.Register(this);

        Closed += OnClosed;
    }

    /// <summary>The NavigationView app frame, exposed so the app can drive palette navigation.</summary>
    public AppShell Shell => ShellControl;

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
