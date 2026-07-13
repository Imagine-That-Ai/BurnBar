using System;
using System.Net;
using System.Net.Http;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class ModelCompletionExecutorTests
{
    [Fact]
    public async Task ExecuteAsync_RejectsRemoteHttpBeforeTransport()
    {
        var handler = new CapturingResponseHandler(new HttpResponseMessage(HttpStatusCode.OK));
        using var client = new HttpClient(handler);
        var executor = new HttpModelCompletionExecutor(client);

        ModelCompletionResult result = await executor.ExecuteAsync(
            new ModelRoute(
                "unsafe-route",
                "openai",
                "model",
                0,
                true,
                new Uri("http://provider.example/v1/chat/completions")),
            Encoding.UTF8.GetBytes("{}"),
            CancellationToken.None);

        Assert.False(result.Succeeded);
        Assert.Equal(503, result.StatusCode);
        Assert.Null(handler.RequestBody);
    }

    [Fact]
    public async Task ExecuteAsync_RejectsOversizedProviderResponse()
    {
        using var client = new HttpClient(new FixedResponseHandler(
            new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(new byte[HttpModelCompletionExecutor.MaxResponseBytes + 1]),
            }));
        var executor = new HttpModelCompletionExecutor(client);

        ModelCompletionResult result = await executor.ExecuteAsync(
            new ModelRoute("route", "openai", "model", 0, true, new Uri("https://provider.test/v1/chat/completions")),
            new byte[] { (byte)'{' },
            CancellationToken.None);

        Assert.False(result.Succeeded);
        Assert.Equal(502, result.StatusCode);
        Assert.Empty(result.Body);
    }

    [Fact]
    public async Task ExecuteAsync_AdaptsAnthropicMessagesAndNormalizesResponse()
    {
        var handler = new CapturingResponseHandler(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(
                "{\"id\":\"msg_1\",\"model\":\"claude-test\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}"),
        });
        using var client = new HttpClient(handler);
        var executor = new HttpModelCompletionExecutor(client);

        ModelCompletionResult result = await executor.ExecuteAsync(
            new ModelRoute(
                "anthropic-route",
                "anthropic",
                "claude-test",
                0,
                true,
                new Uri("https://api.anthropic.test/v1/messages"),
                "sk-ant-test-token"),
            Encoding.UTF8.GetBytes(
                "{\"model\":\"claude-test\",\"messages\":[{\"role\":\"system\",\"content\":\"be concise\"},{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":64}"),
            CancellationToken.None);

        Assert.True(result.Succeeded);
        Assert.Equal("hello", JsonDocument.Parse(result.Body).RootElement
            .GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString());
        Assert.Contains("be concise", handler.RequestBody, StringComparison.Ordinal);
        Assert.DoesNotContain("\"role\":\"system\"", handler.RequestBody, StringComparison.Ordinal);
        Assert.Equal("sk-ant-test-token", handler.RequestHeaders["x-api-key"]);
        Assert.Equal(AnthropicProviderAdapter.ApiVersion, handler.RequestHeaders["anthropic-version"]);
        Assert.DoesNotContain("Authorization", handler.RequestHeaders.Keys, StringComparer.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ExecuteAsync_AdaptsAnthropicToolsAndNormalizesToolUseResponse()
    {
        var handler = new CapturingResponseHandler(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(
                "{\"id\":\"msg_tool\",\"model\":\"claude-test\",\"content\":[{\"type\":\"text\",\"text\":\"I will look\"},{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"lookup\",\"input\":{\"q\":\"x\"}}],\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":5,\"output_tokens\":4}}"),
        });
        using var client = new HttpClient(handler);
        var executor = new HttpModelCompletionExecutor(client);

        ModelCompletionResult result = await executor.ExecuteAsync(
            new ModelRoute(
                "anthropic-route",
                "anthropic",
                "claude-test",
                0,
                true,
                new Uri("https://api.anthropic.test/v1/messages"),
                "sk-ant-test-token"),
            Encoding.UTF8.GetBytes(
                "{\"model\":\"claude-test\",\"messages\":[{\"role\":\"user\",\"content\":\"find x\"},{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"q\\\":\\\"x\\\"}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"result\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"description\":\"look up\",\"parameters\":{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}}}}}],\"tool_choice\":{\"type\":\"function\",\"function\":{\"name\":\"lookup\"}},\"max_tokens\":64}"),
            CancellationToken.None);

        Assert.True(result.Succeeded);
        using JsonDocument response = JsonDocument.Parse(result.Body);
        JsonElement message = response.RootElement.GetProperty("choices")[0].GetProperty("message");
        Assert.Equal("I will look", message.GetProperty("content").GetString());
        Assert.Equal("lookup", message.GetProperty("tool_calls")[0].GetProperty("function").GetProperty("name").GetString());
        Assert.Equal("{\"q\":\"x\"}", message.GetProperty("tool_calls")[0].GetProperty("function").GetProperty("arguments").GetString());
        Assert.Contains("tool_use", handler.RequestBody, StringComparison.Ordinal);
        Assert.Contains("tool_result", handler.RequestBody, StringComparison.Ordinal);
        Assert.Contains("input_schema", handler.RequestBody, StringComparison.Ordinal);
        Assert.Contains("\"type\":\"tool\"", handler.RequestBody, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ExecuteAsync_MapsAnthropicImageContentAndRejectsUnsafeUrls()
    {
        var handler = new CapturingResponseHandler(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(
                "{\"id\":\"msg_image\",\"model\":\"claude-test\",\"content\":[{\"type\":\"text\",\"text\":\"seen\"}],\"stop_reason\":\"end_turn\"}"),
        });
        using var client = new HttpClient(handler);
        var executor = new HttpModelCompletionExecutor(client);
        ModelRoute route = new(
            "anthropic-route",
            "anthropic",
            "claude-test",
            0,
            true,
            new Uri("https://api.anthropic.test/v1/messages"),
            "sk-ant-test-token");

        ModelCompletionResult result = await executor.ExecuteAsync(
            route,
            Encoding.UTF8.GetBytes(
                "{\"model\":\"claude-test\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"what is this?\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,aGVsbG8=\"}}]}],\"max_tokens\":64}"),
            CancellationToken.None);

        Assert.True(result.Succeeded);
        Assert.Contains("\"type\":\"image\"", handler.RequestBody, StringComparison.Ordinal);
        Assert.Contains("\"media_type\":\"image/png\"", handler.RequestBody, StringComparison.Ordinal);
        Assert.Contains("\"data\":\"aGVsbG8=\"", handler.RequestBody, StringComparison.Ordinal);

        var rejectedHandler = new CapturingResponseHandler(new HttpResponseMessage(HttpStatusCode.OK));
        using var rejectedClient = new HttpClient(rejectedHandler);
        var rejected = await new HttpModelCompletionExecutor(rejectedClient).ExecuteAsync(
            route,
            Encoding.UTF8.GetBytes(
                "{\"model\":\"claude-test\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"http://127.0.0.1/private.png\"}}]}] }"),
            CancellationToken.None);
        Assert.False(rejected.Succeeded);
        Assert.Equal(400, rejected.StatusCode);
        Assert.Null(rejectedHandler.RequestBody);
    }

    [Fact]
    public async Task ExecuteAsync_RejectsMalformedAnthropicToolArgumentsBeforeTransport()
    {
        var handler = new CapturingResponseHandler(new HttpResponseMessage(HttpStatusCode.OK));
        using var client = new HttpClient(handler);
        var executor = new HttpModelCompletionExecutor(client);

        ModelCompletionResult result = await executor.ExecuteAsync(
            new ModelRoute("anthropic-route", "anthropic", "claude-test", 0, true, new Uri("https://api.anthropic.test/v1/messages")),
            Encoding.UTF8.GetBytes(
                "{\"model\":\"claude-test\",\"messages\":[{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"not-json\"}}]}]}"),
            CancellationToken.None);

        Assert.False(result.Succeeded);
        Assert.Equal(400, result.StatusCode);
        Assert.Null(handler.RequestBody);
    }

    [Fact]
    public async Task ExecuteAsync_AdaptsAnthropicStreamingEvents()
    {
        var response = new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(
                "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_stream\",\"model\":\"claude-test\"}}\n\n" +
                "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" +
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}\n\n" +
                "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n" +
                "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n" +
                "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"),
        };
        response.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("text/event-stream");
        var handler = new CapturingResponseHandler(response);
        using var client = new HttpClient(handler);
        var executor = new HttpModelCompletionExecutor(client);

        ModelCompletionResult result = await executor.ExecuteAsync(
            new ModelRoute("anthropic-route", "anthropic", "claude-test", 0, true, new Uri("https://api.anthropic.test/v1/messages")),
            Encoding.UTF8.GetBytes(
                "{\"model\":\"claude-test\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}"),
            CancellationToken.None);

        Assert.True(result.Succeeded);
        Assert.Equal("text/event-stream", result.ContentType);
        string stream = Encoding.UTF8.GetString(result.Body);
        Assert.Contains("chat.completion.chunk", stream, StringComparison.Ordinal);
        Assert.Contains("hello", stream, StringComparison.Ordinal);
        Assert.Contains("[DONE]", stream, StringComparison.Ordinal);
        Assert.Contains("\"stream\":true", handler.RequestBody, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ExecuteAsync_FailsClosedForTruncatedAnthropicEventStream()
    {
        var response = new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(
                "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_stream\",\"model\":\"claude-test\"}}\n\n"),
        };
        response.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("text/event-stream");
        using var client = new HttpClient(new CapturingResponseHandler(response));
        var executor = new HttpModelCompletionExecutor(client);

        ModelCompletionResult result = await executor.ExecuteAsync(
            new ModelRoute("anthropic-route", "anthropic", "claude-test", 0, true, new Uri("https://api.anthropic.test/v1/messages")),
            Encoding.UTF8.GetBytes(
                "{\"model\":\"claude-test\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}"),
            CancellationToken.None);

        Assert.False(result.Succeeded);
        Assert.Equal(502, result.StatusCode);
        Assert.Empty(result.Body);
    }

    [Fact]
    public async Task ExecuteAsync_FailsClosedForMalformedAnthropicTypes()
    {
        var handler = new CapturingResponseHandler(new HttpResponseMessage(HttpStatusCode.OK));
        using var client = new HttpClient(handler);
        var executor = new HttpModelCompletionExecutor(client);

        ModelCompletionResult result = await executor.ExecuteAsync(
            new ModelRoute("anthropic-route", "anthropic", "claude-test", 0, true, new Uri("https://api.anthropic.test/v1/messages")),
            Encoding.UTF8.GetBytes(
                "{\"model\":\"claude-test\",\"stream\":\"yes\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}"),
            CancellationToken.None);

        Assert.False(result.Succeeded);
        Assert.Equal(400, result.StatusCode);
        Assert.Null(handler.RequestBody);
    }

    private sealed class FixedResponseHandler : HttpMessageHandler
    {
        private readonly HttpResponseMessage _response;

        public FixedResponseHandler(HttpResponseMessage response) => _response = response;

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => Task.FromResult(_response);
    }

    private sealed class CapturingResponseHandler : HttpMessageHandler
    {
        private readonly HttpResponseMessage _response;

        public CapturingResponseHandler(HttpResponseMessage response) => _response = response;

        public string? RequestBody { get; private set; }

        public Dictionary<string, string> RequestHeaders { get; } = new(StringComparer.OrdinalIgnoreCase);

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            RequestBody = request.Content is null
                ? null
                : await request.Content.ReadAsStringAsync(cancellationToken);
            foreach (KeyValuePair<string, IEnumerable<string>> header in request.Headers)
            {
                RequestHeaders[header.Key] = string.Join(",", header.Value);
            }

            return _response;
        }
    }
}
