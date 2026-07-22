using OpenBurnBar.App.CloudSync;
using OpenBurnBar.CloudSync.AppCheck.Net;
using OpenBurnBar.CloudSync.AppCheck.Windows;

namespace OpenBurnBar.App;

/// <summary>
/// Registers the real Windows App Check adapters only for an explicitly
/// configured staging environment. Without the app-id switch, OAuth remains
/// usable as an id-token-only path; with it, the TPM producer and HTTP mint
/// transport are composed together and any TPM/mint failure blocks the request.
/// </summary>
internal static class WindowsAppCheckComposition
{
    public static void RegisterIfConfigured()
    {
        if (!CloudAuthProductionComposition.IsAppCheckConfigured())
        {
            return;
        }

        WinAppCloudSyncHost.ConfigurePlatformAppCheck(
            static () => new TpmAttestationProducer(),
            static () => new HttpClientAppCheckMintTransport());
    }
}
