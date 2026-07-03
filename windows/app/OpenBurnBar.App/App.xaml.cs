using Microsoft.UI.Xaml;
using OpenBurnBar.App.Tray;

namespace OpenBurnBar.App;

/// <summary>
/// Application entry point for the OpenBurnBar Windows shell spike.
///
/// Menu-bar-first parity with the macOS app: launch installs a <c>Shell_NotifyIcon</c>
/// tray item (the <see cref="TrayIcon"/>, an NSStatusItem analog) and does NOT pop a
/// main window. Left-clicking the tray toggles the borderless Mica flyout
/// (<see cref="FlyoutWindow"/>, the NSPopover analog); the tray context menu opens the
/// full <see cref="MainWindow"/> or quits.
/// </summary>
public partial class App : Application
{
    private TrayIcon? _tray;
    private MainWindow? _mainWindow;
    private FlyoutWindow? _flyout;

    public App()
    {
        InitializeComponent();
    }

    /// <summary>The single running app instance (WinUI has no typed Application.Current).</summary>
    public static new App Current => (App)Application.Current;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Windows are created eagerly but stay hidden — the tray owns visibility,
        // exactly like NSStatusItem owning the menu-bar popover on macOS.
        _flyout = new FlyoutWindow();

        _tray = new TrayIcon(
            tooltip: "OpenBurnBar",
            onPrimaryClick: ToggleFlyout,
            onOpenMainWindow: ShowMainWindow,
            onExit: ExitApp);
        _tray.Show();
    }

    /// <summary>Open the full main window from the flyout's "Open full window" action.</summary>
    public void ShowMainWindowFromFlyout() => ShowMainWindow();

    private void ToggleFlyout()
    {
        _flyout ??= new FlyoutWindow();
        _flyout.ToggleNearTray();
    }

    private void ShowMainWindow()
    {
        if (_mainWindow is null)
        {
            _mainWindow = new MainWindow();
            // Null the field when the user closes the window so a later open re-creates it.
            _mainWindow.Closed += (_, _) => _mainWindow = null;
        }

        _mainWindow.Activate();
    }

    private void ExitApp()
    {
        _tray?.Dispose();
        _tray = null;
        _flyout?.Close();
        _mainWindow?.Close();
        Exit();
    }
}
