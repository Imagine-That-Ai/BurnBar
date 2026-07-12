using System;
using OpenBurnBar.App.Configuration;

namespace OpenBurnBar.Integrations.HomeAssistant.Stores;

/// <summary>Home Assistant token-store adapter over the app-wide protected store.</summary>
public sealed class AppConfigurationHomeAssistantSecretStore : IHomeAssistantSecretStore
{
    private readonly IAppSecretStore _secrets;

    public AppConfigurationHomeAssistantSecretStore(IAppSecretStore secrets)
    {
        _secrets = secrets ?? throw new ArgumentNullException(nameof(secrets));
    }

    public string? GetSecret(string account) => _secrets.Read(account);

    public void SetSecret(string account, string value) => _secrets.Write(account, value);

    public void DeleteSecret(string account) => _secrets.Delete(account);
}
