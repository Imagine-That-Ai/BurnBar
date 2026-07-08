using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.Gateway;
using OpenBurnBar.CloudSync.Json;

namespace OpenBurnBar.CloudSync.Callable;

/// <summary>
/// The Firebase Cloud Functions <b>callable</b> HTTPS protocol, ported for the
/// Windows client (the macOS app calls these through the Firebase SDK
/// <c>httpsCallable(name).call(data)</c>; e.g.
/// <c>mintWindowsAppCheckToken</c>, <c>beginEntitlementBinding</c>,
/// <c>getDataDomainUsage</c>). The wire envelope is fixed:
/// <code>
///   POST {host}/{name}
///   Authorization: Bearer &lt;idToken&gt;          X-Firebase-AppCheck: &lt;appCheckToken&gt;
///   { "data": &lt;args&gt; }                        -- request
///   { "result": &lt;payload&gt; }                   -- success (HTTP 200)
///   { "error": { "message", "status", "details" } }  -- failure
/// </code>
/// </summary>
public sealed class CallableClient
{
    private static readonly JsonSerializerOptions DeserializeOptions = new()
    {
        PropertyNameCaseInsensitive = false,
    };

    private readonly ICloudSyncHttpTransport _transport;
    private readonly ICloudSyncCredentialsProvider _credentials;
    private readonly CallableEndpoint _endpoint;

    public CallableClient(
        ICloudSyncHttpTransport transport,
        ICloudSyncCredentialsProvider credentials,
        CallableEndpoint endpoint)
    {
        _transport = transport;
        _credentials = credentials;
        _endpoint = endpoint;
    }

    /// <summary>Build the canonical request body <c>{ "data": &lt;args&gt; }</c> for a callable.</summary>
    public static byte[] BuildRequestBody<TRequest>(TRequest request)
    {
        JsonNode? dataNode = request is null ? null : JsonSerializer.SerializeToNode(request, DeserializeOptions);
        var envelope = new JsonObject { ["data"] = dataNode };
        return CanonicalJson.SerializeToUtf8Bytes(envelope);
    }

    /// <summary>Parse a callable response body, throwing <see cref="CallableException"/> on an error envelope.</summary>
    public static TResult ParseResponse<TResult>(byte[] body)
    {
        using var document = JsonDocument.Parse(body);
        JsonElement root = document.RootElement;

        if (root.TryGetProperty("error", out JsonElement errorElement))
        {
            throw new CallableException(CallableError.FromJson(errorElement));
        }

        if (!root.TryGetProperty("result", out JsonElement resultElement))
        {
            throw new CallableException(new CallableError(
                "INTERNAL", "Callable response missing both 'result' and 'error'.", null));
        }

        TResult? result = resultElement.Deserialize<TResult>(DeserializeOptions);
        if (result is null)
        {
            throw new CallableException(new CallableError("INTERNAL", "Callable 'result' decoded to null.", null));
        }
        return result;
    }

    /// <summary>Invoke a callable end-to-end through the HTTP transport.</summary>
    public async Task<TResult> InvokeAsync<TRequest, TResult>(
        string name,
        TRequest request,
        CancellationToken cancellationToken = default)
    {
        CloudSyncCredentials credentials = await _credentials
            .GetCredentialsAsync(cancellationToken)
            .ConfigureAwait(false);

        var headers = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["Authorization"] = $"Bearer {credentials.IdToken}",
        };
        if (credentials.AppCheckToken is { Length: > 0 } appCheck)
        {
            headers["X-Firebase-AppCheck"] = appCheck;
        }

        var httpRequest = new CloudSyncHttpRequest(
            HttpVerb.Post,
            _endpoint.UrlFor(name),
            BuildRequestBody(request),
            headers);

        CloudSyncHttpResponse response = await _transport
            .SendAsync(httpRequest, cancellationToken)
            .ConfigureAwait(false);

        // The callable protocol reports application errors in the body even on
        // some non-2xx statuses; try to surface the structured error either way.
        if (!response.IsSuccess)
        {
            CallableError? bodyError = CallableError.TryFromBody(response.Body);
            throw new CallableException(bodyError
                ?? new CallableError(MapHttpStatus(response.StatusCode), $"Callable HTTP {response.StatusCode}.", null));
        }

        return ParseResponse<TResult>(response.Body);
    }

    private static string MapHttpStatus(int status) => status switch
    {
        400 => "INVALID_ARGUMENT",
        401 => "UNAUTHENTICATED",
        403 => "PERMISSION_DENIED",
        404 => "NOT_FOUND",
        429 => "RESOURCE_EXHAUSTED",
        >= 500 => "UNAVAILABLE",
        _ => "UNKNOWN",
    };
}

/// <summary>
/// The callable host for a region + project. The Firebase SDK routes
/// <c>Functions.functions(region: "us-central1").httpsCallable(name)</c> to
/// <c>https://{region}-{project}.cloudfunctions.net/{name}</c>.
/// </summary>
public sealed record CallableEndpoint(string Region, string ProjectId, string? Host = null)
{
    public string UrlFor(string name)
    {
        string host = Host ?? $"https://{Region}-{ProjectId}.cloudfunctions.net";
        return $"{host.TrimEnd('/')}/{name}";
    }
}

/// <summary>The structured error carried by a callable <c>{ "error": ... }</c> envelope.</summary>
public sealed record CallableError(string Status, string Message, JsonElement? Details)
{
    public static CallableError FromJson(JsonElement error)
    {
        string status = error.TryGetProperty("status", out JsonElement s) && s.ValueKind == JsonValueKind.String
            ? s.GetString()!
            : "UNKNOWN";
        string message = error.TryGetProperty("message", out JsonElement m) && m.ValueKind == JsonValueKind.String
            ? m.GetString()!
            : "Callable error.";
        JsonElement? details = error.TryGetProperty("details", out JsonElement d) ? d.Clone() : null;
        return new CallableError(status, message, details);
    }

    public static CallableError? TryFromBody(byte[] body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("error", out JsonElement error))
            {
                return FromJson(error);
            }
        }
        catch (JsonException)
        {
            // Non-JSON body — fall through to null.
        }
        return null;
    }
}

public sealed class CallableException : Exception
{
    public CallableException(CallableError error) : base($"{error.Status}: {error.Message}") => Error = error;

    public CallableError Error { get; }
}
