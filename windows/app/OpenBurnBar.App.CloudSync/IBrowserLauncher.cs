using System;
using OpenBurnBar.App.Configuration;

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
/// Launches the OS default browser through the reviewed child-process policy.
/// Windows activation uses <c>explorer.exe &lt;url&gt;</c> with a scrubbed
/// environment instead of shell execution from the OpenBurnBar process.
/// </summary>
public sealed class SystemBrowserLauncher : IBrowserLauncher
{
    public void Launch(Uri authorizationUrl)
    {
        if (authorizationUrl is null) throw new ArgumentNullException(nameof(authorizationUrl));
        ChildProcessLaunchPolicy.StartDefaultBrowser(authorizationUrl);
    }
}
