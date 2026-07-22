using System;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class OllamaNativeProviderAdapterTests
{
    [Fact]
    public void NativeDetectionAndEndpointResolutionRespectOpenAiRoutes()
    {
        ModelRoute native = Route("http://127.0.0.1:11434");
        ModelRoute apiBase = Route("http://127.0.0.1:11434/api");
        ModelRoute openAi = Route("http://127.0.0.1:11434/v1/chat/completions");

        Assert.True(OllamaNativeProviderAdapter.IsNative(native));
        Assert.Equal("http://127.0.0.1:11434/api/chat", OllamaNativeProviderAdapter.ChatEndpoint(native.Endpoint!).ToString());
        Assert.Equal("http://127.0.0.1:11434/api/chat", OllamaNativeProviderAdapter.ChatEndpoint(apiBase.Endpoint!).ToString());
        Assert.False(OllamaNativeProviderAdapter.IsNative(openAi));
    }

    [Fact]
    public void RequestConversionMapsOptionsReasoningSchemaContentAndToolArguments()
    {
        const string request = """
            {
              "model":"client-alias",
              "stream":true,
              "max_tokens":64,
              "temperature":0.25,
              "reasoning_effort":"high",
              "tool_choice":"auto",
              "response_format":{"type":"json_schema","json_schema":{"schema":{"type":"object"}}},
              "messages":[
                {"role":"user","content":[{"type":"text","text":"hello"}]},
                {"role":"assistant","content":null,"tool_calls":[{"function":{"name":"lookup","arguments":"{\"q\":\"x\"}"}}]}
              ]
            }
            """;

        (byte[] body, bool stream) = OllamaNativeProviderAdapter.ToNativeRequest(
            Encoding.UTF8.GetBytes(request),
            "llama3.2");

        using JsonDocument document = JsonDocument.Parse(body);
        JsonElement root = document.RootElement;
        Assert.True(stream);
        Assert.Equal("llama3.2", root.GetProperty("model").GetString());
        Assert.Equal("object", root.GetProperty("format").GetProperty("type").GetString());
        Assert.Equal(64, root.GetProperty("options").GetProperty("num_predict").GetInt32());
        Assert.Equal(0.25, root.GetProperty("options").GetProperty("temperature").GetDouble());
        Assert.Equal("high", root.GetProperty("think").GetString());
        Assert.False(root.TryGetProperty("tool_choice", out _));
        Assert.Equal("hello", root.GetProperty("messages")[0].GetProperty("content").GetString());
        Assert.Equal(string.Empty, root.GetProperty("messages")[1].GetProperty("content").GetString());
        Assert.Equal(
            "x",
            root.GetProperty("messages")[1]
                .GetProperty("tool_calls")[0]
                .GetProperty("function")
                .GetProperty("arguments")
                .GetProperty("q")
                .GetString());
    }

    [Fact]
    public void BufferedResponseNormalizesToolCallsFinishReasonAndExactUsage()
    {
        const string native = """
            {
              "model":"llama3.2",
              "message":{"role":"assistant","content":"", "tool_calls":[{"function":{"name":"lookup","arguments":{"q":"x"}}}]},
              "done":true,
              "done_reason":"tool_calls",
              "prompt_eval_count":11,
              "eval_count":5
            }
            """;

        ModelCompletionResult result = OllamaNativeProviderAdapter.ToOpenAiResponse(
            Encoding.UTF8.GetBytes(native),
            "llama3.2",
            streamRequested: false);

        Assert.True(result.Succeeded);
        using JsonDocument document = JsonDocument.Parse(result.Body);
        JsonElement root = document.RootElement;
        JsonElement choice = root.GetProperty("choices")[0];
        Assert.Equal("tool_calls", choice.GetProperty("finish_reason").GetString());
        JsonElement call = choice.GetProperty("message").GetProperty("tool_calls")[0];
        Assert.Equal("lookup", call.GetProperty("function").GetProperty("name").GetString());
        Assert.Equal("{\"q\":\"x\"}", call.GetProperty("function").GetProperty("arguments").GetString());
        Assert.Equal(11, root.GetProperty("usage").GetProperty("prompt_tokens").GetInt32());
        Assert.Equal(5, root.GetProperty("usage").GetProperty("completion_tokens").GetInt32());
    }

    [Fact]
    public void NativeStreamNormalizesEventsAndCarriesFinalUsage()
    {
        const string native =
            "{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"hello\"},\"done\":false}\n"
            + "{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\",\"prompt_eval_count\":11,\"eval_count\":5}\n";

        ModelCompletionResult result = OllamaNativeProviderAdapter.ToOpenAiResponse(
            Encoding.UTF8.GetBytes(native),
            "llama3.2",
            streamRequested: true);

        string stream = Encoding.UTF8.GetString(result.Body);
        Assert.Equal("text/event-stream", result.ContentType);
        Assert.Contains("hello", stream, StringComparison.Ordinal);
        Assert.Contains("[DONE]", stream, StringComparison.Ordinal);
        GatewayTokenUsage usage = Assert.IsType<GatewayTokenUsage>(GatewayUsageParser.Parse(result));
        Assert.Equal(11, usage.InputTokens);
        Assert.Equal(5, usage.OutputTokens);
    }

    [Fact]
    public void TruncatedNativeStreamFailsClosed()
    {
        const string native =
            "{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"partial\"},\"done\":false}\n";

        Assert.ThrowsAny<Exception>(() => OllamaNativeProviderAdapter.ToOpenAiResponse(
            Encoding.UTF8.GetBytes(native),
            "llama3.2",
            streamRequested: true));
    }

    [Fact]
    public async Task HttpExecutorUsesNativeEndpointAndReturnsOpenAiShape()
    {
        var handler = new CapturingHandler(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(
                "{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"ready\"},\"done\":true,\"done_reason\":\"stop\"}"),
        });
        using var client = new HttpClient(handler);
        var executor = new HttpModelCompletionExecutor(client);

        ModelCompletionResult result = await executor.ExecuteAsync(
            Route("http://127.0.0.1:11434"),
            Encoding.UTF8.GetBytes("{\"model\":\"llama3.2\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}"));

        Assert.True(result.Succeeded);
        Assert.Equal("http://127.0.0.1:11434/api/chat", handler.RequestUri?.ToString());
        Assert.Contains("\"model\":\"llama3.2\"", handler.RequestBody, StringComparison.Ordinal);
        Assert.Equal(
            "ready",
            JsonDocument.Parse(result.Body).RootElement
                .GetProperty("choices")[0]
                .GetProperty("message")
                .GetProperty("content")
                .GetString());
    }

    private static ModelRoute Route(string endpoint) =>
        new("ollama", "ollama-local", "llama3.2", 0, true, new Uri(endpoint));

    private sealed class CapturingHandler : HttpMessageHandler
    {
        private readonly HttpResponseMessage _response;

        public CapturingHandler(HttpResponseMessage response) => _response = response;

        public Uri? RequestUri { get; private set; }
        public string RequestBody { get; private set; } = string.Empty;

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            RequestUri = request.RequestUri;
            RequestBody = request.Content is null
                ? string.Empty
                : await request.Content.ReadAsStringAsync(cancellationToken);
            return _response;
        }
    }
}
