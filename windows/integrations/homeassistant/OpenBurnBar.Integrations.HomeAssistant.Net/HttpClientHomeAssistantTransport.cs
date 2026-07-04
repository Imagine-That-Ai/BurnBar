using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.HomeAssistant.Rest;

namespace OpenBurnBar.Integrations.HomeAssistant.Net;

// Live HttpClient transport for the portable Home Assistant client.
//
// Implements IHomeAssistantHttpTransport with System.Net.Http, mapping timeouts
// and connection faults onto the portable HomeAssistantClientException the same
// way the Swift URLSession client mapped URLError.timedOut / other URLErrors.
// Every request field (method, URL, headers, body, per-request timeout) comes
// from the portable client; this adapter only performs the send.

public sealed class HttpClientHomeAssistantTransport : IHomeAssistantHttpTransport, IDisposable
{
    private readonly HttpClient _httpClient;
    private readonly bool _ownsClient;

    public HttpClientHomeAssistantTransport(HttpClient? httpClient = null)
    {
        _httpClient = httpClient ?? new HttpClient();
        _ownsClient = httpClient is null;
    }

    public async Task<HaHttpResponse> SendAsync(HaHttpRequest request, CancellationToken cancellationToken = default)
    {
        using var message = new HttpRequestMessage(new HttpMethod(request.Method), request.Url);

        // HA /api/ probe uses no-store semantics; honor it for parity with the
        // Swift reloadIgnoringLocalAndRemoteCacheData policy.
        message.Headers.CacheControl = new CacheControlHeaderValue { NoStore = true, NoCache = true };

        string? contentType = null;
        foreach (var header in request.Headers)
        {
            if (string.Equals(header.Name, "Content-Type", StringComparison.OrdinalIgnoreCase))
            {
                contentType = header.Value;
                continue;
            }
            message.Headers.TryAddWithoutValidation(header.Name, header.Value);
        }

        if (request.Body is not null)
        {
            message.Content = new ByteArrayContent(request.Body);
            if (contentType is not null)
            {
                message.Content.Headers.TryAddWithoutValidation("Content-Type", contentType);
            }
        }

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (request.TimeoutSeconds > 0)
        {
            timeoutCts.CancelAfter(TimeSpan.FromSeconds(request.TimeoutSeconds));
        }

        HttpResponseMessage response;
        try
        {
            response = await _httpClient
                .SendAsync(message, HttpCompletionOption.ResponseContentRead, timeoutCts.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            // The linked token fired from our timeout, not the caller's cancel.
            throw HomeAssistantClientException.Timeout();
        }
        catch (HttpRequestException ex)
        {
            throw HomeAssistantClientException.Transport(ex.Message);
        }

        using (response)
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            var headers = new List<HaHeader>();
            foreach (var header in response.Headers)
            {
                foreach (var value in header.Value)
                {
                    headers.Add(new HaHeader(header.Key, value));
                }
            }
            foreach (var header in response.Content.Headers)
            {
                foreach (var value in header.Value)
                {
                    headers.Add(new HaHeader(header.Key, value));
                }
            }

            return new HaHttpResponse((int)response.StatusCode, headers, body);
        }
    }

    public void Dispose()
    {
        if (_ownsClient)
        {
            _httpClient.Dispose();
        }
    }
}
