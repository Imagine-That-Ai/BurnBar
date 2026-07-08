using System;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// The reason a desktop OAuth sign-in / refresh could not produce a Firebase id
/// token. Every value is <b>fail-closed</b>: the credentials provider surfaces it
/// as "not signed in", so the seam-ready surfaces
/// (<c>MissionDispatchHostFactory</c>, <c>QuotaAccountsSource</c>, …) fall back to
/// their honest empty/sample state rather than transmitting an unauthenticated
/// request.
/// </summary>
public enum DesktopOAuthFailure
{
    /// <summary>The user closed the browser / denied consent (<c>error=access_denied</c>).</summary>
    UserCancelled,

    /// <summary>No redirect arrived before the authorization timeout elapsed.</summary>
    Timeout,

    /// <summary>The authorization endpoint returned an <c>error=</c> on the redirect.</summary>
    AuthorizationError,

    /// <summary>A token / sign-in / refresh HTTP exchange returned a non-success status.</summary>
    TokenExchangeFailed,

    /// <summary>A response body was missing a required field or was not valid JSON.</summary>
    Malformed,

    /// <summary>The redirect <c>state</c> did not match the value we issued (CSRF guard).</summary>
    StateMismatch,

    /// <summary>The transport faulted (connection refused, DNS, TLS, …).</summary>
    Transport,

    /// <summary>No session exists yet (never signed in, or signed out) — credentials are unavailable.</summary>
    NotSignedIn,
}

/// <summary>
/// Fail-closed desktop-OAuth error. Carries a <see cref="Failure"/> classification
/// so callers can distinguish a user cancel from a transport fault while treating
/// all of them as "not signed in".
/// </summary>
public sealed class DesktopOAuthException : Exception
{
    public DesktopOAuthFailure Failure { get; }

    public DesktopOAuthException(DesktopOAuthFailure failure, string message, Exception? inner = null)
        : base(message, inner)
    {
        Failure = failure;
    }

    public static DesktopOAuthException UserCancelled(string message = "The user cancelled the sign-in.") =>
        new(DesktopOAuthFailure.UserCancelled, message);

    public static DesktopOAuthException Timeout(string message = "Timed out waiting for the sign-in redirect.") =>
        new(DesktopOAuthFailure.Timeout, message);

    public static DesktopOAuthException AuthorizationError(string error) =>
        new(DesktopOAuthFailure.AuthorizationError, $"Authorization endpoint returned error: {error}.");

    public static DesktopOAuthException TokenExchange(string stage, int status, string detail) =>
        new(DesktopOAuthFailure.TokenExchangeFailed, $"{stage} failed with HTTP {status}: {Trim(detail)}.");

    public static DesktopOAuthException Malformed(string stage, string detail) =>
        new(DesktopOAuthFailure.Malformed, $"{stage} returned a malformed response: {detail}.");

    public static DesktopOAuthException StateMismatch() =>
        new(DesktopOAuthFailure.StateMismatch, "The redirect state did not match the issued value (possible CSRF).");

    public static DesktopOAuthException Transport(string stage, Exception inner) =>
        new(DesktopOAuthFailure.Transport, $"{stage} transport fault: {inner.Message}.", inner);

    public static DesktopOAuthException NotSignedIn() =>
        new(DesktopOAuthFailure.NotSignedIn, "No desktop OAuth session; the user is not signed in.");

    private static string Trim(string detail) =>
        detail.Length <= 200 ? detail : detail[..200] + "…";
}
