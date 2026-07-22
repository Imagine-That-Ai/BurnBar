using System;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

namespace OpenBurnBar.Pal.Ipc.Windows;

/// <summary>Stable per-user identity for the privileged-input watchdog channel.</summary>
public static class PrivilegedInputWatchdogEndpoint
{
    public const string SharedKeyName = "OpenBurnBar.PrivilegedInputWatchdog.PeerAuth.v1";
    public const string ExpectedPublisherSubject =
        "CN=Imagine That AI LLC, O=Imagine That AI LLC, L=Little Rock, S=Arkansas, C=US";

    public static string CurrentPipeName()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("The privileged-input watchdog is Windows-only.");
        }

        string sid = WindowsIdentity.GetCurrent().User?.Value
            ?? throw new InvalidOperationException("The current Windows SID is unavailable.");
        string digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sid)))
            .ToLowerInvariant();
        return "OpenBurnBar.PrivilegedInputWatchdog.v1." + digest[..16];
    }
}
