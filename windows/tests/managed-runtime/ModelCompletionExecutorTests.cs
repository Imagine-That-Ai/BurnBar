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
    public async Task ExecuteAsync_RejectsUnsupportedAnthropicStreamingBeforeTransport()
    {
        var handler = new CapturingResponseHandler(new HttpResponseMessage(HttpStatusCode.OK));
        using var client = new HttpClient(handler);
        var executor = new HttpModelCompletionExecutor(client);

        ModelCompletionResult result = await executor.ExecuteAsync(
            new ModelRoute("anthropic-route", "anthropic", "claude-test", 0, true, new Uri("https://api.anthropic.test/v1/messages")),
            Encoding.UTF8.GetBytes(
                "{\"model\":\"claude-test\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}"),
            CancellationToken.None);

        Assert.False(result.Succeeded);
        Assert.Equal(501, result.StatusCode);
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
