using System;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.MemorySearch.Memory;
using Xunit;

namespace OpenBurnBar.App.MemorySearch.Tests;

public sealed class HttpMemoryExtractionLlmClientTests
{
    [Fact]
    public async Task OpenAiCompletionMatchesRequestContractAndReadsStringContent()
    {
        var handler = new StubHandler(
            _ => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = Json("{\"choices\":[{\"message\":{\"content\":\"{\\\"kind\\\":\\\"preference\\\"}\"}}]}"),
            });
        var client = NewClient(handler);

        string? result = await client.CallOpenAiCompatibleCompletionAsync(
            "https://example.test/v1",
            "secret-key",
            "gpt-5.5-mini",
            "system prompt",
            "user prompt",
            timeoutSeconds: 5,
            maxOutputTokens: 300,
            includeOpenRouterHeaders: true);

        Assert.Equal("{\"kind\":\"preference\"}", result);
        Assert.NotNull(handler.Request);
        Assert.Equal("https://example.test/v1/chat/completions", handler.Request!.RequestUri!.ToString());
        Assert.Equal("Bearer secret-key", handler.Request.Headers.Authorization!.ToString());
        Assert.Equal("OpenBurnBar", handler.Request.Headers.GetValues("X-Title").Single());
        using JsonDocument request = JsonDocument.Parse(handler.RequestBody!);
        Assert.Equal("gpt-5.5-mini", request.RootElement.GetProperty("model").GetString());
        Assert.Equal("high", request.RootElement.GetProperty("reasoning_effort").GetString());
        Assert.Equal("json_object", request.RootElement.GetProperty("response_format").GetProperty("type").GetString());
        Assert.Equal(0.1, request.RootElement.GetProperty("temperature").GetDouble());
    }

    [Fact]
    public async Task OpenAiCompletionJoinsStructuredContentBlocks()
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = Json("{\"choices\":[{\"message\":{\"content\":[{\"text\":\"one\"},{\"text\":\"two\"}]}}]}"),
        });

        string? result = await NewClient(handler).CallOpenAiCompatibleCompletionAsync(
            "https://example.test/v1", string.Empty, "model", "system", "user", 5, 20, false);

        Assert.Equal("onetwo", result);
    }

    [Fact]
    public async Task OpenAiFailuresReturnNullWithoutThrowing()
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.BadGateway)
        {
            Content = Json("{\"error\":{\"message\":\"upstream\"}}"),
        });
        var client = NewClient(handler);

        Assert.Null(await client.CallOpenAiCompatibleCompletionAsync(
            "https://example.test/v1", "secret-key", "model", "system", "user", 5, 20, false));
        Assert.Null(await client.CallOpenAiCompatibleCompletionAsync(
            "file:///tmp", "secret-key", "model", "system", "user", 5, 20, false));
        Assert.Null(await client.CallOpenAiCompatibleCompletionAsync(
            "https://example.test/v1", "secret-key", "model", new string('x', HttpMemoryExtractionLlmClient.MaxPromptCharacters + 1), "user", 5, 20, false));
    }

    [Fact]
    public async Task OllamaCompletionMatchesRequestContract()
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = Json("{\"response\":\"{\\\"memory\\\":true}\"}"),
        });
        var client = NewClient(handler);

        OllamaCompletionResult result = await client.CallOllamaAsync(
            "http://localhost:11434/",
            "llama3",
            "system prompt",
            "user prompt",
            timeoutSeconds: 5,
            maxOutputTokens: 250);

        Assert.Equal("{\"memory\":true}", result.Text);
        Assert.False(result.ShouldCooldown);
        Assert.Equal("http://localhost:11434/api/generate", handler.Request!.RequestUri!.ToString());
        using JsonDocument request = JsonDocument.Parse(handler.RequestBody!);
        Assert.False(request.RootElement.GetProperty("stream").GetBoolean());
        Assert.Equal("json", request.RootElement.GetProperty("format").GetString());
        Assert.Equal(250, request.RootElement.GetProperty("options").GetProperty("num_predict").GetInt32());
    }

    [Theory]
    [InlineData(HttpStatusCode.NotFound, true)]
    [InlineData(HttpStatusCode.RequestTimeout, true)]
    [InlineData((HttpStatusCode)429, true)]
    [InlineData(HttpStatusCode.BadRequest, false)]
    [InlineData(HttpStatusCode.InternalServerError, true)]
    public async Task OllamaStatusSetsCooldownHint(HttpStatusCode status, bool cooldown)
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(status)
        {
            Content = Json("{}"),
        });

        OllamaCompletionResult result = await NewClient(handler).CallOllamaAsync(
            "http://localhost:11434", "llama3", "system", "user", 5, 20);

        Assert.Null(result.Text);
        Assert.Equal(cooldown, result.ShouldCooldown);
    }

    [Fact]
    public async Task CancellationDoesNotRequestCooldown()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = Json("{\"response\":\"ignored\"}"),
        });

        OllamaCompletionResult result = await NewClient(handler).CallOllamaAsync(
            "http://localhost:11434", "llama3", "system", "user", 5, 20, cancellation.Token);

        Assert.Null(result.Text);
        Assert.False(result.ShouldCooldown);
    }

    private static HttpMemoryExtractionLlmClient NewClient(StubHandler handler)
        => new(new HttpClient(handler));

    private static StringContent Json(string body)
        => new(body, Encoding.UTF8, "application/json");

    private sealed class StubHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, HttpResponseMessage> _response;

        public StubHandler(Func<HttpRequestMessage, HttpResponseMessage> response)
        {
            _response = response;
        }

        public HttpRequestMessage? Request { get; private set; }

        public string? RequestBody { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Request = request;
            RequestBody = request.Content is null
                ? null
                : await request.Content.ReadAsStringAsync(cancellationToken);
            return _response(request);
        }
    }
}
