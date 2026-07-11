using System.Collections.Generic;
using OpenBurnBar.CloudSync.AppCheck.Provider;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// Wraps a base id-token provider and attaches App Check via <see cref="WindowsAppCheckProvider"/> (fail-closed).
/// </summary>
public sealed class AppCheckCredentialsProvider : ICloudSyncCredentialsProvider
{
    private readonly ICloudSyncCredentialsProvider _inner;
    private readonly WindowsAppCheckProvider? _appCheck;

    public AppCheckCredentialsProvider(ICloudSyncCredentialsProvider inner, WindowsAppCheckProvider? appCheck)
    {
        _inner = inner ?? throw new ArgumentNullException(nameof(inner));
        _appCheck = appCheck;
    }

    public async Task<CloudSyncCredentials> GetCredentialsAsync(CancellationToken cancellationToken = default)
    {
        CloudSyncCredentials baseCreds = await _inner.GetCredentialsAsync(cancellationToken).ConfigureAwait(false);
        if (_appCheck is null)
        {
            return baseCreds;
        }

        var headers = new Dictionary<string, string>(StringComparer.Ordinal);
        AppCheckDecision decision = await _appCheck.AuthorizeRequestAsync(headers, cancellationToken).ConfigureAwait(false);
        if (!decision.IsAttached || decision.Token is null)
        {
            throw new InvalidOperationException(
                decision.BlockReason ?? "App Check token unavailable; request blocked (fail-closed).");
        }

        return baseCreds with { AppCheckToken = decision.Token.Token };
    }
}