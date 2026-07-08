using Microsoft.UI.Xaml;
using OpenBurnBar.App.Interop;
using OpenBurnBar.App.Shell;
using OpenBurnBar.App.Theme;

namespace OpenBurnBar.App;

/// <summary>
/// The full OpenBurnBar window (opened from the tray). Mica-backed, with a custom draggable
/// title bar hosting the <see cref="AppShell"/> NavigationView app frame — the Windows analog
/// of the macOS NavigationSplitView. The appearance follows the shared <see cref="ThemeService"/>.
/// </summary>
public sealed partial class MainWindow : Window
{
    public MainWindow(ThemeService theme)
    {
        InitializeComponent();

        var appWindow = WindowChrome.GetAppWindow(this);
        appWindow.Resize(new Windows.Graphics.SizeInt32(1040, 720));

        // Custom draggable title bar (WinUI window-level title-bar API).
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);

        // Wire the shell's Appearance flyout to the shared theme service, then let the theme
        // service own this window's element theme + backdrop (Mica vs solid).
        ShellControl.BindTheme(theme);
        theme.Register(this);
    }

    /// <summary>The NavigationView app frame, exposed so the app can drive palette navigation.</summary>
    public AppShell Shell => ShellControl;
}
