using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.MemorySearch.Search;

/// <summary>Failure categories for the OpenAI embedding transport.</summary>
public enum OpenAIEmbeddingFailureKind
{
    MissingApiKey,
    UnsupportedModel,
    InvalidBaseUrl,
    InputTooLarge,
    UnexpectedResponse,
    InvalidResponse,
    TransportFailure,
}

/// <summary>
/// A bounded, provider-backed embedding failure. The exception never includes
/// the bearer token or request body in its message.
/// </summary>
public sealed class OpenAIEmbeddingProviderException : Exception
{
    public OpenAIEmbeddingProviderException(
        OpenAIEmbeddingFailureKind kind,
        string message,
        int? statusCode = null,
        Exception? innerException = null)
        : base(message, innerException)
    {
        Kind = kind;
        StatusCode = statusCode;
    }

    public OpenAIEmbeddingFailureKind Kind { get; }

    public int? StatusCode { get; }
}

/// <summary>
/// OpenAI-compatible embeddings adapter matching the macOS provider contract.
/// The transport is injectable so provider behavior can be exercised without
/// credentials or network access. Empty input is a no-op; all other input and
/// response sizes are bounded before vectors reach the index.
/// </summary>
public sealed class OpenAIEmbeddingProvider : IChunkEmbeddingProvider, IQueryEmbeddingProvider
{
    public const int MaxBatchItems = 128;
    public const int MaxTextCharacters = 64 * 1024;
    public const int MaxResponseBytes = 32 * 1024 * 1024;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
    };

    private readonly string _apiKey;
    private readonly Uri _endpoint;
    private readonly HttpClient _httpClient;

    public OpenAIEmbeddingProvider(
        string apiKey,
        string modelName,
        string versionTag = "openai-v1",
        string chunkerVersion = "openburnbar-chunker-v1",
        string normalizationVersion = "unit-l2-v1",
        string promptVersion = "plain-text-v1",
        string baseUrl = "https://api.openai.com/v1",
        HttpClient? httpClient = null)
    {
        int dimensions = DimensionsFor(modelName);
        if (!Uri.TryCreate((baseUrl ?? string.Empty).Trim().TrimEnd('/'), UriKind.Absolute, out var parsed)
            || parsed is null
            || (parsed.Scheme != Uri.UriSchemeHttps
                && (parsed.Scheme != Uri.UriSchemeHttp || !parsed.IsLoopback))
            || !string.IsNullOrEmpty(parsed.UserInfo)
            || !string.IsNullOrEmpty(parsed.Query)
            || !string.IsNullOrEmpty(parsed.Fragment))
        {
            throw new OpenAIEmbeddingProviderException(
                OpenAIEmbeddingFailureKind.InvalidBaseUrl,
                "The OpenAI embeddings endpoint URL is invalid.");
        }

        _apiKey = (apiKey ?? string.Empty).Trim();
        _endpoint = new Uri(parsed, parsed.AbsolutePath.TrimEnd('/') + "/embeddings");
        _httpClient = httpClient ?? new HttpClient();
        Descriptor = new EmbeddingModelDescriptor(
            provider: "openai",
            modelName: modelName,
            dimensions: dimensions,
            distanceMetric: EmbeddingDistanceMetric.Cosine,
            versionTag: versionTag,
            chunkerVersion: chunkerVersion,
            normalizationVersion: normalizationVersion,
            promptVersion: promptVersion);
    }

    public static IReadOnlyList<string> SupportedModels { get; } = new[]
    {
        "text-embedding-3-small",
        "text-embedding-3-large",
        "text-embedding-ada-002",
    };

    public EmbeddingModelDescriptor Descriptor { get; }

    public Task<float[]> EmbeddingAsync(string text)
        => EmbeddingAsync(text, CancellationToken.None);

    public async Task<float[]> EmbeddingAsync(string text, CancellationToken cancellationToken)
    {
        var vectors = await EmbeddingsAsync(new[] { text }, cancellationToken).ConfigureAwait(false);
        return vectors.Count == 0 ? Array.Empty<float>() : vectors[0];
    }

    /// <summary>Embeds a bounded batch while preserving the provider's item order.</summary>
    public async Task<IReadOnlyList<float[]>> EmbeddingsAsync(
        IReadOnlyList<string> texts,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(texts);

        var input = new List<string>(Math.Min(texts.Count, MaxBatchItems));
        foreach (var text in texts)
        {
            var normalized = (text ?? string.Empty).Trim();
            if (normalized.Length == 0)
            {
                continue;
            }

            if (normalized.Length > MaxTextCharacters)
            {
                throw new OpenAIEmbeddingProviderException(
                    OpenAIEmbeddingFailureKind.InputTooLarge,
                    $"Embedding input exceeds the {MaxTextCharacters} character limit.");
            }

            input.Add(normalized);
            if (input.Count > MaxBatchItems)
            {
                throw new OpenAIEmbeddingProviderException(
                    OpenAIEmbeddingFailureKind.InputTooLarge,
                    $"Embedding batches are limited to {MaxBatchItems} items.");
            }
        }

        if (input.Count == 0)
        {
            return Array.Empty<float[]>();
        }

        if (_apiKey.Length == 0)
        {
            throw new OpenAIEmbeddingProviderException(
                OpenAIEmbeddingFailureKind.MissingApiKey,
                "OpenAI indexing requires an API key.");
        }

        var payload = new EmbeddingRequest
        {
            Model = Descriptor.ModelName,
            Input = input,
            EncodingFormat = "float",
        };
        byte[] requestBytes = JsonSerializer.SerializeToUtf8Bytes(payload, JsonOptions);
        using var request = new HttpRequestMessage(HttpMethod.Post, _endpoint)
        {
            Content = new ByteArrayContent(requestBytes),
        };
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);

        try
        {
            using var response = await _httpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            byte[] responseBytes = await ReadBoundedAsync(response.Content, cancellationToken).ConfigureAwait(false);

            if (!response.IsSuccessStatusCode)
            {
                throw new OpenAIEmbeddingProviderException(
                    OpenAIEmbeddingFailureKind.UnexpectedResponse,
                    FormatStatusMessage((int)response.StatusCode, TryReadErrorMessage(responseBytes)),
                    (int)response.StatusCode);
            }

            return DecodeVectors(responseBytes, input.Count);
        }
        catch (OpenAIEmbeddingProviderException)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (HttpRequestException exception)
        {
            throw new OpenAIEmbeddingProviderException(
                OpenAIEmbeddingFailureKind.TransportFailure,
                "OpenAI embeddings transport failed.",
                innerException: exception);
        }
    }

    public static int DimensionsFor(string modelName)
    {
        var normalized = (modelName ?? string.Empty).Trim().ToLowerInvariant();
        return normalized switch
        {
            "text-embedding-3-small" => 1536,
            "text-embedding-3-large" => 3072,
            "text-embedding-ada-002" => 1536,
            _ => throw new OpenAIEmbeddingProviderException(
                OpenAIEmbeddingFailureKind.UnsupportedModel,
                $"Unsupported OpenAI embedding model: {modelName ?? string.Empty}"),
        };
    }

    private IReadOnlyList<float[]> DecodeVectors(byte[] responseBytes, int expectedCount)
    {
        EmbeddingResponse? response;
        try
        {
            response = JsonSerializer.Deserialize<EmbeddingResponse>(responseBytes, JsonOptions);
        }
        catch (JsonException exception)
        {
            throw new OpenAIEmbeddingProviderException(
                OpenAIEmbeddingFailureKind.InvalidResponse,
                "OpenAI embeddings returned invalid JSON.",
                innerException: exception);
        }

        if (response?.Data is null || response.Data.Count != expectedCount)
        {
            throw new OpenAIEmbeddingProviderException(
                OpenAIEmbeddingFailureKind.InvalidResponse,
                "OpenAI embeddings returned an unexpected item count.");
        }

        var items = response.Data;
        if (items.All(static item => item.Index.HasValue))
        {
            var indexes = items.Select(static item => item.Index!.Value).ToArray();
            if (indexes.Any(index => index < 0 || index >= expectedCount)
                || indexes.Distinct().Count() != expectedCount)
            {
                throw new OpenAIEmbeddingProviderException(
                    OpenAIEmbeddingFailureKind.InvalidResponse,
                    "OpenAI embeddings returned invalid item indexes.");
            }

            items = items.OrderBy(static item => item.Index).ToList();
        }

        var vectors = new List<float[]>(items.Count);
        foreach (var item in items)
        {
            if (item.Embedding is null || item.Embedding.Count != Descriptor.Dimensions
                || item.Embedding.Any(static value => !float.IsFinite(value)))
            {
                throw new OpenAIEmbeddingProviderException(
                    OpenAIEmbeddingFailureKind.InvalidResponse,
                    "OpenAI embeddings returned an invalid vector.");
            }

            vectors.Add(item.Embedding.ToArray());
        }

        return vectors;
    }

    private static async Task<byte[]> ReadBoundedAsync(HttpContent content, CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength is > MaxResponseBytes)
        {
            throw new OpenAIEmbeddingProviderException(
                OpenAIEmbeddingFailureKind.InvalidResponse,
                "OpenAI embeddings response exceeds the size limit.");
        }

        await using var stream = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var buffer = new MemoryStream();
        var chunk = new byte[81920];
        while (true)
        {
            int read = await stream.ReadAsync(chunk.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            if (buffer.Length + read > MaxResponseBytes)
            {
                throw new OpenAIEmbeddingProviderException(
                    OpenAIEmbeddingFailureKind.InvalidResponse,
                    "OpenAI embeddings response exceeds the size limit.");
            }

            buffer.Write(chunk, 0, read);
        }

        return buffer.ToArray();
    }

    private static string? TryReadErrorMessage(byte[] responseBytes)
    {
        try
        {
            var error = JsonSerializer.Deserialize<EmbeddingResponse>(responseBytes, JsonOptions)?.Error?.Message;
            return string.IsNullOrWhiteSpace(error) ? null : error.Trim()[..Math.Min(error.Trim().Length, 512)];
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string FormatStatusMessage(int statusCode, string? message)
        => string.IsNullOrEmpty(message)
            ? $"OpenAI embeddings request failed with status {statusCode}."
            : $"OpenAI embeddings request failed ({statusCode}): {message}";

    private sealed class EmbeddingRequest
    {
        [JsonPropertyName("model")]
        public string Model { get; set; } = string.Empty;

        [JsonPropertyName("input")]
        public IReadOnlyList<string> Input { get; set; } = Array.Empty<string>();

        [JsonPropertyName("encoding_format")]
        public string EncodingFormat { get; set; } = string.Empty;
    }

    private sealed class EmbeddingResponse
    {
        [JsonPropertyName("data")]
        public List<EmbeddingItem>? Data { get; set; }

        [JsonPropertyName("error")]
        public ApiError? Error { get; set; }
    }

    private sealed class EmbeddingItem
    {
        [JsonPropertyName("index")]
        public int? Index { get; set; }

        [JsonPropertyName("embedding")]
        public List<float>? Embedding { get; set; }
    }

    private sealed class ApiError
    {
        [JsonPropertyName("message")]
        public string? Message { get; set; }
    }
}
