using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.AppCheck.Mint;

namespace OpenBurnBar.CloudSync.AppCheck.Net;

/// <summary>
/// Live <see cref="HttpClient"/> transport for the portable App Check mint client.
/// </summary>
/// <remarks>
/// Implements <see cref="IAppCheckMintTransport"/> with System.Net.Http, mapping
/// timeouts and connection faults onto the portable <see cref="AppCheckMintException"/>
/// so the mint client fails CLOSED on transport faults. Every request field
/// (method, URL, headers, body, per-request timeout) comes from the portable
/// client; this adapter only performs the send. It is cross-platform (no WinRT),
/// so it runs today on the macOS authoring host against a loopback
/// <c>HttpListener</c> — proving the full claim → HTTP → token-install path
/// off-Windows.
/// </remarks>
public sealed class HttpClientAppCheckMintTransport : IAppCheckMintTransport, IDisposable
{
    private readonly HttpClient _httpClient;
    private readonly bool _ownsClient;

    public HttpClientAppCheckMintTransport(HttpClient? httpClient = null)
    {
        _httpClient = httpClient ?? new HttpClient();
        _ownsClient = httpClient is null;
    }

    public async Task<AppCheckMintHttpResponse> SendAsync(
        AppCheckMintHttpRequest request,
        CancellationToken cancellationToken = default)
    {
        if (request is null) throw new ArgumentNullException(nameof(request));

        using var message = new HttpRequestMessage(new HttpMethod(request.Method), request.Url);

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
            message.Content.Headers.ContentType =
                MediaTypeHeaderValue.Parse(contentType ?? "application/json");
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
            throw AppCheckMintException.Timeout();
        }
        catch (HttpRequestException ex)
        {
            throw AppCheckMintException.Transport(ex.Message, ex);
        }

        using (response)
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            return new AppCheckMintHttpResponse((int)response.StatusCode, body);
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
