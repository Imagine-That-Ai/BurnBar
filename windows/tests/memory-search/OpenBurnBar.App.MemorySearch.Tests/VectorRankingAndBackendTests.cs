using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.MemorySearch.Search;
using Xunit;

namespace OpenBurnBar.App.MemorySearch.Tests;

/// <summary>
/// The single canonical ranking rule (score desc, chunkID asc, drop non-finite, take k) and the
/// exact backend. Swift: <c>VectorRanking</c> / <c>ExactVectorCandidateBackend</c>.
/// </summary>
public sealed class VectorRankingAndBackendTests
{
    [Fact]
    public void RankTopK_SortsByScoreDescending()
    {
        var scored = new[]
        {
            new VectorIndexCandidate("a", 0.1),
            new VectorIndexCandidate("b", 0.9),
            new VectorIndexCandidate("c", 0.5),
        };

        var ranked = VectorRanking.RankTopK(scored, 3);
        Assert.Equal(new[] { "b", "c", "a" }, ranked.Select(c => c.ChunkId));
    }

    [Fact]
    public void RankTopK_TieBreaksByChunkIdAscending()
    {
        var scored = new[]
        {
            new VectorIndexCandidate("zebra", 0.5),
            new VectorIndexCandidate("apple", 0.5),
            new VectorIndexCandidate("mango", 0.5),
        };

        var ranked = VectorRanking.RankTopK(scored, 3);
        Assert.Equal(new[] { "apple", "mango", "zebra" }, ranked.Select(c => c.ChunkId));
    }

    [Fact]
    public void RankTopK_DropsNonFiniteScores()
    {
        var scored = new[]
        {
            new VectorIndexCandidate("finite", 0.5),
            new VectorIndexCandidate("nan", double.NaN),
            new VectorIndexCandidate("inf", double.PositiveInfinity),
        };

        var ranked = VectorRanking.RankTopK(scored, 10);
        Assert.Single(ranked);
        Assert.Equal("finite", ranked[0].ChunkId);
    }

    [Fact]
    public void RankTopK_TruncatesToLimit()
    {
        var scored = Enumerable.Range(0, 10)
            .Select(i => new VectorIndexCandidate($"c{i:D2}", i))
            .ToArray();

        var ranked = VectorRanking.RankTopK(scored, 3);
        Assert.Equal(3, ranked.Count);
        Assert.Equal(new[] { "c09", "c08", "c07" }, ranked.Select(c => c.ChunkId));
    }

    [Fact]
    public void ExactBackend_Id_MatchesSwift()
    {
        Assert.Equal("exact_scan_v1", new ExactVectorCandidateBackend().Id);
    }

    [Fact]
    public void ExactBackend_RanksNearestByCosine()
    {
        var backend = new ExactVectorCandidateBackend();
        backend.Rebuild(new[]
        {
            new VectorIndexEntry("north", new[] { 0f, 1f }),
            new VectorIndexEntry("east", new[] { 1f, 0f }),
            new VectorIndexEntry("northeast", new[] { 1f, 1f }),
        }, EmbeddingDistanceMetric.Cosine);

        var candidates = backend.Candidates(new[] { 0.1f, 1f }, 3);
        // Query points mostly north; north is closest, then northeast, then east.
        Assert.Equal(new[] { "north", "northeast", "east" }, candidates.Select(c => c.ChunkId));
    }

    [Fact]
    public void ExactBackend_EmptyIndexOrZeroLimit_ReturnsEmpty()
    {
        var backend = new ExactVectorCandidateBackend();
        Assert.Empty(backend.Candidates(new[] { 1f }, 3));

        backend.Rebuild(new[] { new VectorIndexEntry("a", new[] { 1f }) }, EmbeddingDistanceMetric.Cosine);
        Assert.Empty(backend.Candidates(new[] { 1f }, 0));
    }

    [Fact]
    public void ExactBackend_DimensionMismatch_Throws()
    {
        var backend = new ExactVectorCandidateBackend();
        backend.Rebuild(new[] { new VectorIndexEntry("a", new[] { 1f, 2f, 3f }) }, EmbeddingDistanceMetric.Cosine);

        var ex = Assert.Throws<VectorIndexBackendException>(() => backend.Candidates(new[] { 1f, 2f }, 5));
        Assert.Equal(3, ex.Expected);
        Assert.Equal(2, ex.Actual);
    }
}
