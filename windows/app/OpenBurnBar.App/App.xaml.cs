using System;
using Microsoft.UI.Xaml;
using System.Threading.Tasks;
using OpenBurnBar.App.Shell;
using OpenBurnBar.App.Theme;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Tray;

namespace OpenBurnBar.App;

/// <summary>
/// Application entry point for the OpenBurnBar Windows shell.
///
/// Menu-bar-first parity with the macOS app: launch installs a <c>Shell_NotifyIcon</c> tray
/// item (the <see cref="TrayIcon"/>, an NSStatusItem analog) and does NOT pop a main window.
/// Left-clicking the tray toggles the resizable/reorderable Mica flyout (<see cref="FlyoutWindow"/>,
/// the NSPopover analog); the tray context menu opens the full <see cref="MainWindow"/> (the
/// NavigationView app frame) or quits. A process-global Ctrl+K opens the Command Palette.
///
/// Shared services (appearance/theme + persisted UI state) are created once here and threaded
/// into every window.
/// </summary>
public partial class App : Application
{
    private readonly GlobalHotkeyService _hotkey = new();

    private AppStatePersistence? _state;
    private ThemeService? _theme;
    private TrayIcon? _tray;
    private MainWindow? _mainWindow;
    private FlyoutWindow? _flyout;
    private bool _hotkeyRegistered;

    public App()
    {
        AutomationLaunchOptions.Parse(Environment.CommandLine)?.ApplyEnvironment();
        AppDiagnostics.Install(this);
        InitializeComponent();
    }

    /// <summary>The single running app instance (WinUI has no typed Application.Current).</summary>
    public static new App Current => (App)Application.Current;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var automation = AutomationLaunchOptions.Parse(args.Arguments) ?? AutomationLaunchOptions.Parse(Environment.CommandLine);
        automation?.ApplyEnvironment();
        AppDiagnostics.LogEvent("launch", args.Arguments ?? string.Empty);
        WinAppCloudSyncHost.ConfigureFromAppConfiguration();
        Quota.Acquisition.Windows.WindowsQuotaAcquisitionHost.ConfigureDefault();
        _state = new AppStatePersistence();
        _theme = new ThemeService(_state);
        automation?.WriteLaunchMarker();

        if ((RouteSmokeOptions.Parse(args.Arguments) ?? RouteSmokeOptions.Parse(Environment.CommandLine)) is { } smoke)
        {
            AppDiagnostics.LogEvent("route-smoke.start", $"{smoke.RouteKey} -> {smoke.OutputDirectory}");
            StartRouteSmoke(smoke);
            return;
        }

        if (automation?.MainWindow == true)
        {
            ShowMainWindow();
            return;
        }

        // Windows are created eagerly but stay hidden — the tray owns visibility, exactly like
        // NSStatusItem owning the menu-bar popover on macOS.
        _flyout = new FlyoutWindow(State);
        _theme.Register(_flyout);

        // The flyout is the always-alive window, so anchor the global Ctrl+K hotkey there.
        _hotkeyRegistered = _hotkey.Register(_flyout, OpenCommandPalette);

        _tray = new TrayIcon(
            tooltip: "OpenBurnBar",
            onPrimaryClick: ToggleFlyout,
            onOpenMainWindow: ShowMainWindow,
            onExit: ExitApp);
        _tray.Show();
    }

    private void StartRouteSmoke(RouteSmokeOptions smoke)
    {
        _mainWindow = new MainWindow(_theme!);
        _mainWindow.Shell.CommandPaletteRequested += (_, _) => OpenCommandPalette();
        _mainWindow.Activate();
        _mainWindow.Shell.Navigate(smoke.RouteKey);
        _ = RouteSmokeHost.CaptureAndExitAsync(_mainWindow, smoke);
    }

    /// <summary>Open the full main window from the flyout's "Open full window" action.</summary>
    public void ShowMainWindowFromFlyout() => ShowMainWindow();

    private void ToggleFlyout()
    {
        _flyout ??= new FlyoutWindow(State);
        _flyout.ToggleNearTray();
    }

    private void ShowMainWindow()
    {
        if (_mainWindow is null)
        {
            _mainWindow = new MainWindow(_theme!);
            _mainWindow.Shell.CommandPaletteRequested += (_, _) => OpenCommandPalette();
            // Null the field when the user closes the window so a later open re-creates it.
            _mainWindow.Closed += (_, _) => _mainWindow = null;
        }

        _mainWindow.Activate();
    }

    /// <summary>Show the Command Palette over the main window (header button or Ctrl+K hotkey).</summary>
    private async void OpenCommandPalette()
    {
        try
        {
            // The palette is a ContentDialog and needs a live XamlRoot, so ensure the main window is up.
            ShowMainWindow();
            if (_mainWindow?.Content is not FrameworkElement root)
            {
                return;
            }

            var palette = new CommandPalette
            {
                XamlRoot = root.XamlRoot,
                RequestedTheme = root.RequestedTheme,
            };

            await palette.ShowAsync();

            if (palette.ChosenDestinationKey is { } key)
            {
                _mainWindow.Shell.Navigate(key);
            }
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("command-palette", ex);
        }
    }

    private void ExitApp()
    {
        if (_hotkeyRegistered)
        {
            _hotkey.Dispose();
            _hotkeyRegistered = false;
        }

        _tray?.Dispose();
        _tray = null;
        _flyout?.Close();
        _mainWindow?.Close();
        Exit();
    }

    private AppStatePersistence State =>
        _state ?? throw new InvalidOperationException("App state was requested before launch initialization completed.");
}
