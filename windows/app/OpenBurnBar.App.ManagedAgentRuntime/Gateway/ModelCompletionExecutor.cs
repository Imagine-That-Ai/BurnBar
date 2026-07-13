using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>Result of forwarding an OpenAI-compatible completion request.</summary>
public readonly record struct ModelCompletionResult(
    int StatusCode,
    byte[] Body,
    string ContentType,
    bool Succeeded);

/// <summary>
/// Executes a completion against the selected provider route. The request body
/// remains opaque so the gateway preserves provider-compatible fields and does
/// not accidentally log or reinterpret prompts, attachments, or tool payloads.
/// </summary>
public interface IModelCompletionExecutor
{
    Task<ModelCompletionResult> ExecuteAsync(
        ModelRoute route,
        byte[] requestBody,
        CancellationToken cancellationToken = default);
}

/// <summary>
/// Production executor for OpenAI-compatible providers. It forwards only to a
/// route's explicitly configured HTTPS/loopback endpoint, applies a bounded
/// request timeout, and never shells out or constructs command strings.
/// </summary>
public sealed class HttpModelCompletionExecutor : IModelCompletionExecutor
{
    private readonly HttpClient _client;
    private readonly TimeSpan _timeout;

    public HttpModelCompletionExecutor(HttpClient client, TimeSpan? timeout = null)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _timeout = timeout ?? TimeSpan.FromSeconds(90);
        if (_timeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }
    }

    public async Task<ModelCompletionResult> ExecuteAsync(
        ModelRoute route,
        byte[] requestBody,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(route);
        ArgumentNullException.ThrowIfNull(requestBody);
        if (route.Endpoint is null || !route.Endpoint.IsAbsoluteUri)
        {
            return new ModelCompletionResult(503, Array.Empty<byte>(), "application/json", false);
        }

        using var timeout = new CancellationTokenSource(_timeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            timeout.Token);
        using var request = new HttpRequestMessage(HttpMethod.Post, route.Endpoint)
        {
            Content = new ByteArrayContent(requestBody),
        };
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        if (!string.IsNullOrWhiteSpace(route.BearerToken))
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", route.BearerToken.Trim());
        }

        try
        {
            using HttpResponseMessage response = await _client
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, linked.Token)
                .ConfigureAwait(false);
            byte[] body = await response.Content.ReadAsByteArrayAsync(linked.Token).ConfigureAwait(false);
            string contentType = response.Content.Headers.ContentType?.ToString()
                ?? "application/json";
            int status = (int)response.StatusCode;
            return new ModelCompletionResult(status, body, contentType, status is >= 200 and <= 299);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new ModelCompletionResult(504, Array.Empty<byte>(), "application/json", false);
        }
        catch (HttpRequestException)
        {
            return new ModelCompletionResult(502, Array.Empty<byte>(), "application/json", false);
        }
    }
}

/// <summary>Small deterministic executor useful for local composition and tests.</summary>
public sealed class DelegateModelCompletionExecutor : IModelCompletionExecutor
{
    private readonly Func<ModelRoute, byte[], CancellationToken, Task<ModelCompletionResult>> _handler;

    public DelegateModelCompletionExecutor(
        Func<ModelRoute, byte[], CancellationToken, Task<ModelCompletionResult>> handler)
    {
        _handler = handler ?? throw new ArgumentNullException(nameof(handler));
    }

    public Task<ModelCompletionResult> ExecuteAsync(
        ModelRoute route,
        byte[] requestBody,
        CancellationToken cancellationToken = default) =>
        _handler(route, requestBody, cancellationToken);
}
