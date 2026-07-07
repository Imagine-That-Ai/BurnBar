using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace OpenBurnBar.App.CursorConnector;

// ── Secret broker ────────────────────────────────────────────────────────────
//
// Faithful Windows peer of AgentLens/Services/CursorConnector/
// CursorConnectorManager+SecretBroker.swift. The broker is the loopback endpoint
// the proxy calls to resolve a per-route provider API key WITHOUT the key ever
// being written into the proxy's config file: the proxy presents a bearer token +
// a `/secret/<routeID>` path, and the broker maps routeID → keychain account →
// secret. The Mac binds this to an NWListener on a random loopback port; that
// transport is the deferred .Windows half. The PORTABLE, security-critical core —
// request parsing, constant bearer check, route resolution, the exact HTTP status
// contract (400/401/404/424/200) — lives here and is provable byte-for-byte.

/// <summary>Resolves per-route provider secrets over the loopback broker contract.</summary>
public sealed class CursorConnectorSecretBroker
{
    private readonly ISecretStore _secretStore;
    private readonly IReadOnlyDictionary<string, string> _routeAccounts;

    /// <summary>The bearer token every request must present (Swift <c>bearerToken</c>).</summary>
    public string BearerToken { get; }

    /// <summary>
    /// The loopback port the transport half bound to. Zero until the deferred
    /// .Windows listener starts; tests may set it to exercise <see cref="BaseUrlString"/>.
    /// </summary>
    public int Port { get; set; }

    /// <summary>Swift <c>baseURLString</c>.</summary>
    public string BaseUrlString => $"http://127.0.0.1:{Port}";

    /// <summary>Creates a broker over the given secret store and route→account map.</summary>
    public CursorConnectorSecretBroker(
        ISecretStore secretStore,
        IReadOnlyDictionary<string, string> routeAccounts,
        IRandomTokenSource? randomTokenSource = null)
    {
        _secretStore = secretStore ?? throw new ArgumentNullException(nameof(secretStore));
        _routeAccounts = routeAccounts ?? throw new ArgumentNullException(nameof(routeAccounts));
        BearerToken = RandomToken(randomTokenSource ?? SystemRandomTokenSource.Instance);
    }

    /// <summary>
    /// Swift <c>response(for:)</c> — the full request→response transform. Feed the
    /// raw request bytes; get the raw HTTP/1.1 response bytes.
    /// </summary>
    public byte[] ResponseFor(byte[]? requestData)
    {
        if (requestData is null || !TryDecodeUtf8(requestData, out var request))
        {
            return Http(400, ("error", "empty_request"));
        }

        var lines = request.Split(new[] { "\r\n" }, StringSplitOptions.None);
        if (lines.Length == 0)
        {
            return Http(400, ("error", "bad_request"));
        }

        var requestLine = lines[0];
        var parts = requestLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2)
        {
            return Http(400, ("error", "bad_request"));
        }

        var authHeader = lines.FirstOrDefault(
            line => line.ToLowerInvariant().StartsWith("authorization:", StringComparison.Ordinal)) ?? string.Empty;
        if (!string.Equals(authHeader, $"Authorization: Bearer {BearerToken}", StringComparison.Ordinal))
        {
            return Http(401, ("error", "unauthorized"));
        }

        var path = parts[1];
        const string prefix = "/secret/";
        if (!path.StartsWith(prefix, StringComparison.Ordinal))
        {
            return Http(404, ("error", "not_found"));
        }

        var routeId = path.Substring(prefix.Length);
        if (!_routeAccounts.TryGetValue(routeId, out var account))
        {
            return Http(404, ("error", "unknown_route"));
        }

        var secret = _secretStore.TryRead(account);
        var normalized = QuotaNonEmpty(secret);
        if (normalized is null)
        {
            return Http(424, ("error", "secret_unavailable"));
        }

        return Http(200, ("api_key", normalized));
    }

    /// <summary>Swift <c>http(status:body:)</c> — the exact wire response.</summary>
    public static byte[] Http(int status, params (string Key, string Value)[] body)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (key, value) in body)
        {
            map[key] = value;
        }

        var payload = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(map));
        var reason = status switch
        {
            200 => "OK",
            400 => "Bad Request",
            401 => "Unauthorized",
            404 => "Not Found",
            424 => "Failed Dependency",
            _ => "Error",
        };

        var header = new StringBuilder()
            .Append($"HTTP/1.1 {status} {reason}\r\n")
            .Append("Content-Type: application/json\r\n")
            .Append($"Content-Length: {payload.Length}\r\n")
            .Append("Connection: close\r\n\r\n")
            .ToString();

        return Encoding.UTF8.GetBytes(header).Concat(payload).ToArray();
    }

    /// <summary>Swift <c>quotaNonEmpty</c> — trim; empty becomes <c>null</c>.</summary>
    internal static string? QuotaNonEmpty(string? value)
    {
        if (value is null)
        {
            return null;
        }

        var trimmed = value.Trim();
        return trimmed.Length == 0 ? null : trimmed;
    }

    /// <summary>Swift <c>randomToken()</c> — 32 CSPRNG bytes as lowercase hex.</summary>
    private static string RandomToken(IRandomTokenSource randomTokenSource) =>
        HexToken.Encode(randomTokenSource.NextBytes(32));

    private static bool TryDecodeUtf8(byte[] data, out string text)
    {
        try
        {
            text = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true).GetString(data);
            return true;
        }
        catch (DecoderFallbackException)
        {
            text = string.Empty;
            return false;
        }
    }
}
