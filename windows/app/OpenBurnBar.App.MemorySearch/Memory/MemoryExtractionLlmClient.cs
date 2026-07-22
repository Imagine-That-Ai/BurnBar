using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.MemorySearch.Memory;

// PORTED (seam) from AgentLens/Services/Memory/MemoryExtractionLLMClient.swift.
//
// This is THE injectable network boundary for memory extraction. The Swift struct never throws —
// it returns null on any failure. HttpMemoryExtractionLlmClient implements the bounded HttpClient
// POST to an OpenAI-compatible /chat/completions or Ollama /api/generate; a fake returning canned
// JSON makes the whole extraction pipeline testable without a network. All cooldown/retry/progress
// bookkeeping lives in the CALLER (the transcript extractor), not in this seam.

/// <summary>Result of an Ollama completion. Swift: the <c>(text:shouldCooldown:)</c> tuple.</summary>
public readonly record struct OllamaCompletionResult(string? Text, bool ShouldCooldown);

/// <summary>The memory-extraction LLM boundary. Swift: <c>struct MemoryExtractionLLMClient</c>.</summary>
public interface IMemoryExtractionLlmClient
{
    /// <summary>
    /// POST to an OpenAI-compatible <c>/chat/completions</c>. Body: model, [system, user] messages,
    /// temperature 0.1, max_tokens, response_format json_object (and reasoning_effort "high" when
    /// the model id contains "gpt-5.5"). Returns the parsed content, or null on any failure.
    /// Swift: <c>callOpenAICompatibleCompletion(...)</c>.
    /// </summary>
    Task<string?> CallOpenAiCompatibleCompletionAsync(
        string baseUrl,
        string apiKey,
        string model,
        string systemPrompt,
        string userPrompt,
        double timeoutSeconds,
        int maxOutputTokens,
        bool includeOpenRouterHeaders,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// POST to Ollama <c>/api/generate</c> (stream false, format json, options temperature 0.1 /
    /// num_predict). Returns the response text plus a cooldown hint (transport error, or status
    /// 404/408/429/&gt;=500). Swift: <c>callOllama(...)</c>.
    /// </summary>
    Task<OllamaCompletionResult> CallOllamaAsync(
        string baseUrl,
        string model,
        string systemPrompt,
        string userPrompt,
        double timeoutSeconds,
        int maxOutputTokens,
        CancellationToken cancellationToken = default);
}
