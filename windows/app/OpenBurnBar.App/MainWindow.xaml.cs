using Microsoft.UI.Xaml;
using OpenBurnBar.App.Cli;
using OpenBurnBar.App.Interop;

namespace OpenBurnBar.App;

/// <summary>
/// The full OpenBurnBar window (opened from the tray context menu). Mica-backed, with a
/// draggable custom header, hosting the live CLI stream at full size. The stream is fed
/// by a <see cref="StubCliStream"/> — WINUI-017 swaps in the real ConPTY-backed source.
/// </summary>
public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();

        WindowChrome.TryApplyMica(this);

        var appWindow = WindowChrome.GetAppWindow(this);
        appWindow.Resize(new Windows.Graphics.SizeInt32(880, 620));

        // Custom draggable header (WinUI window-level title-bar API).
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(HeaderBar);

        // Auto-start the stub stream so the window shows live output immediately.
        StreamView.Attach(new StubCliStream(), autoStart: true);

        Closed += (_, _) => StreamView.Detach();
    }
}
