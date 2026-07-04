using System;

namespace OpenBurnBar.Integrations.HomeAssistant.Rest;

// Granular Home Assistant response/error mapping.
//
// Parity: AgentLens/Services/HomeAssistant/HomeAssistantClient.swift
//   enum ClientError / enum ProbeStatus / probe(...) status switch /
//   ensureSuccess(response:data:path:).
//
// This is the PURE half of the REST client: given an HTTP status code + body,
// it produces either a success signal or a typed, user-actionable error — with
// NO dependency on any HTTP stack. The Windows adapter feeds it real
// HttpResponseMessage status/body; the macOS test host feeds it recorded
// fixtures. Keeping the mapping here means the actionable copy the recovery
// wizard shows is identical on every platform.

public enum HomeAssistantClientErrorKind
{
    InvalidUrl,
    Unauthorized,
    Forbidden,
    NotFound,
    RateLimited,
    Server,
    Transport,
    Decoding,
    MissingToken,
    Timeout,
}

/// Typed, equatable Home Assistant client error. Mirrors the Swift
/// `HomeAssistantClient.ClientError` including the `errorDescription` copy so
/// the wizard shows the same actionable message on Windows.
public sealed class HomeAssistantClientException : Exception, IEquatable<HomeAssistantClientException>
{
    public HomeAssistantClientErrorKind Kind { get; }

    /// For NotFound this is the path; for Server/Transport/Decoding it is the
    /// detail message. Empty otherwise.
    public string Detail { get; }

    /// HTTP status for the Server case; 0 otherwise.
    public int StatusCode { get; }

    private HomeAssistantClientException(HomeAssistantClientErrorKind kind, string detail, int statusCode)
        : base(Describe(kind, detail, statusCode))
    {
        Kind = kind;
        Detail = detail;
        StatusCode = statusCode;
    }

    public static HomeAssistantClientException InvalidUrl() => new(HomeAssistantClientErrorKind.InvalidUrl, string.Empty, 0);
    public static HomeAssistantClientException Unauthorized() => new(HomeAssistantClientErrorKind.Unauthorized, string.Empty, 0);
    public static HomeAssistantClientException Forbidden() => new(HomeAssistantClientErrorKind.Forbidden, string.Empty, 0);
    public static HomeAssistantClientException NotFound(string path) => new(HomeAssistantClientErrorKind.NotFound, path, 0);
    public static HomeAssistantClientException RateLimited() => new(HomeAssistantClientErrorKind.RateLimited, string.Empty, 0);
    public static HomeAssistantClientException Server(int code, string message) => new(HomeAssistantClientErrorKind.Server, message, code);
    public static HomeAssistantClientException Transport(string message) => new(HomeAssistantClientErrorKind.Transport, message, 0);
    public static HomeAssistantClientException Decoding(string message) => new(HomeAssistantClientErrorKind.Decoding, message, 0);
    public static HomeAssistantClientException MissingToken() => new(HomeAssistantClientErrorKind.MissingToken, string.Empty, 0);
    public static HomeAssistantClientException Timeout() => new(HomeAssistantClientErrorKind.Timeout, string.Empty, 0);

    private static string Describe(HomeAssistantClientErrorKind kind, string detail, int statusCode) => kind switch
    {
        HomeAssistantClientErrorKind.InvalidUrl => "Home Assistant URL is invalid.",
        HomeAssistantClientErrorKind.Unauthorized => "Home Assistant rejected the access token. Issue a new long-lived access token and paste it again.",
        HomeAssistantClientErrorKind.Forbidden => "Home Assistant blocked the request. The token may not have admin scope.",
        HomeAssistantClientErrorKind.NotFound => $"Home Assistant did not have an endpoint at {detail}.",
        HomeAssistantClientErrorKind.RateLimited => "Home Assistant is rate-limiting requests; try again in a moment.",
        HomeAssistantClientErrorKind.Server => $"Home Assistant returned HTTP {statusCode}: {detail}",
        HomeAssistantClientErrorKind.Transport => $"Could not reach Home Assistant: {detail}",
        HomeAssistantClientErrorKind.Decoding => $"Could not parse Home Assistant response: {detail}",
        HomeAssistantClientErrorKind.MissingToken => "Home Assistant is not connected. Paste your long-lived access token first.",
        HomeAssistantClientErrorKind.Timeout => "Home Assistant did not answer in time. Make sure it's reachable on this network.",
        _ => "Home Assistant error.",
    };

    public bool Equals(HomeAssistantClientException? other) =>
        other is not null && Kind == other.Kind && Detail == other.Detail && StatusCode == other.StatusCode;

    public override bool Equals(object? obj) => Equals(obj as HomeAssistantClientException);

    public override int GetHashCode() => HashCode.Combine(Kind, Detail, StatusCode);
}

/// Outcome of an unauthenticated probe of `/api/`. Mirrors the Swift
/// `HomeAssistantClient.ProbeStatus`.
public abstract record HomeAssistantProbeStatus
{
    /// `/api/` returned 200 or 401 (auth-required is enough to confirm HA is
    /// here) with an optional `X-HA-Version` header.
    public sealed record Ok(string? Version) : HomeAssistantProbeStatus;

    /// Base URL works but the token does not (currently unused by probe but
    /// kept for parity with the Swift enum surface).
    public sealed record Unauthorized : HomeAssistantProbeStatus;

    /// Host responded but the endpoint is not Home Assistant (404).
    public sealed record NoHomeAssistantHere : HomeAssistantProbeStatus;

    /// Transport or DNS error.
    public sealed record Unreachable(string Message) : HomeAssistantProbeStatus;
}

public static class HomeAssistantResponseMapper
{
    /// Maps a probe of `/api/` (status + optional X-HA-Version header) to a
    /// granular probe status. Parity with the Swift `probe(baseURL:)` switch:
    /// 401 and 2xx both confirm HA (with version if present), 404 means
    /// "not HA here", any other status is treated as OK with no version.
    public static HomeAssistantProbeStatus MapProbe(int statusCode, string? haVersionHeader)
    {
        if (statusCode == 401)
        {
            return new HomeAssistantProbeStatus.Ok(haVersionHeader);
        }
        if (statusCode >= 200 && statusCode < 300)
        {
            return new HomeAssistantProbeStatus.Ok(haVersionHeader);
        }
        if (statusCode == 404)
        {
            return new HomeAssistantProbeStatus.NoHomeAssistantHere();
        }
        return new HomeAssistantProbeStatus.Ok(null);
    }

    /// Throws the mapped typed error when the response is not a success.
    /// Parity with the Swift `ensureSuccess(response:data:path:)`:
    ///   2xx -> ok, 401 -> Unauthorized, 403 -> Forbidden, 404 -> NotFound(path),
    ///   429 -> RateLimited, else -> Server(code, first 160 chars of body).
    public static void EnsureSuccess(int statusCode, string? body, string path)
    {
        if (statusCode >= 200 && statusCode < 300)
        {
            return;
        }
        switch (statusCode)
        {
            case 401:
                throw HomeAssistantClientException.Unauthorized();
            case 403:
                throw HomeAssistantClientException.Forbidden();
            case 404:
                throw HomeAssistantClientException.NotFound(path);
            case 429:
                throw HomeAssistantClientException.RateLimited();
            default:
                var message = string.IsNullOrEmpty(body)
                    ? "no body"
                    : Truncate(body!, 160);
                throw HomeAssistantClientException.Server(statusCode, message);
        }
    }

    private static string Truncate(string value, int max) =>
        value.Length <= max ? value : value.Substring(0, max);
}
