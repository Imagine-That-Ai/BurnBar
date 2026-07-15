using System;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

namespace OpenBurnBar.Pal.Ipc.Windows;

/// <summary>Stable per-user identity for the isolated desktop-input broker.</summary>
public static class PrivilegedInputBrokerEndpoint
{
    public const string SharedKeyName = "OpenBurnBar.PrivilegedInputBroker.PeerAuth.v1";

    public static string CurrentPipeName()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("The privileged-input broker is Windows-only.");
        }

        string sid = WindowsIdentity.GetCurrent().User?.Value
            ?? throw new InvalidOperationException("The current Windows SID is unavailable.");
        string digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sid)))
            .ToLowerInvariant();
        return "OpenBurnBar.PrivilegedInputBroker.v1." + digest[..16];
    }
}
