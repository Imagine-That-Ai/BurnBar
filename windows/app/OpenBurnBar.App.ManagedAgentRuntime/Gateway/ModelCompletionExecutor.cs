using System;
using System.IO;
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
    public const int MaxResponseBytes = 4 * 1024 * 1024;

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
        if (!route.IsExecutable || route.Endpoint is null)
        {
            return new ModelCompletionResult(503, Array.Empty<byte>(), "application/json", false);
        }

        bool anthropic = AnthropicProviderAdapter.IsAnthropic(route);
        bool anthropicStreaming = false;
        bool ollamaNative = OllamaNativeProviderAdapter.IsNative(route);
        bool ollamaStreaming = false;
        byte[] outboundBody;
        try
        {
            if (anthropic)
            {
                anthropicStreaming = AnthropicProviderAdapter.IsStreamingRequest(requestBody);
            }
            if (anthropic)
            {
                outboundBody = AnthropicProviderAdapter.ToMessagesRequest(requestBody, route.Model);
            }
            else if (ollamaNative)
            {
                (outboundBody, ollamaStreaming) = OllamaNativeProviderAdapter.ToNativeRequest(
                    requestBody,
                    route.Model);
            }
            else
            {
                outboundBody = requestBody;
            }
        }
        catch (ProviderWireFormatException error)
        {
            return new ModelCompletionResult(error.StatusCode, Array.Empty<byte>(), "application/json", false);
        }

        using var timeout = new CancellationTokenSource(_timeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            timeout.Token);
        Uri endpoint = ollamaNative
            ? OllamaNativeProviderAdapter.ChatEndpoint(route.Endpoint)
            : route.Endpoint;
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
        {
            Content = new ByteArrayContent(outboundBody),
        };
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        if (anthropic)
        {
            request.Headers.TryAddWithoutValidation("anthropic-version", AnthropicProviderAdapter.ApiVersion);
            if (!string.IsNullOrWhiteSpace(route.BearerToken))
            {
                string token = route.BearerToken.Trim();
                if (token.StartsWith("sk-ant-", StringComparison.OrdinalIgnoreCase))
                {
                    request.Headers.TryAddWithoutValidation("x-api-key", token);
                }
                else
                {
                    request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                }
            }
        }
        else if (!string.IsNullOrWhiteSpace(route.BearerToken))
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", route.BearerToken.Trim());
        }

        try
        {
            using HttpResponseMessage response = await _client
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, linked.Token)
                .ConfigureAwait(false);
            byte[] body = await ReadBoundedAsync(response.Content, linked.Token).ConfigureAwait(false);
            string contentType = response.Content.Headers.ContentType?.ToString()
                ?? "application/json";
            int status = (int)response.StatusCode;
            if (anthropic && status is >= 200 and <= 299)
            {
                try
                {
                    if (anthropicStreaming)
                    {
                        if (!contentType.StartsWith("text/event-stream", StringComparison.OrdinalIgnoreCase))
                        {
                            return new ModelCompletionResult(502, Array.Empty<byte>(), "application/json", false);
                        }

                        body = AnthropicProviderAdapter.ToOpenAiEventStream(body, route.Model);
                        contentType = "text/event-stream";
                    }
                    else
                    {
                        body = AnthropicProviderAdapter.ToOpenAiResponse(body, route.Model);
                        contentType = "application/json";
                    }
                }
                catch (ProviderWireFormatException)
                {
                    return new ModelCompletionResult(502, Array.Empty<byte>(), "application/json", false);
                }
            }
            else if (ollamaNative && status is >= 200 and <= 299)
            {
                try
                {
                    return OllamaNativeProviderAdapter.ToOpenAiResponse(
                        body,
                        route.Model,
                        ollamaStreaming);
                }
                catch (ProviderWireFormatException)
                {
                    return new ModelCompletionResult(502, Array.Empty<byte>(), "application/json", false);
                }
            }

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
        catch (ResponseTooLargeException)
        {
            return new ModelCompletionResult(502, Array.Empty<byte>(), "application/json", false);
        }
    }

    private static async Task<byte[]> ReadBoundedAsync(
        HttpContent content,
        CancellationToken cancellationToken)
    {
        await using Stream stream = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var buffer = new MemoryStream(capacity: Math.Min(MaxResponseBytes, 64 * 1024));
        byte[] chunk = new byte[64 * 1024];
        while (true)
        {
            int read = await stream.ReadAsync(chunk.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                return buffer.ToArray();
            }

            if (buffer.Length + read > MaxResponseBytes)
            {
                throw new ResponseTooLargeException();
            }

            buffer.Write(chunk, 0, read);
        }
    }

    private sealed class ResponseTooLargeException : Exception
    {
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
