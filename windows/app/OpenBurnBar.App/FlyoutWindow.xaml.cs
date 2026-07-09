using System;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using OpenBurnBar.App.Cli;
using OpenBurnBar.App.Interop;
using OpenBurnBar.App.Shell;
using OpenBurnBar.App.Theme;
using Windows.Graphics;

namespace OpenBurnBar.App;

/// <summary>
/// Borderless, top-most, Liquid-Glass-backed flyout dropped from the tray — the Windows
/// analog of the macOS NSStatusItem + NSPopover. It hides on focus loss (transient popover
/// behavior), toggles from the tray primary click, is resizable (via the footer grip,
/// persisted), and hosts a reorderable module list.
/// </summary>
public sealed partial class FlyoutWindow : Window
{
    private const double DefaultWidth = 380;
    private const double DefaultHeight = 460;
    private const double MinWidth = 300;
    private const double MaxWidth = 640;
    private const double MinHeight = 320;
    private const double MaxHeight = 760;

    private readonly AppStatePersistence _persistence;
    private readonly AppWindow _appWindow;
    private readonly ICliStream _stream = CliStreamFactory.CreateDefault();

    private double _width;
    private double _height;
    private bool _isOpen;

    public FlyoutWindow(AppStatePersistence persistence)
    {
        _persistence = persistence;

        InitializeComponent();

        _width = Clamp(persistence.State.FlyoutWidth, MinWidth, MaxWidth, DefaultWidth);
        _height = Clamp(persistence.State.FlyoutHeight, MinHeight, MaxHeight, DefaultHeight);

        // Glass window backdrop through the Liquid Glass chokepoint (not ad-hoc TryApplyMica).
        LiquidGlass.ApplyWindowBackdrop(this, LiquidGlassEnvironment.Current);
        LiquidGlassWindowBlend.ApplyScrim(WindowBlendScrim, LiquidGlassEnvironment.Current);
        LiquidGlassEnvironment.PreferencesChanged += OnGlassPreferencesChanged;

        _appWindow = WindowChrome.GetAppWindow(this);
        WindowChrome.ConfigureAsFlyout(_appWindow);
        _appWindow.Hide();

        ViewModel = new FlyoutViewModel(persistence);
        ModulesList.ItemsSource = ViewModel.Modules;

        StreamView.Attach(_stream, autoStart: false);

        // Transient popover: dismiss when focus leaves the flyout.
        Activated += OnActivated;
        Closed += OnClosed;
    }

    /// <summary>The reorderable module list backing the flyout body.</summary>
    public FlyoutViewModel ViewModel { get; }

    /// <summary>Show the flyout at the tray corner if hidden; hide it if already shown.</summary>
    public void ToggleNearTray()
    {
        if (_isOpen)
        {
            Hide();
            return;
        }

        WindowChrome.MoveToTrayCorner(_appWindow, CurrentSize);
        _appWindow.Show();
        Activate();
        StreamView.StartIfIdle();
        _isOpen = true;
    }

    private SizeInt32 CurrentSize => new((int)Math.Round(_width), (int)Math.Round(_height));

    private void Hide()
    {
        _appWindow.Hide();
        _isOpen = false;
    }

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated && _isOpen)
        {
            Hide();
        }
    }

    private void OnGlassPreferencesChanged(object? sender, EventArgs e)
    {
        // Window SystemBackdrop is owned by ThemeService.Register (High Contrast /
        // ReduceTransparency override). Do NOT re-apply LiquidGlass.ApplyWindowBackdrop
        // here — that would override the accessibility gate. Only refresh the blend scrim.
        LiquidGlassWindowBlend.ApplyScrim(WindowBlendScrim, LiquidGlassEnvironment.Current);
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        LiquidGlassEnvironment.PreferencesChanged -= OnGlassPreferencesChanged;
        StreamView.Detach();
    }

    private void OpenFull_Click(object sender, RoutedEventArgs e)
    {
        Hide();
        App.Current.ShowMainWindowFromFlyout();
    }

    private void ModulesList_DragItemsCompleted(ListViewBase sender, DragItemsCompletedEventArgs args)
        => ViewModel.PersistOrder();

    private void ResizeGrip_DragDelta(object sender, DragDeltaEventArgs e)
    {
        _width = Clamp(_width + e.HorizontalChange, MinWidth, MaxWidth, _width);
        _height = Clamp(_height + e.VerticalChange, MinHeight, MaxHeight, _height);

        // Re-anchor at the tray corner so the flyout grows in place instead of drifting off-screen.
        WindowChrome.MoveToTrayCorner(_appWindow, CurrentSize);
    }

    private void ResizeGrip_DragCompleted(object sender, DragCompletedEventArgs e)
    {
        _persistence.State.FlyoutWidth = _width;
        _persistence.State.FlyoutHeight = _height;
        _persistence.Save();
    }

    private static double Clamp(double value, double min, double max, double fallback)
    {
        if (double.IsNaN(value) || value <= 0)
        {
            return fallback;
        }

        return Math.Max(min, Math.Min(max, value));
    }
}
