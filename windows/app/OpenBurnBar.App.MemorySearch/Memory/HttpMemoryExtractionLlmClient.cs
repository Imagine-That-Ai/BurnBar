using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.MemorySearch.Memory;

/// <summary>
/// Stateless bounded HTTP implementation of the memory-extraction LLM seam.
/// It mirrors the macOS OpenAI-compatible and Ollama request contracts, never
/// logs credentials, and returns null/failure tuples rather than throwing for
/// provider, payload, response, or transport errors.
/// </summary>
public sealed class HttpMemoryExtractionLlmClient : IMemoryExtractionLlmClient
{
    public const int MaxPromptCharacters = 128 * 1024;
    public const int MaxModelCharacters = 256;
    public const int MaxResponseBytes = 8 * 1024 * 1024;
    public const int MaxOutputTokens = 32 * 1024;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly HttpClient _httpClient;

    public HttpMemoryExtractionLlmClient(HttpClient? httpClient = null)
    {
        _httpClient = httpClient ?? new HttpClient();
    }

    public async Task<string?> CallOpenAiCompatibleCompletionAsync(
        string baseUrl,
        string apiKey,
        string model,
        string systemPrompt,
        string userPrompt,
        double timeoutSeconds,
        int maxOutputTokens,
        bool includeOpenRouterHeaders,
        CancellationToken cancellationToken = default)
    {
        if (!TryEndpoint(baseUrl, "/chat/completions", out Uri? endpoint)
            || !ValidModel(model)
            || !ValidPrompt(systemPrompt)
            || !ValidPrompt(userPrompt)
            || !ValidTimeout(timeoutSeconds)
            || maxOutputTokens is < 1 or > MaxOutputTokens)
        {
            return null;
        }

        var message = new CompletionRequest
        {
            Model = model.Trim(),
            Messages = new[]
            {
                new CompletionMessage { Role = "system", Content = systemPrompt },
                new CompletionMessage { Role = "user", Content = userPrompt },
            },
            Temperature = 0.1,
            MaxTokens = maxOutputTokens,
            ResponseFormat = new ResponseFormat { Type = "json_object" },
            ReasoningEffort = model.Trim().Contains("gpt-5.5", StringComparison.OrdinalIgnoreCase)
                ? "high"
                : null,
        };

        try
        {
            byte[] body = JsonSerializer.SerializeToUtf8Bytes(message, JsonOptions);
            using var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
            {
                Content = new ByteArrayContent(body),
            };
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            string trimmedKey = (apiKey ?? string.Empty).Trim();
            if (trimmedKey.Length > 0)
            {
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", trimmedKey);
            }

            if (includeOpenRouterHeaders)
            {
                request.Headers.TryAddWithoutValidation("X-Title", "OpenBurnBar");
            }

            using var timeout = CreateTimeout(timeoutSeconds, cancellationToken);
            using HttpResponseMessage response = await _httpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                timeout.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            byte[] responseBody = await ReadBoundedAsync(response, timeout.Token).ConfigureAwait(false);
            return ParseOpenAiContent(responseBody);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (HttpRequestException)
        {
            return null;
        }
        catch (JsonException)
        {
            return null;
        }
        catch (InvalidOperationException)
        {
            return null;
        }
    }

    public async Task<OllamaCompletionResult> CallOllamaAsync(
        string baseUrl,
        string model,
        string systemPrompt,
        string userPrompt,
        double timeoutSeconds,
        int maxOutputTokens,
        CancellationToken cancellationToken = default)
    {
        if (!TryEndpoint(baseUrl, "/api/generate", out Uri? endpoint)
            || !ValidModel(model)
            || !ValidPrompt(systemPrompt)
            || !ValidPrompt(userPrompt)
            || !ValidTimeout(timeoutSeconds)
            || maxOutputTokens is < 1 or > MaxOutputTokens)
        {
            return new OllamaCompletionResult(null, false);
        }

        var requestPayload = new OllamaRequest
        {
            Model = model.Trim(),
            System = systemPrompt,
            Prompt = userPrompt,
            Stream = false,
            Format = "json",
            Options = new OllamaOptions { Temperature = 0.1, NumPredict = maxOutputTokens },
        };

        try
        {
            byte[] body = JsonSerializer.SerializeToUtf8Bytes(requestPayload, JsonOptions);
            using var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
            {
                Content = new ByteArrayContent(body),
            };
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            using var timeout = CreateTimeout(timeoutSeconds, cancellationToken);
            using HttpResponseMessage response = await _httpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                timeout.Token).ConfigureAwait(false);
            bool shouldCooldown = ShouldCooldown((int)response.StatusCode);
            if (!response.IsSuccessStatusCode)
            {
                return new OllamaCompletionResult(null, shouldCooldown);
            }

            byte[] responseBody = await ReadBoundedAsync(response, timeout.Token).ConfigureAwait(false);
            using JsonDocument document = JsonDocument.Parse(responseBody);
            if (!document.RootElement.TryGetProperty("response", out JsonElement text)
                || text.ValueKind != JsonValueKind.String)
            {
                return new OllamaCompletionResult(null, false);
            }

            string value = text.GetString() ?? string.Empty;
            return value.Length == 0
                ? new OllamaCompletionResult(null, false)
                : new OllamaCompletionResult(value, false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new OllamaCompletionResult(null, false);
        }
        catch (OperationCanceledException)
        {
            return new OllamaCompletionResult(null, true);
        }
        catch (HttpRequestException)
        {
            return new OllamaCompletionResult(null, true);
        }
        catch (JsonException)
        {
            return new OllamaCompletionResult(null, false);
        }
        catch (InvalidOperationException)
        {
            return new OllamaCompletionResult(null, false);
        }
    }

    private static string? ParseOpenAiContent(byte[] responseBody)
    {
        using JsonDocument document = JsonDocument.Parse(responseBody);
        if (!document.RootElement.TryGetProperty("choices", out JsonElement choices)
            || choices.ValueKind != JsonValueKind.Array
            || choices.GetArrayLength() == 0)
        {
            return null;
        }

        JsonElement first = choices[0];
        if (!first.TryGetProperty("message", out JsonElement message)
            || message.ValueKind != JsonValueKind.Object
            || !message.TryGetProperty("content", out JsonElement content))
        {
            return null;
        }

        if (content.ValueKind == JsonValueKind.String)
        {
            string value = content.GetString() ?? string.Empty;
            return value.Length == 0 ? null : value;
        }

        if (content.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        var builder = new StringBuilder();
        foreach (JsonElement block in content.EnumerateArray())
        {
            if (block.ValueKind == JsonValueKind.Object
                && block.TryGetProperty("text", out JsonElement text)
                && text.ValueKind == JsonValueKind.String)
            {
                builder.Append(text.GetString());
            }
        }

        return builder.Length == 0 ? null : builder.ToString();
    }

    private static CancellationTokenSource CreateTimeout(
        double timeoutSeconds,
        CancellationToken callerToken)
    {
        var timeout = CancellationTokenSource.CreateLinkedTokenSource(callerToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
        return timeout;
    }

    private static async Task<byte[]> ReadBoundedAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        if (response.Content.Headers.ContentLength is > MaxResponseBytes)
        {
            throw new InvalidOperationException("llm_response_too_large");
        }

        await using Stream stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var bytes = new System.IO.MemoryStream();
        var chunk = new byte[81920];
        while (true)
        {
            int read = await stream.ReadAsync(chunk.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                return bytes.ToArray();
            }

            if (bytes.Length + read > MaxResponseBytes)
            {
                throw new InvalidOperationException("llm_response_too_large");
            }

            bytes.Write(chunk, 0, read);
        }
    }

    private static bool TryEndpoint(string baseUrl, string suffix, out Uri? endpoint)
    {
        endpoint = null;
        string trimmed = (baseUrl ?? string.Empty).Trim().TrimEnd('/');
        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out Uri? parsed)
            || parsed is null
            || (parsed.Scheme != Uri.UriSchemeHttp && parsed.Scheme != Uri.UriSchemeHttps)
            || !string.IsNullOrEmpty(parsed.UserInfo)
            || !string.IsNullOrEmpty(parsed.Query)
            || !string.IsNullOrEmpty(parsed.Fragment))
        {
            return false;
        }

        endpoint = new Uri(parsed, parsed.AbsolutePath.TrimEnd('/') + suffix);
        return true;
    }

    private static bool ValidModel(string model)
        => !string.IsNullOrWhiteSpace(model) && model.Trim().Length <= MaxModelCharacters;

    private static bool ValidPrompt(string prompt)
        => prompt is not null && prompt.Length <= MaxPromptCharacters;

    private static bool ValidTimeout(double seconds)
        => double.IsFinite(seconds) && seconds is >= 0.1 and <= 300;

    private static bool ShouldCooldown(int statusCode)
        => statusCode is 404 or 408 or 429 || statusCode >= 500;

    private sealed class CompletionRequest
    {
        [JsonPropertyName("model")] public string Model { get; set; } = string.Empty;
        [JsonPropertyName("messages")] public IReadOnlyList<CompletionMessage> Messages { get; set; } = Array.Empty<CompletionMessage>();
        [JsonPropertyName("temperature")] public double Temperature { get; set; }
        [JsonPropertyName("max_tokens")] public int MaxTokens { get; set; }
        [JsonPropertyName("response_format")] public ResponseFormat ResponseFormat { get; set; } = new();
        [JsonPropertyName("reasoning_effort")] public string? ReasoningEffort { get; set; }
    }

    private sealed class CompletionMessage
    {
        [JsonPropertyName("role")] public string Role { get; set; } = string.Empty;
        [JsonPropertyName("content")] public string Content { get; set; } = string.Empty;
    }

    private sealed class ResponseFormat
    {
        [JsonPropertyName("type")] public string Type { get; set; } = string.Empty;
    }

    private sealed class OllamaRequest
    {
        [JsonPropertyName("model")] public string Model { get; set; } = string.Empty;
        [JsonPropertyName("system")] public string System { get; set; } = string.Empty;
        [JsonPropertyName("prompt")] public string Prompt { get; set; } = string.Empty;
        [JsonPropertyName("stream")] public bool Stream { get; set; }
        [JsonPropertyName("format")] public string Format { get; set; } = string.Empty;
        [JsonPropertyName("options")] public OllamaOptions Options { get; set; } = new();
    }

    private sealed class OllamaOptions
    {
        [JsonPropertyName("temperature")] public double Temperature { get; set; }
        [JsonPropertyName("num_predict")] public int NumPredict { get; set; }
    }
}
