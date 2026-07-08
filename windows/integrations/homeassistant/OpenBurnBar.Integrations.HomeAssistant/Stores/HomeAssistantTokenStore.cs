using System;

namespace OpenBurnBar.Integrations.HomeAssistant.Stores;

// HA secret storage seam.
//
// Parity: AgentLens/Services/HomeAssistant/HomeAssistantTokenStore.swift
//   protocol HomeAssistantTokenStoring + struct HomeAssistantTokenStore
//   (KeychainStore-backed) + final class InMemoryHomeAssistantTokenStore.
//
// The HA long-lived access token + webhook secret are password-class secrets:
// on Windows they belong in DPAPI/CNG-backed secure storage (the PAL's secret
// store), never in the JSON config. This interface is the seam the Windows
// adapter binds to that store; the in-memory implementation backs tests.

/// Backing key/value secret store (the PAL secret store on Windows).
public interface IHomeAssistantSecretStore
{
    string? GetSecret(string account);
    void SetSecret(string account, string value);
    void DeleteSecret(string account);
}

public interface IHomeAssistantTokenStore
{
    string? LoadAccessToken();
    void SaveAccessToken(string token);
    void DeleteAccessToken();

    string? LoadWebhookSecret();
    void SaveWebhookSecret(string secret);
    void DeleteWebhookSecret();
}

/// Canonical HA secret account identifiers (mirrors the Swift
/// OpenBurnBarIdentity.homeAssistant* account names).
public static class HomeAssistantSecretAccounts
{
    public const string AccessToken = "homeAssistantAccessToken";
    public const string WebhookSecret = "homeAssistantWebhookSecret";
}

/// Secret-store-backed token store. Empty input deletes (parity with Swift's
/// trim-then-delete-on-empty behavior).
public sealed class HomeAssistantTokenStore : IHomeAssistantTokenStore
{
    private readonly IHomeAssistantSecretStore _secrets;

    public HomeAssistantTokenStore(IHomeAssistantSecretStore secrets)
    {
        _secrets = secrets ?? throw new ArgumentNullException(nameof(secrets));
    }

    public string? LoadAccessToken() => _secrets.GetSecret(HomeAssistantSecretAccounts.AccessToken);

    public void SaveAccessToken(string token)
    {
        var trimmed = token.Trim();
        if (trimmed.Length == 0)
        {
            DeleteAccessToken();
        }
        else
        {
            _secrets.SetSecret(HomeAssistantSecretAccounts.AccessToken, trimmed);
        }
    }

    public void DeleteAccessToken() => _secrets.DeleteSecret(HomeAssistantSecretAccounts.AccessToken);

    public string? LoadWebhookSecret() => _secrets.GetSecret(HomeAssistantSecretAccounts.WebhookSecret);

    public void SaveWebhookSecret(string secret)
    {
        var trimmed = secret.Trim();
        if (trimmed.Length == 0)
        {
            DeleteWebhookSecret();
        }
        else
        {
            _secrets.SetSecret(HomeAssistantSecretAccounts.WebhookSecret, trimmed);
        }
    }

    public void DeleteWebhookSecret() => _secrets.DeleteSecret(HomeAssistantSecretAccounts.WebhookSecret);
}

/// In-memory token store for tests. Parity: Swift InMemoryHomeAssistantTokenStore
/// (empty -> nil).
public sealed class InMemoryHomeAssistantTokenStore : IHomeAssistantTokenStore
{
    private readonly object _gate = new();
    private string? _token;
    private string? _webhook;

    public string? LoadAccessToken() { lock (_gate) { return _token; } }

    public void SaveAccessToken(string token)
    {
        lock (_gate) { _token = token.Length == 0 ? null : token; }
    }

    public void DeleteAccessToken() { lock (_gate) { _token = null; } }

    public string? LoadWebhookSecret() { lock (_gate) { return _webhook; } }

    public void SaveWebhookSecret(string secret)
    {
        lock (_gate) { _webhook = secret.Length == 0 ? null : secret; }
    }

    public void DeleteWebhookSecret() { lock (_gate) { _webhook = null; } }
}
