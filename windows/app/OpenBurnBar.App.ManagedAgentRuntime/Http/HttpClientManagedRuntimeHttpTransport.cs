using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Http;

/// <summary>
/// The production <see cref="IManagedRuntimeHttpTransport"/>: a thin wrapper over
/// <c>System.Net.Http.HttpClient</c>. This is the portable analog of Foundation's
/// <c>URLSession.shared</c> that the Swift discovery + model probe use, and — like
/// the rest of this core — it runs unchanged on the macOS authoring host because
/// <c>HttpClient</c> is cross-platform (no Windows-only dependency).
///
/// The per-request timeout from <see cref="HttpProbeRequest.Timeout"/> is applied
/// with a linked <see cref="CancellationTokenSource"/> (HttpClient's own
/// <c>Timeout</c> is per-client, not per-request), so each caller controls its own
/// deadline exactly as <c>URLRequest.timeoutInterval</c> does.
/// </summary>
public sealed class HttpClientManagedRuntimeHttpTransport : IManagedRuntimeHttpTransport
{
    private readonly HttpClient _client;

    /// <summary>
    /// Wraps a caller-owned <see cref="HttpClient"/>. The transport does NOT
    /// dispose it — lifetime belongs to the caller (typically a single app-wide
    /// client), matching the shared-session model on macOS.
    /// </summary>
    public HttpClientManagedRuntimeHttpTransport(HttpClient client)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
    }

    /// <inheritdoc />
    public async Task<HttpProbeResponse> SendAsync(
        HttpProbeRequest request,
        CancellationToken cancellationToken = default)
    {
        using var timeoutSource = new CancellationTokenSource(request.Timeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            timeoutSource.Token);

        using var message = new HttpRequestMessage(new HttpMethod(request.Method), request.Url);
        foreach (var header in request.Headers)
        {
            message.Headers.TryAddWithoutValidation(header.Key, header.Value);
        }

        using var response = await _client
            .SendAsync(message, HttpCompletionOption.ResponseContentRead, linked.Token)
            .ConfigureAwait(false);

        var body = await response.Content
            .ReadAsByteArrayAsync(linked.Token)
            .ConfigureAwait(false);

        return new HttpProbeResponse((int)response.StatusCode, body);
    }
}
