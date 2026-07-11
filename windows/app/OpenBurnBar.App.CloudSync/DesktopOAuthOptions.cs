using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// Configuration for the desktop Firebase OAuth loopback flow. Every endpoint is
/// injectable so tests point the whole exchange at an in-process fake
/// authorization server (an <c>HttpListener</c>), while production defaults to the
/// standard Google + Firebase Identity Platform endpoints.
/// </summary>
/// <remarks>
/// The macOS oracle (<c>AgentLens/Services/Insights/MacFirebaseTokenProvider.swift</c>
/// + <c>AccountManager.swift</c>) delegates this entire dance to the FirebaseAuth /
/// GoogleSignIn Apple SDKs, so the Windows port re-implements the standard flow the
/// SDKs hide:
/// <list type="number">
///   <item>authorize (loopback + PKCE) at <see cref="AuthorizationEndpoint"/>,</item>
///   <item>exchange the code for Google tokens at <see cref="TokenEndpoint"/>,</item>
///   <item>trade the Google id token for a <b>Firebase</b> id token at
///         <see cref="FirebaseSignInEndpoint"/> (<c>accounts:signInWithIdp</c>),</item>
///   <item>refresh the Firebase id token at <see cref="FirebaseRefreshEndpoint"/>
///         (<c>securetoken</c>).</item>
/// </list>
/// The <b>Firebase</b> id token (steps 3/4) is what rides <c>Authorization: Bearer</c>
/// to Firestore + the App Check mint callable — not the raw Google token.
/// </remarks>
public sealed class DesktopOAuthOptions
{
    /// <summary>Google's OAuth 2.0 authorization endpoint (opens in the browser).</summary>
    public Uri AuthorizationEndpoint { get; init; } = new("https://accounts.google.com/o/oauth2/v2/auth");

    /// <summary>Google's OAuth 2.0 token endpoint (authorization-code + PKCE exchange).</summary>
    public Uri TokenEndpoint { get; init; } = new("https://oauth2.googleapis.com/token");

    /// <summary>Firebase Identity Toolkit <c>accounts:signInWithIdp</c> (Google id token → Firebase id token).</summary>
    public Uri FirebaseSignInEndpoint { get; init; } = new("https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp");

    /// <summary>Firebase <c>securetoken</c> refresh endpoint (refresh_token → new Firebase id token).</summary>
    public Uri FirebaseRefreshEndpoint { get; init; } = new("https://securetoken.googleapis.com/v1/token");

    /// <summary>The Google OAuth client id. Required.</summary>
    public string ClientId { get; init; } = string.Empty;

    /// <summary>The Google OAuth client secret (Desktop-type clients only; null for public clients relying on PKCE).</summary>
    public string? ClientSecret { get; init; }

    /// <summary>The Firebase Web API key (the <c>?key=</c> on the Identity Platform calls). Required.</summary>
    public string FirebaseApiKey { get; init; } = string.Empty;

    /// <summary>OAuth scopes requested at authorization time.</summary>
    public IReadOnlyList<string> Scopes { get; init; } = new[] { "openid", "email", "profile" };

    /// <summary>The Firebase IdP provider id (<c>google.com</c> for Google sign-in).</summary>
    public string ProviderId { get; init; } = "google.com";

    /// <summary>The loopback host the redirect binds to (<c>127.0.0.1</c> per RFC 8252 §7.3).</summary>
    public string LoopbackHost { get; init; } = "127.0.0.1";

    /// <summary>
    /// A fixed loopback port, or null to bind an OS-assigned ephemeral port. A
    /// desktop OAuth client with a registered <c>http://127.0.0.1</c> redirect
    /// accepts any port, so null is the norm; a fixed port aids a test's routing.
    /// </summary>
    public int? FixedRedirectPort { get; init; }

    /// <summary>How long to wait for the browser redirect before failing closed as <see cref="DesktopOAuthFailure.Timeout"/>.</summary>
    public TimeSpan AuthorizationTimeout { get; init; } = TimeSpan.FromMinutes(3);

    /// <summary>Refresh the cached id token this many millis before its expiry (mirrors the SDK's ~5-min lead).</summary>
    public long RefreshLeadMillis { get; init; } = 5 * 60 * 1000;

    /// <summary>Per-request HTTP timeout (seconds) for the token / sign-in / refresh exchanges.</summary>
    public double HttpTimeoutSeconds { get; init; } = 20.0;

    /// <summary>The HTML shown in the browser after a successful redirect capture.</summary>
    public string SuccessHtml { get; init; } =
        "<html><body style=\"font-family:sans-serif\"><h2>Signed in to OpenBurnBar</h2>" +
        "<p>You can close this window and return to the app.</p></body></html>";

    /// <summary>Throws when a required field is missing so misconfiguration fails fast at composition.</summary>
    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(ClientId))
        {
            throw new ArgumentException("DesktopOAuthOptions.ClientId is required.");
        }
        if (string.IsNullOrWhiteSpace(FirebaseApiKey))
        {
            throw new ArgumentException("DesktopOAuthOptions.FirebaseApiKey is required.");
        }
        if (RefreshLeadMillis < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(RefreshLeadMillis), RefreshLeadMillis, "Refresh lead must be non-negative.");
        }
        if (AuthorizationTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(AuthorizationTimeout), AuthorizationTimeout, "Authorization timeout must be positive.");
        }
        if (Scopes is null || Scopes.Count == 0)
        {
            throw new ArgumentException("DesktopOAuthOptions.Scopes must contain at least one scope.");
        }
    }
}
