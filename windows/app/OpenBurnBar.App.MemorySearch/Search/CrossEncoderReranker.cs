using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.MemorySearch.Search;

// PORTED (faithful) from AgentLens/Services/CrossEncoderReranker.swift
//   (RetrievalRerankProviding, NoOpRetrievalReranker, CrossEncoderPromptBuilder:
//    buildPrompt / rerankedResults / parseScores / truncateText, and the config clamps).
//
// SEAM SPLIT: the Swift concrete rerankers (OpenAICompatible HTTP + CLI) all build the SAME
// prompt, obtain model text from a transport, then parse+reorder. We split the network
// transport out behind ICrossEncoderCompletionClient (bucket B: real OpenAI/CLI transport) and
// keep the deterministic prompt-build → parse → reorder here, fully testable with a fake client.
//
// FAITHFUL PIPELINE NOTE: in the macOS pipeline the cross-encoder REORDERS candidates but never
// writes their relevance into `rerankScore`, and SearchService then unconditionally re-sorts by
// the hybrid `rerankScore` (SearchRankingMath.RankResults). So at the pipeline level the
// cross-encoder is inert on final ordering. This class ports the reranker COMPONENT exactly
// (scoring/ordering over a fake scorer, as the lane requires); wiring it into a pipeline should
// preserve — or deliberately fix — that macOS behavior. This is flagged, not silently changed.

/// <summary>One relevance score. Swift: <c>struct CrossEncoderRelevanceScore</c>. The
/// <c>chunk_id</c> is the 1-based PASSAGE index (as a string), not the real chunkID.</summary>
public sealed record CrossEncoderRelevanceScore(
    [property: JsonPropertyName("chunk_id")] string ChunkId,
    [property: JsonPropertyName("relevance")] double Relevance);

/// <summary>Built prompt payload. Swift: <c>struct CrossEncoderPromptPayload</c>.</summary>
public sealed record CrossEncoderPromptPayload(
    string SystemPrompt,
    string UserPrompt,
    IReadOnlyList<RetrievalResult> ScoredCandidates);

/// <summary>Raised when a model response cannot be parsed. Swift: <c>CrossEncoderRerankerError.parseError</c>.</summary>
public sealed class CrossEncoderParseException : Exception
{
    public CrossEncoderParseException(string detail)
        : base($"Failed to parse cross-encoder response: {detail}")
    {
    }
}

/// <summary>The reranker seam. Swift: <c>protocol RetrievalRerankProviding</c>.</summary>
public interface IRetrievalReranker
{
    Task<IReadOnlyList<RetrievalResult>> RerankAsync(
        string query,
        IReadOnlyList<RetrievalResult> candidates,
        int limit,
        CancellationToken cancellationToken = default);
}

/// <summary>Returns candidates unchanged. Swift: <c>final class NoOpRetrievalReranker</c>.</summary>
public sealed class NoOpRetrievalReranker : IRetrievalReranker
{
    public Task<IReadOnlyList<RetrievalResult>> RerankAsync(
        string query,
        IReadOnlyList<RetrievalResult> candidates,
        int limit,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        IReadOnlyList<RetrievalResult> result = candidates.Take(Math.Max(0, limit)).ToList();
        return Task.FromResult(result);
    }
}

/// <summary>
/// The injectable model-completion boundary (bucket B in prod: OpenAI-compatible HTTP or a CLI
/// bridge). Returns the completion TEXT the Swift <c>parseChatCompletionText</c> would extract.
/// Fakes return canned JSON so the reranker is exercised without a network.
/// </summary>
public interface ICrossEncoderCompletionClient
{
    Task<string> CompleteAsync(string systemPrompt, string userPrompt, CancellationToken cancellationToken = default);
}

/// <summary>
/// Prompt build + score parse + reorder. Swift: <c>enum CrossEncoderPromptBuilder</c>. Pure and
/// deterministic — the mission's "reranker scoring/ordering (fake scorer)" targets these statics.
/// </summary>
public static class CrossEncoderPromptBuilder
{
    private const string SystemPromptText =
        """
        You are a relevance scoring assistant. Given a user query and a list of passages,
        score each passage's relevance to the query on a scale from 0.0 to 1.0.

        Scoring guidelines:
        - 1.0: Passage directly answers or is highly relevant to the query
        - 0.7-0.9: Passage is relevant and contains useful information
        - 0.4-0.6: Passage mentions related topics but doesn't fully address the query
        - 0.1-0.3: Passage is tangentially related
        - 0.0: Passage is completely irrelevant

        Return your scores as a JSON array of objects with "chunk_id" (the passage number) and "relevance" (0.0-1.0).
        Only include passages you scored. Do not include passages with score 0.0.
        Never use tools or external resources. Reply with JSON only.
        """;

    private static readonly JsonSerializerOptions ScoreJsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    /// <summary>Builds the prompt. Swift: <c>buildPrompt(query:candidates:...)</c>. Returns null
    /// on empty query or no candidates.</summary>
    public static CrossEncoderPromptPayload? BuildPrompt(
        string query,
        IReadOnlyList<RetrievalResult> candidates,
        int maxCharsPerCandidate,
        int maxCandidatesPerRequest)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(candidates);
        string trimmedQuery = query.Trim();
        if (trimmedQuery.Length == 0)
        {
            return null;
        }

        var scoredCandidates = candidates.Take(Math.Max(0, maxCandidatesPerRequest)).ToList();
        if (scoredCandidates.Count == 0)
        {
            return null;
        }

        var lines = new List<string>
        {
            "User Query: " + trimmedQuery,
            string.Empty,
            "Passages:",
        };

        for (int index = 0; index < scoredCandidates.Count; index++)
        {
            var candidate = scoredCandidates[index];
            int passageNumber = index + 1;
            string title = candidate.Title.Trim();
            string preferredText = candidate.Snippet.Length != 0 ? candidate.Snippet : candidate.Title;
            string text = TruncateText(preferredText, maxCharsPerCandidate);

            lines.Add(string.Empty);
            lines.Add($"[{passageNumber}] Title: {title}");
            lines.Add($"[{passageNumber}] Content: {text}");
        }

        return new CrossEncoderPromptPayload(SystemPromptText, string.Join("\n", lines), scoredCandidates);
    }

    /// <summary>
    /// Reorders candidates by parsed relevance (keyed by 1-based passage number; missing → 0),
    /// tiebreak by original index, take limit, then append any candidates beyond the scored
    /// window unchanged. Swift: <c>rerankedResults(...)</c>.
    /// </summary>
    public static List<RetrievalResult> RerankedResults(
        IReadOnlyList<CrossEncoderRelevanceScore> scores,
        IReadOnlyList<RetrievalResult> scoredCandidates,
        IReadOnlyList<RetrievalResult> allCandidates,
        int limit,
        int maxCandidatesPerRequest)
    {
        ArgumentNullException.ThrowIfNull(scores);
        ArgumentNullException.ThrowIfNull(scoredCandidates);
        ArgumentNullException.ThrowIfNull(allCandidates);

        var scoreById = new Dictionary<string, double>(StringComparer.Ordinal);
        foreach (var score in scores)
        {
            // Swift builds a dict keyed by chunk_id; duplicate keys would trap there but the
            // model contract emits unique passage numbers. Last write wins here (benign).
            scoreById[score.ChunkId] = score.Relevance;
        }

        var indexed = new List<(RetrievalResult Result, double Relevance, int OriginalIndex)>(scoredCandidates.Count);
        for (int index = 0; index < scoredCandidates.Count; index++)
        {
            int passageNumber = index + 1;
            double relevance = scoreById.TryGetValue(passageNumber.ToString(CultureInfo.InvariantCulture), out double value)
                ? value
                : 0;
            indexed.Add((scoredCandidates[index], relevance, index));
        }

        indexed.Sort((lhs, rhs) =>
        {
            if (lhs.Relevance == rhs.Relevance)
            {
                return lhs.OriginalIndex.CompareTo(rhs.OriginalIndex);
            }

            // Relevance descending.
            return rhs.Relevance.CompareTo(lhs.Relevance);
        });

        var reranked = indexed.Take(Math.Max(0, limit)).Select(entry => entry.Result).ToList();

        if (allCandidates.Count > scoredCandidates.Count)
        {
            int skip = Math.Min(maxCandidatesPerRequest, allCandidates.Count);
            reranked.AddRange(allCandidates.Skip(skip));
        }

        return reranked;
    }

    /// <summary>
    /// Strips ```json / ``` fences, extracts the first '[' … last ']' slice, JSON-decodes, and
    /// filters to non-empty chunk_id with relevance in [0,1]. Swift: <c>parseScores(from:)</c>.
    /// </summary>
    public static List<CrossEncoderRelevanceScore> ParseScores(string content)
    {
        ArgumentNullException.ThrowIfNull(content);
        string jsonString = content.Trim();

        int jsonFence = jsonString.IndexOf("```json", StringComparison.OrdinalIgnoreCase);
        if (jsonFence >= 0)
        {
            int start = jsonFence + "```json".Length;
            int end = jsonString.IndexOf("```", start, StringComparison.OrdinalIgnoreCase);
            jsonString = end >= 0 ? jsonString[start..end] : jsonString[start..];
        }
        else
        {
            int fence = jsonString.IndexOf("```", StringComparison.OrdinalIgnoreCase);
            if (fence >= 0)
            {
                int start = fence + "```".Length;
                int end = jsonString.IndexOf("```", start, StringComparison.OrdinalIgnoreCase);
                if (end >= 0)
                {
                    jsonString = jsonString[start..end];
                }
            }
        }

        jsonString = jsonString.Trim();

        int startIndex = jsonString.IndexOf('[');
        int endIndex = jsonString.LastIndexOf(']');
        if (startIndex < 0 || endIndex < 0 || endIndex < startIndex)
        {
            throw new CrossEncoderParseException("No JSON array found in response");
        }

        string jsonArray = jsonString[startIndex..(endIndex + 1)];

        List<CrossEncoderRelevanceScore>? decoded;
        try
        {
            decoded = JsonSerializer.Deserialize<List<CrossEncoderRelevanceScore>>(jsonArray, ScoreJsonOptions);
        }
        catch (JsonException error)
        {
            throw new CrossEncoderParseException("JSON parsing failed: " + error.Message);
        }

        var results = new List<CrossEncoderRelevanceScore>();
        if (decoded == null)
        {
            return results;
        }

        foreach (var score in decoded)
        {
            if (!string.IsNullOrEmpty(score.ChunkId) && score.Relevance >= 0 && score.Relevance <= 1)
            {
                results.Add(score);
            }
        }

        return results;
    }

    /// <summary>Trim, then if longer than maxChars take first (maxChars-3) chars + "...".
    /// Swift: <c>truncateText(_:maxChars:)</c>. Grapheme-aware to match Swift counting.</summary>
    public static string TruncateText(string text, int maxChars)
    {
        ArgumentNullException.ThrowIfNull(text);
        string trimmed = text.Trim();
        var elements = EnumerateGraphemes(trimmed);
        if (elements.Count <= maxChars)
        {
            return trimmed;
        }

        int take = Math.Max(0, maxChars - 3);
        var builder = new StringBuilder();
        for (int i = 0; i < take && i < elements.Count; i++)
        {
            builder.Append(elements[i]);
        }

        builder.Append("...");
        return builder.ToString();
    }

    private static List<string> EnumerateGraphemes(string value)
    {
        var elements = new List<string>();
        var enumerator = StringInfo.GetTextElementEnumerator(value);
        while (enumerator.MoveNext())
        {
            elements.Add((string)enumerator.Current);
        }

        return elements;
    }
}

/// <summary>
/// Cross-encoder reranker over the injectable completion client. Swift peer: the shared logic of
/// <c>OpenAICompatibleCrossEncoderReranker</c> / <c>CLICrossEncoderReranker</c>. On empty prompt
/// or any parse failure it FALLS BACK to <c>candidates.prefix(limit)</c> (graceful, like the
/// pipeline's error path) rather than throwing.
/// </summary>
public sealed class CrossEncoderReranker : IRetrievalReranker
{
    private readonly ICrossEncoderCompletionClient _client;
    private readonly int _maxCharsPerCandidate;
    private readonly int _maxCandidatesPerRequest;

    public CrossEncoderReranker(
        ICrossEncoderCompletionClient client,
        int maxCharsPerCandidate = 512,
        int maxCandidatesPerRequest = 40)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        // Swift clamps: max(128, min(x, 1024)) and max(5, min(x, 64)).
        _maxCharsPerCandidate = Math.Max(128, Math.Min(maxCharsPerCandidate, 1024));
        _maxCandidatesPerRequest = Math.Max(5, Math.Min(maxCandidatesPerRequest, 64));
    }

    public async Task<IReadOnlyList<RetrievalResult>> RerankAsync(
        string query,
        IReadOnlyList<RetrievalResult> candidates,
        int limit,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        var payload = CrossEncoderPromptBuilder.BuildPrompt(
            query,
            candidates,
            _maxCharsPerCandidate,
            _maxCandidatesPerRequest);
        if (payload == null)
        {
            return candidates.Take(Math.Max(0, limit)).ToList();
        }

        string content = await _client.CompleteAsync(payload.SystemPrompt, payload.UserPrompt, cancellationToken)
            .ConfigureAwait(false);

        List<CrossEncoderRelevanceScore> scores;
        try
        {
            scores = CrossEncoderPromptBuilder.ParseScores(content);
        }
        catch (CrossEncoderParseException)
        {
            return candidates.Take(Math.Max(0, limit)).ToList();
        }

        return CrossEncoderPromptBuilder.RerankedResults(
            scores,
            payload.ScoredCandidates,
            candidates,
            limit,
            _maxCandidatesPerRequest);
    }
}
