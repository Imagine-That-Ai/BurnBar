using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using OpenBurnBar.App.Cli;
using OpenBurnBar.App.Interop;
using Windows.Graphics;

namespace OpenBurnBar.App;

/// <summary>
/// Borderless, top-most, Mica-backed flyout dropped from the tray — the Windows analog of
/// the macOS NSStatusItem + NSPopover. It hides when it loses focus (transient popover
/// behavior) and toggles open/closed from the tray's primary click.
/// </summary>
public sealed partial class FlyoutWindow : Window
{
    private static readonly SizeInt32 FlyoutSize = new(380, 460);

    private readonly AppWindow _appWindow;
    private readonly StubCliStream _stream = new();
    private bool _isOpen;

    public FlyoutWindow()
    {
        InitializeComponent();

        WindowChrome.TryApplyMica(this);
        _appWindow = WindowChrome.GetAppWindow(this);
        WindowChrome.ConfigureAsFlyout(_appWindow);
        _appWindow.Hide();

        StreamView.Attach(_stream, autoStart: false);

        // Transient popover: dismiss when focus leaves the flyout.
        Activated += OnActivated;
        Closed += (_, _) => StreamView.Detach();
    }

    /// <summary>Show the flyout at the tray corner if hidden; hide it if already shown.</summary>
    public void ToggleNearTray()
    {
        if (_isOpen)
        {
            Hide();
            return;
        }

        WindowChrome.MoveToTrayCorner(_appWindow, FlyoutSize);
        _appWindow.Show();
        Activate();
        StreamView.StartIfIdle();
        _isOpen = true;
    }

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

    private void OpenFull_Click(object sender, RoutedEventArgs e)
    {
        Hide();
        App.Current.ShowMainWindowFromFlyout();
    }
}
