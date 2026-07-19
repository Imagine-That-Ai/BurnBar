using System;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.CloudSync.AppCheck.Attestation;
using OpenBurnBar.CloudSync.AppCheck.Mint;
using OpenBurnBar.CloudSync.AppCheck.Provider;
using OpenBurnBar.CloudSync.AppCheck.Token;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// Production composition for Desktop OAuth + App Check providers.
/// Wires real types when credentials/env are present; never uses silent sample auth.
/// </summary>
public static class CloudAuthProductionComposition
{
    public const string GoogleClientIdEnv = "OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID";
    public const string FirebaseApiKeyEnv = "OPENBURNBAR_FIREBASE_WEB_API_KEY";
    public const string AppCheckAppIdEnv = "OPENBURNBAR_APPCHECK_APP_ID";

    /// <summary>
    /// True when a provisioned App Check app id is available. Callers that only
    /// probe launch-time readiness can use this without weakening the production
    /// composition path, which validates the id again through
    /// <see cref="RequireAppCheckAppId"/>.
    /// </summary>
    public static bool IsAppCheckConfigured() =>
        !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(AppCheckAppIdEnv));

    public static string RequireAppCheckAppId()
    {
        string? appId = Environment.GetEnvironmentVariable(AppCheckAppIdEnv);
        if (string.IsNullOrWhiteSpace(appId))
        {
            throw new InvalidOperationException($"{AppCheckAppIdEnv} is required for production Windows sign-in.");
        }
        if (!appId.StartsWith("1:", StringComparison.Ordinal) ||
            !appId.Contains(":web:", StringComparison.Ordinal) ||
            appId.Contains("placeholder", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"{AppCheckAppIdEnv} must be a provisioned Firebase web app id.");
        }
        return appId;
    }

    /// <summary>True when Desktop OAuth client id + Firebase API key are configured.</summary>
    public static bool IsOAuthConfigured()
    {
        return !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(GoogleClientIdEnv))
            && !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(FirebaseApiKeyEnv));
    }

    /// <summary>
    /// Build a live <see cref="DesktopOAuthLoopbackFlow"/> when env credentials exist.
    /// Returns null when unconfigured (callers show honest empty/sign-in affordance).
    /// </summary>
    public static DesktopOAuthLoopbackFlow? TryCreateOAuthFlow(
        IBrowserLauncher? browser = null,
        IClock? clock = null)
    {
        if (!IsOAuthConfigured())
        {
            return null;
        }

        var options = new DesktopOAuthOptions
        {
            ClientId = Environment.GetEnvironmentVariable(GoogleClientIdEnv)!,
            FirebaseApiKey = Environment.GetEnvironmentVariable(FirebaseApiKeyEnv)!,
        };
        options.Validate();
        var http = new System.Net.Http.HttpClient
        {
            Timeout = TimeSpan.FromSeconds(options.HttpTimeoutSeconds),
        };
        return new DesktopOAuthLoopbackFlow(
            options,
            browser ?? new SystemBrowserLauncher(),
            new FirebaseIdentityClient(http, options),
            clock ?? SystemClock.Instance);
    }

    public static DesktopOAuthCredentialsProvider? TryCreateOAuthCredentialsProvider(
        IBrowserLauncher? browser = null,
        IClock? clock = null,
        IAppSecretStore? secretStore = null)
    {
        if (!IsOAuthConfigured())
        {
            return null;
        }

        var options = new DesktopOAuthOptions
        {
            ClientId = Environment.GetEnvironmentVariable(GoogleClientIdEnv)!,
            FirebaseApiKey = Environment.GetEnvironmentVariable(FirebaseApiKeyEnv)!,
        };
        options.Validate();
        var http = new System.Net.Http.HttpClient
        {
            Timeout = TimeSpan.FromSeconds(options.HttpTimeoutSeconds),
        };
        return DesktopOAuthCredentialsProvider.Create(
            options,
            http,
            browser,
            clock,
            new ProtectedFirebaseOAuthSessionStore(secretStore ?? AppConfiguration.Current.SecretStore));
    }

    /// <summary>
    /// Build <see cref="WindowsAppCheckProvider"/> with the given attestation producer
    /// and ID token source. Production Windows uses TPM producer; tests inject mocks.
    /// </summary>
    public static WindowsAppCheckProvider CreateAppCheckProvider(
        IAttestationProducer producer,
        IFirebaseIdTokenSource idTokenSource,
        AppCheckMintClient mintClient,
        string? appId = null)
    {
        string resolvedAppId = appId ?? RequireAppCheckAppId();
        var options = new AppCheckProviderOptions { AppId = resolvedAppId };
        return new WindowsAppCheckProvider(producer, mintClient, idTokenSource, options);
    }
}
