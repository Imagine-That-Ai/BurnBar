using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.AppCheck.Attestation;
using OpenBurnBar.CloudSync.AppCheck.Token;

namespace OpenBurnBar.CloudSync.AppCheck.Mint;

/// <summary>
/// Portable mint client: encodes the Firebase callable request for
/// <c>mintWindowsAppCheckToken</c>, sends it through the injected transport, and
/// decodes the callable response into an <see cref="AppCheckToken"/>. It owns the
/// entire wire contract and fails CLOSED on every non-success outcome.
/// </summary>
/// <remarks>
/// Firebase v2 <c>onCall</c> wire protocol:
/// <list type="bullet">
///   <item>Request: <c>POST</c> with <c>Authorization: Bearer &lt;idToken&gt;</c>,
///   <c>Content-Type: application/json</c>, body <c>{ "data": &lt;payload&gt; }</c>.</item>
///   <item>Success: HTTP 200, body <c>{ "result": &lt;result&gt; }</c>.</item>
///   <item>Error: an <c>{ "error": { status, message } }</c> envelope.</item>
/// </list>
/// The payload is <c>{ attestation: { kind, appId, nonce, issuedAtMs, mac }, ttlMillis? }</c>
/// — exactly what the server's handler reads. There is NO App Check header on this
/// call: it is the bootstrap that MINTS App Check, so it cannot demand one
/// (<c>enforceAppCheck: false</c> server-side); the gate is the attestation verifier.
/// </remarks>
public sealed class AppCheckMintClient
{
    private readonly AppCheckMintEndpoint _endpoint;
    private readonly IAppCheckMintTransport _transport;
    private readonly double _timeoutSeconds;

    public AppCheckMintClient(
        AppCheckMintEndpoint endpoint,
        IAppCheckMintTransport transport,
        double timeoutSeconds = 20.0)
    {
        _endpoint = endpoint ?? throw new ArgumentNullException(nameof(endpoint));
        _transport = transport ?? throw new ArgumentNullException(nameof(transport));
        if (timeoutSeconds <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(timeoutSeconds), timeoutSeconds, "Timeout must be positive.");
        }
        _timeoutSeconds = timeoutSeconds;
    }

    /// <summary>
    /// Exchange an attestation claim for an installed App Check token.
    /// </summary>
    /// <param name="claim">The attestation claim to present.</param>
    /// <param name="idToken">A non-empty Firebase ID token for the bearer header.</param>
    /// <param name="nowMillis">Clock reading stamped as the token's <see cref="AppCheckToken.MintedAtMs"/>.</param>
    /// <param name="ttlMillisRequest">Optional requested TTL (server clamps to 30 min .. 7 days).</param>
    /// <exception cref="AppCheckMintException">Thrown fail-closed on any non-success outcome.</exception>
    public async Task<AppCheckToken> MintAsync(
        WindowsAttestationClaim claim,
        string idToken,
        long nowMillis,
        long? ttlMillisRequest = null,
        CancellationToken cancellationToken = default)
    {
        if (claim is null) throw new ArgumentNullException(nameof(claim));
        if (string.IsNullOrEmpty(idToken))
        {
            // Defense in depth — the provider fail-closes earlier, but never send
            // an unauthenticated mint.
            throw AppCheckMintException.MissingIdToken();
        }

        var body = EncodeRequestBody(claim, ttlMillisRequest);
        var request = new AppCheckMintHttpRequest(
            Method: "POST",
            Url: _endpoint.Url.ToString(),
            Headers: new List<AppCheckMintHeader>
            {
                new("Authorization", $"Bearer {idToken}"),
                new("Content-Type", "application/json"),
                new("Accept", "application/json"),
            },
            Body: body,
            TimeoutSeconds: _timeoutSeconds);

        var response = await _transport.SendAsync(request, cancellationToken).ConfigureAwait(false);
        return DecodeResponse(response, nowMillis);
    }

    private static byte[] EncodeRequestBody(WindowsAttestationClaim claim, long? ttlMillisRequest)
    {
        using var stream = new System.IO.MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WritePropertyName("data");
            writer.WriteStartObject();

            writer.WritePropertyName("attestation");
            writer.WriteStartObject();
            writer.WriteString("kind", claim.Kind);
            writer.WriteString("appId", claim.AppId);
            writer.WriteString("nonce", claim.Nonce);
            writer.WriteNumber("issuedAtMs", claim.IssuedAtMs);
            writer.WriteString("mac", claim.Mac);
            writer.WriteEndObject();

            if (ttlMillisRequest.HasValue)
            {
                writer.WriteNumber("ttlMillis", ttlMillisRequest.Value);
            }

            writer.WriteEndObject(); // data
            writer.WriteEndObject(); // root
        }
        return stream.ToArray();
    }

    private static AppCheckToken DecodeResponse(AppCheckMintHttpResponse response, long nowMillis)
    {
        // Fail closed on any non-2xx: a Firebase callable also returns a JSON
        // `error` envelope on failure, but the status alone is authoritative here.
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(string.IsNullOrEmpty(response.Body) ? "{}" : response.Body);
        }
        catch (JsonException ex)
        {
            throw AppCheckMintException.Malformed($"non-JSON body ({ex.Message})");
        }

        using (document)
        {
            var root = document.RootElement;

            if (response.StatusCode is < 200 or >= 300)
            {
                var detail = ExtractErrorMessage(root) ?? Truncate(response.Body);
                throw AppCheckMintException.Rejected(response.StatusCode, detail);
            }

            // Even on HTTP 200 a callable may carry an `error` envelope; treat it as rejection.
            if (root.ValueKind == JsonValueKind.Object &&
                root.TryGetProperty("error", out var errorElement) &&
                errorElement.ValueKind == JsonValueKind.Object)
            {
                throw AppCheckMintException.Rejected(
                    response.StatusCode,
                    ExtractErrorMessage(root) ?? "callable error envelope");
            }

            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("result", out var result) ||
                result.ValueKind != JsonValueKind.Object)
            {
                throw AppCheckMintException.Malformed("missing `result` object");
            }

            if (!result.TryGetProperty("ok", out var ok) ||
                ok.ValueKind != JsonValueKind.True)
            {
                throw AppCheckMintException.Rejected(response.StatusCode, "server did not confirm ok=true");
            }

            var token = ReadNonEmptyString(result, "appCheckToken");
            var appId = ReadNonEmptyString(result, "appId");
            var ttlMillis = ReadPositiveLong(result, "ttlMillis");

            return new AppCheckToken
            {
                Token = token,
                TtlMillis = ttlMillis,
                AppId = appId,
                MintedAtMs = nowMillis,
            };
        }
    }

    private static string ReadNonEmptyString(JsonElement obj, string name)
    {
        if (!obj.TryGetProperty(name, out var element) ||
            element.ValueKind != JsonValueKind.String)
        {
            throw AppCheckMintException.Malformed($"missing/invalid string `{name}`");
        }
        var value = element.GetString();
        if (string.IsNullOrEmpty(value))
        {
            throw AppCheckMintException.Malformed($"empty `{name}`");
        }
        return value;
    }

    private static long ReadPositiveLong(JsonElement obj, string name)
    {
        if (!obj.TryGetProperty(name, out var element) ||
            element.ValueKind != JsonValueKind.Number ||
            !element.TryGetInt64(out var value) ||
            value <= 0)
        {
            throw AppCheckMintException.Malformed($"missing/invalid positive number `{name}`");
        }
        return value;
    }

    private static string? ExtractErrorMessage(JsonElement root)
    {
        if (root.ValueKind == JsonValueKind.Object &&
            root.TryGetProperty("error", out var error) &&
            error.ValueKind == JsonValueKind.Object &&
            error.TryGetProperty("message", out var message) &&
            message.ValueKind == JsonValueKind.String)
        {
            return message.GetString();
        }
        return null;
    }

    private static string Truncate(string body)
    {
        if (string.IsNullOrEmpty(body)) return "(empty body)";
        return body.Length <= 256 ? body : body.Substring(0, 256) + "…";
    }
}
