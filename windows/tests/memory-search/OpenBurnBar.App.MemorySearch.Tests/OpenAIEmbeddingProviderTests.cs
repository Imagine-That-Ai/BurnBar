using System;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.MemorySearch.Search;
using Xunit;

namespace OpenBurnBar.App.MemorySearch.Tests;

public sealed class OpenAIEmbeddingProviderTests
{
    [Fact]
    public void SupportedModelDescriptorMatchesMacContract()
    {
        var provider = new OpenAIEmbeddingProvider(
            apiKey: "key",
            modelName: "text-embedding-3-small",
            baseUrl: "https://example.test/v1",
            httpClient: new HttpClient(new StubHandler(HttpStatusCode.OK, "{}")));

        Assert.Equal("openai", provider.Descriptor.Provider);
        Assert.Equal("text-embedding-3-small", provider.Descriptor.ModelName);
        Assert.Equal(1536, provider.Descriptor.Dimensions);
        Assert.Equal(1536, OpenAIEmbeddingProvider.DimensionsFor(" TEXT-EMBEDDING-3-SMALL "));
    }

    [Fact]
    public async Task SuccessfulBatchPreservesIndexedOrderAndRequestContract()
    {
        int dimensions = OpenAIEmbeddingProvider.DimensionsFor("text-embedding-3-small");
        string body = JsonSerializer.Serialize(new
        {
            data = new[]
            {
                new { index = 1, embedding = Enumerable.Repeat(2f, dimensions).ToArray() },
                new { index = 0, embedding = Enumerable.Repeat(1f, dimensions).ToArray() },
            },
        });
        var handler = new StubHandler(HttpStatusCode.OK, body);
        var provider = NewProvider(handler);

        var vectors = await provider.EmbeddingsAsync(new[] { " first ", "second" });

        Assert.Equal(2, vectors.Count);
        Assert.Equal(1f, vectors[0][0]);
        Assert.Equal(2f, vectors[1][0]);
        Assert.NotNull(handler.Request);
        Assert.Equal("https://example.test/v1/embeddings", handler.Request!.RequestUri!.ToString());
        Assert.Equal("Bearer key", handler.Request.Headers.Authorization!.ToString());

        using var requestJson = JsonDocument.Parse(handler.RequestBody!);
        Assert.Equal("text-embedding-3-small", requestJson.RootElement.GetProperty("model").GetString());
        Assert.Equal("float", requestJson.RootElement.GetProperty("encoding_format").GetString());
        Assert.Equal("first", requestJson.RootElement.GetProperty("input")[0].GetString());
    }

    [Fact]
    public async Task EmptyBatchAndBlankSingleInputDoNotTouchTransport()
    {
        var handler = new StubHandler(HttpStatusCode.OK, "{}");
        var provider = NewProvider(handler);

        Assert.Empty(await provider.EmbeddingsAsync(Array.Empty<string>()));
        Assert.Empty(await provider.EmbeddingAsync("   "));
        Assert.Null(handler.Request);
    }

    [Fact]
    public async Task MissingApiKeyFailsBeforeTransport()
    {
        var handler = new StubHandler(HttpStatusCode.OK, "{}");
        var provider = NewProvider(handler, apiKey: " ");

        var exception = await Assert.ThrowsAsync<OpenAIEmbeddingProviderException>(
            () => provider.EmbeddingAsync("query"));

        Assert.Equal(OpenAIEmbeddingFailureKind.MissingApiKey, exception.Kind);
        Assert.Null(handler.Request);
    }

    [Fact]
    public void UnsupportedModelAndBaseUrlFailClosed()
    {
        var model = Assert.Throws<OpenAIEmbeddingProviderException>(
            () => new OpenAIEmbeddingProvider("key", "unknown", baseUrl: "https://example.test/v1"));
        var url = Assert.Throws<OpenAIEmbeddingProviderException>(
            () => new OpenAIEmbeddingProvider("key", "text-embedding-3-small", baseUrl: "file:///tmp"));

        Assert.Equal(OpenAIEmbeddingFailureKind.UnsupportedModel, model.Kind);
        Assert.Equal(OpenAIEmbeddingFailureKind.InvalidBaseUrl, url.Kind);
    }

    [Fact]
    public async Task InvalidVectorShapeFailsClosed()
    {
        var handler = new StubHandler(HttpStatusCode.OK, "{\"data\":[{\"index\":0,\"embedding\":[1]}]}");
        var provider = NewProvider(handler);

        var exception = await Assert.ThrowsAsync<OpenAIEmbeddingProviderException>(
            () => provider.EmbeddingAsync("query"));

        Assert.Equal(OpenAIEmbeddingFailureKind.InvalidResponse, exception.Kind);
    }

    [Fact]
    public async Task InvalidItemIndexesFailClosed()
    {
        int dimensions = OpenAIEmbeddingProvider.DimensionsFor("text-embedding-3-small");
        string body = JsonSerializer.Serialize(new
        {
            data = new[]
            {
                new { index = 4, embedding = Enumerable.Repeat(1f, dimensions).ToArray() },
                new { index = 5, embedding = Enumerable.Repeat(1f, dimensions).ToArray() },
            },
        });
        var provider = NewProvider(new StubHandler(HttpStatusCode.OK, body));

        var exception = await Assert.ThrowsAsync<OpenAIEmbeddingProviderException>(
            () => provider.EmbeddingsAsync(new[] { "one", "two" }));

        Assert.Equal(OpenAIEmbeddingFailureKind.InvalidResponse, exception.Kind);
    }

    [Fact]
    public async Task HttpErrorIncludesBoundedProviderMessageButNeverSecret()
    {
        var handler = new StubHandler(
            HttpStatusCode.Unauthorized,
            "{\"error\":{\"message\":\"bad key\"}}");
        var provider = NewProvider(handler, apiKey: "super-secret-token");

        var exception = await Assert.ThrowsAsync<OpenAIEmbeddingProviderException>(
            () => provider.EmbeddingAsync("query"));

        Assert.Equal(OpenAIEmbeddingFailureKind.UnexpectedResponse, exception.Kind);
        Assert.Equal(401, exception.StatusCode);
        Assert.Contains("bad key", exception.Message);
        Assert.DoesNotContain("super-secret-token", exception.ToString());
    }

    [Fact]
    public async Task OversizedInputFailsBeforeTransport()
    {
        var handler = new StubHandler(HttpStatusCode.OK, "{}");
        var provider = NewProvider(handler);

        var exception = await Assert.ThrowsAsync<OpenAIEmbeddingProviderException>(
            () => provider.EmbeddingAsync(new string('x', OpenAIEmbeddingProvider.MaxTextCharacters + 1)));

        Assert.Equal(OpenAIEmbeddingFailureKind.InputTooLarge, exception.Kind);
        Assert.Null(handler.Request);
    }

    private static OpenAIEmbeddingProvider NewProvider(StubHandler handler, string apiKey = "key")
        => new(
            apiKey,
            "text-embedding-3-small",
            baseUrl: "https://example.test/v1",
            httpClient: new HttpClient(handler));

    private sealed class StubHandler : HttpMessageHandler
    {
        private readonly HttpStatusCode _statusCode;
        private readonly string _body;

        public StubHandler(HttpStatusCode statusCode, string body)
        {
            _statusCode = statusCode;
            _body = body;
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
            return new HttpResponseMessage(_statusCode)
            {
                Content = new StringContent(_body, Encoding.UTF8, "application/json"),
            };
        }
    }
}
