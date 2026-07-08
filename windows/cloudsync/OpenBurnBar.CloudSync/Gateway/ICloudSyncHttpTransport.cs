using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.CloudSync.Gateway;

/// <summary>
/// The HTTP seam shared by the Firestore REST gateway and the callable client.
/// The macOS build has the Firebase Objective-C SDK to do this; Windows has no
/// such SDK, so the wire is an explicit HTTP transport. A fake transport records
/// the exact request bytes and returns canned responses, letting tests prove the
/// request SHAPES and response PARSING without a live network. The live
/// authenticated round-trip (real Firestore, real tokens) is dev-host/CI-deferred.
/// </summary>
public interface ICloudSyncHttpTransport
{
    Task<CloudSyncHttpResponse> SendAsync(CloudSyncHttpRequest request, CancellationToken cancellationToken = default);
}

public enum HttpVerb
{
    Get,
    Post,
    Patch,
    Delete,
}

public sealed record CloudSyncHttpRequest(
    HttpVerb Method,
    string Url,
    byte[]? Body,
    IReadOnlyDictionary<string, string> Headers);

public sealed record CloudSyncHttpResponse(
    int StatusCode,
    byte[] Body,
    IReadOnlyDictionary<string, string> Headers)
{
    public bool IsSuccess => StatusCode is >= 200 and < 300;
}

/// <summary>
/// Firebase identity for authenticated Firestore + callable requests. The App
/// Check token is minted by the Phase-0 <c>mintWindowsAppCheckToken</c> callable
/// (functions/src/callables/windowsAppCheck.ts). A null <see cref="AppCheckToken"/>
/// is fail-closed when App Check is required (see <see cref="FirestoreRestGateway"/>).
/// </summary>
public sealed record CloudSyncCredentials(string IdToken, string? AppCheckToken = null);

public interface ICloudSyncCredentialsProvider
{
    Task<CloudSyncCredentials> GetCredentialsAsync(CancellationToken cancellationToken = default);
}

/// <summary>A static credentials provider (dev-host / test convenience).</summary>
public sealed class StaticCredentialsProvider : ICloudSyncCredentialsProvider
{
    private readonly CloudSyncCredentials _credentials;

    public StaticCredentialsProvider(CloudSyncCredentials credentials) => _credentials = credentials;

    public Task<CloudSyncCredentials> GetCredentialsAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(_credentials);
}

/// <summary>
/// The real <see cref="HttpClient"/>-backed transport that ships on Windows.
/// Present and buildable on the macOS authoring host, but its live round-trip is
/// exercised only on a dev host / CI with real Firebase credentials.
/// </summary>
public sealed class HttpClientCloudSyncTransport : ICloudSyncHttpTransport
{
    private readonly HttpClient _client;

    public HttpClientCloudSyncTransport(HttpClient client) => _client = client;

    public async Task<CloudSyncHttpResponse> SendAsync(CloudSyncHttpRequest request, CancellationToken cancellationToken = default)
    {
        using var message = new HttpRequestMessage(ToHttpMethod(request.Method), request.Url);
        if (request.Body is { } body)
        {
            message.Content = new ByteArrayContent(body);
            message.Content.Headers.TryAddWithoutValidation("Content-Type", "application/json");
        }
        foreach (KeyValuePair<string, string> header in request.Headers)
        {
            if (!message.Headers.TryAddWithoutValidation(header.Key, header.Value))
            {
                message.Content?.Headers.TryAddWithoutValidation(header.Key, header.Value);
            }
        }

        using HttpResponseMessage response = await _client
            .SendAsync(message, HttpCompletionOption.ResponseContentRead, cancellationToken)
            .ConfigureAwait(false);
        byte[] responseBody = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (KeyValuePair<string, IEnumerable<string>> header in response.Headers)
        {
            headers[header.Key] = string.Join(",", header.Value);
        }
        return new CloudSyncHttpResponse((int)response.StatusCode, responseBody, headers);
    }

    private static HttpMethod ToHttpMethod(HttpVerb verb) => verb switch
    {
        HttpVerb.Get => HttpMethod.Get,
        HttpVerb.Post => HttpMethod.Post,
        HttpVerb.Patch => HttpMethod.Patch,
        HttpVerb.Delete => HttpMethod.Delete,
        _ => throw new ArgumentOutOfRangeException(nameof(verb), verb, "Unsupported HTTP verb."),
    };
}
