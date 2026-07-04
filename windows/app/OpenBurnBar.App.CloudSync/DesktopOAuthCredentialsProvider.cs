using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// Desktop Firebase OAuth (browser loopback + id-token capture) is deferred to a follow-up wave.
/// Use <see cref="StaticCredentialsProvider"/> on the dev host until this type is implemented.
/// </summary>
public sealed class DesktopOAuthCredentialsProvider : ICloudSyncCredentialsProvider
{
    public Task<CloudSyncCredentials> GetCredentialsAsync(CancellationToken cancellationToken = default) =>
        throw new InvalidOperationException(
            "Desktop OAuth is not wired yet. Set OPENBURNBAR_FIREBASE_ID_TOKEN (and optional OPENBURNBAR_APP_CHECK_TOKEN) " +
            "and use CloudSyncCompositionRoot.CreateDevHost() with StaticCredentialsProvider.");
}