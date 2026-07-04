using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// Dev-host credentials until desktop OAuth lands (see <see cref="DesktopOAuthCredentialsProvider"/>).
/// </summary>
public sealed class StaticCredentialsProvider : ICloudSyncCredentialsProvider
{
    private readonly Func<Task<CloudSyncCredentials>> _resolve;

    public StaticCredentialsProvider(CloudSyncCredentials credentials) =>
        _resolve = () => Task.FromResult(credentials);

    public StaticCredentialsProvider(Func<Task<CloudSyncCredentials>> resolve) =>
        _resolve = resolve ?? throw new ArgumentNullException(nameof(resolve));

    public Task<CloudSyncCredentials> GetCredentialsAsync(CancellationToken cancellationToken = default) =>
        _resolve();
}