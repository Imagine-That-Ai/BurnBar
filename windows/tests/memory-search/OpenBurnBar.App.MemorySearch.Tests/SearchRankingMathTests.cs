using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.MemorySearch.Search;
using Xunit;

namespace OpenBurnBar.App.MemorySearch.Tests;

/// <summary>
/// The portable ranking math. Swift: <c>SearchService+Ranking.swift</c> + the two rerankScore
/// blends and the final sort/dedup in <c>SearchService+Retrieval.swift</c>.
/// </summary>
public sealed class SearchRankingMathTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 6, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void RecencyScore_NowIsOne_And30DaysIsHalf()
    {
        Assert.Equal(1.0, SearchRankingMath.RecencyScore(Now, Now), 12);
        Assert.Equal(0.5, SearchRankingMath.RecencyScore(Now.AddDays(-30), Now), 12);
    }

    [Fact]
    public void RecencyScore_FutureDate_ClampsAgeToZero()
    {
        Assert.Equal(1.0, SearchRankingMath.RecencyScore(Now.AddDays(5), Now), 12);
    }

    [Fact]
    public void ReciprocalRankFusion_SumsContributions()
    {
        double k = HybridRetrievalConstants.RrfK;
        Assert.Equal((1.0 / (k + 1)) + (1.0 / (k + 3)), SearchRankingMath.ReciprocalRankFusion(1, 3, k), 12);
        Assert.Equal(1.0 / (k + 2), SearchRankingMath.ReciprocalRankFusion(2, null, k), 12);
        Assert.Equal(0.0, SearchRankingMath.ReciprocalRankFusion(null, null, k), 12);
    }

    [Fact]
    public void NormalizedRrfForRerank_ClampsToUnit()
    {
        double k = HybridRetrievalConstants.RrfK;
        double raw = SearchRankingMath.ReciprocalRankFusion(1, 1, k); // both at rank 1 = max
        Assert.Equal(1.0, SearchRankingMath.NormalizedRrfForRerank(raw, 1, 1, k), 12);
        Assert.Equal(0.0, SearchRankingMath.NormalizedRrfForRerank(0, null, null, k));
    }

    [Fact]
    public void NormalizedLexicalScore_NilIsZero()
    {
        Assert.Equal(0.0, SearchRankingMath.NormalizedLexicalScore(null));
        Assert.Equal(1.0 / (1.0 + 3.0), SearchRankingMath.NormalizedLexicalScore(-3.0), 12);
    }

    [Fact]
    public void QueryTokens_LowercasesSplitsAndDropsShortTokens()
    {
        var tokens = SearchRankingMath.QueryTokens("The API-Key, a X!");
        // lowercase, split on ws/punct, keep len >= 2 → drops "a" and "x"
        Assert.Equal(new[] { "the", "api", "key" }, tokens);
    }

    [Fact]
    public void ExactTokenCoverage_TitleHitOutweighsChunkHit_AndCaps()
    {
        var tokens = new[] { "memory", "search" };
        // both in title → 2+2 = 4; denominator = 2*2 = 4 → 1.0
        Assert.Equal(1.0, SearchRankingMath.ExactTokenCoverageScore(tokens, "Memory Search Notes", "body"), 12);
        // one title, one chunk → 2 + 1 = 3; /4 = 0.75
        Assert.Equal(0.75, SearchRankingMath.ExactTokenCoverageScore(tokens, "Memory Notes", "search body"), 12);
        Assert.Equal(0.0, SearchRankingMath.ExactTokenCoverageScore(Array.Empty<string>(), "t", "c"));
    }

    [Fact]
    public void MakeSnippet_PrefersLexicalThenChunkThenFallback()
    {
        Assert.Equal("lex", SearchRankingMath.MakeSnippet("  lex ", "chunk", "fallback"));
        Assert.Equal("chunk", SearchRankingMath.MakeSnippet("   ", "chunk", "fallback"));
        Assert.Equal("fallback", SearchRankingMath.MakeSnippet(null, "   ", "fallback"));
    }

    [Fact]
    public void MakeSnippet_TruncatesTo220Chars()
    {
        string big = new string('x', 500);
        Assert.Equal(220, SearchRankingMath.MakeSnippet(null, big, "f").Length);
    }

    [Theory]
    [InlineData("what is my openai api key", true)]
    [InlineData("show me the password", true)]
    [InlineData("read the .env file", true)]
    [InlineData("what is the weather", false)]
    public void LooksLikeSensitiveExactLookup_MatchesSwiftPatterns(string query, bool expected)
    {
        Assert.Equal(expected, SearchRankingMath.LooksLikeSensitiveExactLookup(query));
    }

    [Fact]
    public void HybridRerankScore_RrfStrategy_UsesFiftyTwoThirtyThreeFifteen()
    {
        double score = SearchRankingMath.HybridRerankScore(
            HybridFusionStrategy.ReciprocalRankFusion,
            normalizedRrf: 1.0,
            exactScore: 1.0,
            recency: 1.0,
            lexicalScore: 0.0,
            semanticScore: 0.0);
        Assert.Equal(0.52 + 0.33 + 0.15, score, 12);
    }

    [Fact]
    public void HybridRerankScore_LegacyStrategy_UsesFourWeights()
    {
        double score = SearchRankingMath.HybridRerankScore(
            HybridFusionStrategy.LegacyWeighted,
            normalizedRrf: 0.0,
            exactScore: 1.0,
            recency: 1.0,
            lexicalScore: 1.0,
            semanticScore: 1.0);
        Assert.Equal(0.52 + 0.33 + 0.10 + 0.05, score, 12);
    }

    [Fact]
    public void RankResults_SortsByRerankScoreThenIndexedAtThenChunkId()
    {
        var older = Now.AddDays(-1);
        var results = new[]
        {
            Result("a", "doc-a", 0.5, Now),
            Result("b", "doc-b", 0.9, older),
            Result("c", "doc-c", 0.5, Now), // ties with a on score+time → chunkId asc keeps a before c
        };

        var ranked = SearchRankingMath.RankResults(results, 10);
        Assert.Equal(new[] { "b", "a", "c" }, ranked.Select(r => r.ChunkId));
    }

    [Fact]
    public void RankResults_DedupesByDocumentId_KeepingHighestRanked()
    {
        var results = new[]
        {
            Result("a1", "doc", 0.9, Now),
            Result("a2", "doc", 0.5, Now),
            Result("b1", "other", 0.7, Now),
        };

        var ranked = SearchRankingMath.RankResults(results, 10);
        Assert.Equal(new[] { "a1", "b1" }, ranked.Select(r => r.ChunkId));
    }

    [Fact]
    public void RankResults_TruncatesToResultLimit()
    {
        var results = Enumerable.Range(0, 5)
            .Select(i => Result($"c{i}", $"doc{i}", i, Now))
            .ToArray();
        Assert.Equal(2, SearchRankingMath.RankResults(results, 2).Count);
    }

    private static RetrievalResult Result(string chunkId, string documentId, double rerankScore, DateTimeOffset indexedAt) =>
        new(chunkId, documentId, "title", "snippet", indexedAt, rerankScore);
}
