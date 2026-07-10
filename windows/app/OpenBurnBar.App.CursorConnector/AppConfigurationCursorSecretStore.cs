using System;
using OpenBurnBar.App.Configuration;

namespace OpenBurnBar.App.CursorConnector;

/// <summary>Cursor provider-secret adapter over the app-wide protected store.</summary>
public sealed class AppConfigurationCursorSecretStore : ISecretStore
{
    private readonly IAppSecretStore _secrets;

    public AppConfigurationCursorSecretStore(IAppSecretStore secrets)
    {
        _secrets = secrets ?? throw new ArgumentNullException(nameof(secrets));
    }

    public string? TryRead(string account) => _secrets.Read(account);

    public void Set(string account, string value) => _secrets.Write(account, value);

    public void Delete(string account) => _secrets.Delete(account);
}
