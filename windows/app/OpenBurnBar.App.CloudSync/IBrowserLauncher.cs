using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// Opens the system browser at the authorization URL. Abstracted so tests inject a
/// launcher that captures the URL (and drives the loopback redirect itself)
/// instead of spawning a real browser.
/// </summary>
public interface IBrowserLauncher
{
    void Launch(Uri authorizationUrl);
}

/// <summary>
/// Launches the OS default browser. Uses <see cref="ProcessStartInfo.UseShellExecute"/>
/// on Windows/macOS and falls back to <c>xdg-open</c> on Linux, so the same portable
/// assembly opens a browser on every desktop target.
/// </summary>
public sealed class SystemBrowserLauncher : IBrowserLauncher
{
    public void Launch(Uri authorizationUrl)
    {
        if (authorizationUrl is null) throw new ArgumentNullException(nameof(authorizationUrl));
        string url = authorizationUrl.ToString();

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            return;
        }
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            Process.Start("open", url);
            return;
        }
        // Linux / other X11 desktops.
        Process.Start("xdg-open", url);
    }
}
