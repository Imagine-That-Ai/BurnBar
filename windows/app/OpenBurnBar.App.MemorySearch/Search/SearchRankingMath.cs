using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace OpenBurnBar.App.MemorySearch.Search;

// PORTED (faithful) from AgentLens/Services/Search/SearchService+Ranking.swift (lines 99-201)
// plus the two rerankScore blend formulas + final sort/dedup from
// AgentLens/Services/Search/SearchService+Retrieval.swift (lines 381-509).
//
// These are pure deterministic functions. `recencyScore` takes an INJECTABLE clock
// (Func<DateTimeOffset>) mirroring the Swift `nowProvider: @Sendable () -> Date`. The final
// hybrid `rerankScore` (RankResults' sort key) is what determines ordering and is surfaced as
// the UI `rank`; the cross-encoder does NOT feed into it (see CrossEncoderReranker.cs header).

/// <summary>Per-candidate lexical/semantic accumulator. Swift: <c>struct CandidateAccumulator</c>.</summary>
public sealed class CandidateAccumulator
{
    public double? LexicalRank { get; set; }

    public double? SemanticScore { get; set; }

    public string? LexicalSnippet { get; set; }
}

/// <summary>The portable ranking math. Swift: the nested + static functions on <c>SearchService</c>.</summary>
public static class SearchRankingMath
{
    // Cached, culture-invariant regexes for the sensitive-lookup gate (Swift patterns verbatim).
    private static readonly Regex[] SensitivePatterns =
    {
        new(@"\bapi[\s_\-]?keys?\b", RegexOptions.Compiled | RegexOptions.CultureInvariant),
        new(@"\btoken\b", RegexOptions.Compiled | RegexOptions.CultureInvariant),
        new(@"\bsecret\b", RegexOptions.Compiled | RegexOptions.CultureInvariant),
        new(@"\bpassword\b", RegexOptions.Compiled | RegexOptions.CultureInvariant),
        new(@"\.env\b", RegexOptions.Compiled | RegexOptions.CultureInvariant),
        new(@"\bopenai\b", RegexOptions.Compiled | RegexOptions.CultureInvariant),
        new(@"\banthropic\b", RegexOptions.Compiled | RegexOptions.CultureInvariant),
        new(@"\bglm[\s_\-]?api[\s_\-]?key\b", RegexOptions.Compiled | RegexOptions.CultureInvariant),
    };

    /// <summary>Recency decay with a 30-day scale. Swift: <c>recencyScore(_:)</c>. Future dates
    /// clamp age to 0 → 1.0. <paramref name="now"/> is the injectable clock.</summary>
    public static double RecencyScore(DateTimeOffset date, DateTimeOffset now)
    {
        double ageSeconds = Math.Max(0, (now - date).TotalSeconds);
        double ageDays = ageSeconds / 86_400.0;
        return 1.0 / (1.0 + (ageDays / 30.0));
    }

    /// <summary>Legacy candidate-bounding score (0.7 lexical / 0.3 semantic). Swift:
    /// <c>preliminaryScore(for:)</c>.</summary>
    public static double PreliminaryScore(CandidateAccumulator candidate)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        return (NormalizedLexicalScore(candidate.LexicalRank) * 0.7)
            + (Math.Max(0, candidate.SemanticScore ?? 0) * 0.3);
    }

    /// <summary>Reciprocal rank fusion over sparse/dense orderings. Swift:
    /// <c>reciprocalRankFusion(lexicalRank:semanticRank:k:)</c>. Ranks are 1-based.</summary>
    public static double ReciprocalRankFusion(int? lexicalRank, int? semanticRank, double k)
    {
        double score = 0.0;
        if (lexicalRank is int lr)
        {
            score += 1.0 / (k + lr);
        }

        if (semanticRank is int sr)
        {
            score += 1.0 / (k + sr);
        }

        return score;
    }

    /// <summary>Maps RRF raw to [0,1] given how many retrievers matched. Swift:
    /// <c>normalizedRRFForRerank(_:lexicalRank:semanticRank:k:)</c>.</summary>
    public static double NormalizedRrfForRerank(double raw, int? lexicalRank, int? semanticRank, double k)
    {
        int lists = (lexicalRank != null ? 1 : 0) + (semanticRank != null ? 1 : 0);
        if (lists <= 0)
        {
            return 0;
        }

        double maxPossible = lists / (k + 1.0);
        if (!(maxPossible > 0))
        {
            return 0;
        }

        return Math.Min(1.0, raw / maxPossible);
    }

    /// <summary>Normalizes a raw lexical rank/score to (0,1]. Swift:
    /// <c>normalizedLexicalScore(_:)</c>. Note the argument is a Double? (BM25-style),
    /// distinct from the Int? ranks used in RRF.</summary>
    public static double NormalizedLexicalScore(double? lexicalRank)
    {
        if (lexicalRank is not double rank)
        {
            return 0;
        }

        return 1.0 / (1.0 + Math.Abs(rank));
    }

    /// <summary>Tokenizes a query: lowercase, split on whitespace/newline/punctuation, keep
    /// tokens with length ≥ 2. Swift: <c>queryTokens(from:)</c>.</summary>
    public static List<string> QueryTokens(string query)
    {
        ArgumentNullException.ThrowIfNull(query);
        var tokens = new List<string>();
        var builder = new StringBuilder();
        foreach (char ch in query.ToLowerInvariant())
        {
            if (char.IsWhiteSpace(ch) || char.IsPunctuation(ch))
            {
                if (builder.Length > 0)
                {
                    Emit(tokens, builder);
                }
            }
            else
            {
                builder.Append(ch);
            }
        }

        if (builder.Length > 0)
        {
            Emit(tokens, builder);
        }

        return tokens;

        static void Emit(List<string> acc, StringBuilder buffer)
        {
            string token = buffer.ToString();
            buffer.Clear();
            if (token.Length >= 2)
            {
                acc.Add(token);
            }
        }
    }

    /// <summary>Exact-token coverage: +2 for a title substring hit (else +1 for a chunk hit),
    /// normalized by tokens*2, capped at 1. Swift: <c>exactTokenCoverageScore(tokens:title:chunkText:)</c>.
    /// Uses substring containment, and a title hit blocks the chunk hit for that token.</summary>
    public static double ExactTokenCoverageScore(IReadOnlyList<string> tokens, string title, string chunkText)
    {
        ArgumentNullException.ThrowIfNull(tokens);
        ArgumentNullException.ThrowIfNull(title);
        ArgumentNullException.ThrowIfNull(chunkText);
        if (tokens.Count == 0)
        {
            return 0;
        }

        string loweredTitle = title.ToLowerInvariant();
        string loweredChunk = chunkText.ToLowerInvariant();

        double weightedMatches = 0.0;
        foreach (string token in tokens)
        {
            if (loweredTitle.Contains(token, StringComparison.Ordinal))
            {
                weightedMatches += 2.0;
            }
            else if (loweredChunk.Contains(token, StringComparison.Ordinal))
            {
                weightedMatches += 1.0;
            }
        }

        double denominator = tokens.Count * 2.0;
        if (!(denominator > 0))
        {
            return 0;
        }

        return Math.Min(1.0, weightedMatches / denominator);
    }

    /// <summary>Picks a snippet: cleaned lexical snippet, else first 220 chars of the chunk,
    /// else first 220 chars of the fallback. Swift: <c>makeSnippet(lexicalSnippet:chunkText:fallback:)</c>.
    /// The 220-char truncation counts grapheme clusters (matches Swift <c>prefix</c>).</summary>
    public static string MakeSnippet(string? lexicalSnippet, string chunkText, string fallback)
    {
        ArgumentNullException.ThrowIfNull(chunkText);
        ArgumentNullException.ThrowIfNull(fallback);
        string cleanedLexical = (lexicalSnippet ?? string.Empty).Trim();
        if (cleanedLexical.Length != 0)
        {
            return cleanedLexical;
        }

        string cleanedChunk = chunkText.Trim();
        if (cleanedChunk.Length != 0)
        {
            return GraphemePrefix(cleanedChunk, 220);
        }

        return GraphemePrefix(fallback.Trim(), 220);
    }

    /// <summary>Whether a query looks like a sensitive exact lookup. Swift:
    /// <c>looksLikeSensitiveExactLookup(_:)</c>.</summary>
    public static bool LooksLikeSensitiveExactLookup(string query)
    {
        ArgumentNullException.ThrowIfNull(query);
        string lower = query.ToLowerInvariant();
        foreach (var pattern in SensitivePatterns)
        {
            if (pattern.IsMatch(lower))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>The hybrid rerank blend that determines final order. Swift:
    /// <c>SearchService+Retrieval.swift:385-401</c>. Two variants, both weight-sets sum to 1.0.</summary>
    public static double HybridRerankScore(
        HybridFusionStrategy strategy,
        double normalizedRrf,
        double exactScore,
        double recency,
        double lexicalScore,
        double semanticScore)
    {
        return strategy switch
        {
            HybridFusionStrategy.ReciprocalRankFusion =>
                (normalizedRrf * 0.52) + (exactScore * 0.33) + (recency * 0.15),
            _ =>
                (lexicalScore * 0.52) + (semanticScore * 0.33) + (exactScore * 0.10) + (recency * 0.05),
        };
    }

    /// <summary>
    /// Final ordering + dedup. Swift: <c>SearchService+Retrieval.swift:492-509</c>. Sort by
    /// rerankScore desc, tiebreak indexedAt desc, tiebreak chunkID ascending; then keep the
    /// first result per documentID and truncate to <paramref name="resultLimit"/>.
    /// </summary>
    public static List<RetrievalResult> RankResults(IEnumerable<RetrievalResult> results, int resultLimit)
    {
        ArgumentNullException.ThrowIfNull(results);
        var ordered = new List<RetrievalResult>(results);
        ordered.Sort(CompareResults);

        int limit = Math.Max(1, resultLimit);
        var deduped = new List<RetrievalResult>();
        var seenDocuments = new HashSet<string>(StringComparer.Ordinal);
        foreach (var result in ordered)
        {
            if (!seenDocuments.Add(result.DocumentId))
            {
                continue;
            }

            deduped.Add(result);
            if (deduped.Count >= limit)
            {
                break;
            }
        }

        return deduped;
    }

    /// <summary>The final total-order comparator: rerankScore desc, indexedAt desc, chunkID asc.</summary>
    public static int CompareResults(RetrievalResult lhs, RetrievalResult rhs)
    {
        ArgumentNullException.ThrowIfNull(lhs);
        ArgumentNullException.ThrowIfNull(rhs);
        if (lhs.RerankScore == rhs.RerankScore)
        {
            if (lhs.IndexedAt == rhs.IndexedAt)
            {
                return string.CompareOrdinal(lhs.ChunkId, rhs.ChunkId);
            }

            // indexedAt descending: newer first.
            return rhs.IndexedAt.CompareTo(lhs.IndexedAt);
        }

        // rerankScore descending.
        return rhs.RerankScore.CompareTo(lhs.RerankScore);
    }

    /// <summary>First <paramref name="count"/> grapheme clusters, matching Swift <c>prefix</c>.</summary>
    private static string GraphemePrefix(string value, int count)
    {
        if (value.Length <= count)
        {
            return value;
        }

        var enumerator = StringInfo.GetTextElementEnumerator(value);
        var builder = new StringBuilder();
        int taken = 0;
        while (taken < count && enumerator.MoveNext())
        {
            builder.Append((string)enumerator.Current);
            taken++;
        }

        return builder.ToString();
    }
}
