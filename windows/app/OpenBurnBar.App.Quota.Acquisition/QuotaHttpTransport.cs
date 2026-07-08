using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Quota.Acquisition;

// HTTP seam for the quota sources — same shape as cloudsync's
// ICloudSyncHttpTransport (windows/cloudsync/OpenBurnBar.CloudSync/Gateway/
// ICloudSyncHttpTransport.cs) so tests fake it with a recording responder and
// production wraps a shared HttpClient.

/// <summary>HTTP verbs the quota sources use.</summary>
public enum QuotaHttpVerb
{
    /// <summary>GET.</summary>
    Get,

    /// <summary>POST.</summary>
    Post,
}

/// <summary>One outgoing request.</summary>
public sealed record QuotaHttpRequest(
    QuotaHttpVerb Method,
    string Url,
    byte[]? Body,
    IReadOnlyDictionary<string, string> Headers);

/// <summary>One response. Headers keep the wire casing; readers must be case-insensitive.</summary>
public sealed record QuotaHttpResponse(
    int StatusCode,
    byte[] Body,
    IReadOnlyDictionary<string, string> Headers)
{
    /// <summary>2xx.</summary>
    public bool IsSuccess => StatusCode is >= 200 and < 300;

    /// <summary>401/403 — the Mac adapters treat both as an auth rejection.</summary>
    public bool IsAuthRejected => StatusCode is 401 or 403;
}

/// <summary>The transport seam.</summary>
public interface IQuotaHttpTransport
{
    /// <summary>Send one request.</summary>
    Task<QuotaHttpResponse> SendAsync(QuotaHttpRequest request, CancellationToken cancellationToken = default);
}

/// <summary>Production transport over <see cref="HttpClient"/>.</summary>
public sealed class HttpClientQuotaTransport : IQuotaHttpTransport
{
    private readonly HttpClient _client;

    /// <summary>Wrap a caller-owned client (lifetime stays with the caller).</summary>
    public HttpClientQuotaTransport(HttpClient client)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
    }

    /// <inheritdoc />
    public async Task<QuotaHttpResponse> SendAsync(
        QuotaHttpRequest request,
        CancellationToken cancellationToken = default)
    {
        using var message = new HttpRequestMessage(
            request.Method == QuotaHttpVerb.Post ? HttpMethod.Post : HttpMethod.Get,
            request.Url);

        string? contentType = null;
        foreach (var pair in request.Headers)
        {
            if (string.Equals(pair.Key, "Content-Type", StringComparison.OrdinalIgnoreCase))
            {
                contentType = pair.Value;
                continue;
            }

            message.Headers.TryAddWithoutValidation(pair.Key, pair.Value);
        }

        if (request.Body is not null)
        {
            var content = new ByteArrayContent(request.Body);
            if (contentType is not null)
            {
                content.Headers.TryAddWithoutValidation("Content-Type", contentType);
            }

            message.Content = content;
        }

        using var response = await _client.SendAsync(message, cancellationToken).ConfigureAwait(false);
        var body = response.Content is null
            ? Array.Empty<byte>()
            : await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);

        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in response.Headers)
        {
            headers[pair.Key] = string.Join(",", pair.Value);
        }

        if (response.Content is not null)
        {
            foreach (var pair in response.Content.Headers)
            {
                headers[pair.Key] = string.Join(",", pair.Value);
            }
        }

        return new QuotaHttpResponse((int)response.StatusCode, body, headers);
    }
}
