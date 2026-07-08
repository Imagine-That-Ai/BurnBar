using System.Linq;
using OpenBurnBar.App.MemorySearch.Search;
using Xunit;

namespace OpenBurnBar.App.MemorySearch.Tests;

/// <summary>
/// Retrieval-health status classification + latency timer. Swift:
/// <c>SearchService+Health.swift</c> (per-query) and <c>RetrievalHealthService.degradedModes</c>.
/// </summary>
public sealed class RetrievalHealthTests
{
    [Theory]
    [InlineData(true, false, RetrievalHealthStatus.Degraded)]
    [InlineData(false, true, RetrievalHealthStatus.Degraded)]
    [InlineData(false, false, RetrievalHealthStatus.Healthy)]
    public void LexicalHealthStatus_MatchesSwift(bool indexStale, bool fallback, RetrievalHealthStatus expected)
    {
        Assert.Equal(expected, RetrievalHealthClassifier.LexicalHealthStatus(indexStale, fallback));
    }

    [Fact]
    public void LexicalHealthError_PrioritizesIndexStaleThenFallbackThenEmpty()
    {
        Assert.Equal("INDEX_STALE_PARTIAL_RESULTS", RetrievalHealthClassifier.LexicalHealthError(true, true).Code);
        Assert.Equal("SEMANTIC_FALLBACK_USED", RetrievalHealthClassifier.LexicalHealthError(false, true).Code);
        Assert.Equal("LEXICAL_SKIPPED_EMPTY_QUERY", RetrievalHealthClassifier.LexicalHealthError(false, false, lexicalSkippedEmptyQuery: true).Code);
        Assert.Null(RetrievalHealthClassifier.LexicalHealthError(false, false).Code);
    }

    [Fact]
    public void LexicalHealthError_UsesProvidedIndexStaleMessage()
    {
        var error = RetrievalHealthClassifier.LexicalHealthError(true, false, indexStaleError: "custom");
        Assert.Equal("custom", error.Message);
    }

    private static ProjectionQueueHealthState HealthyProjection() =>
        new(RetrievalHealthStatus.Healthy, 0, 0);

    private static SemanticPipelineHealthState HealthySemantic() =>
        new(RetrievalHealthStatus.Healthy, IndexedVectorCount: 10);

    private static RebuildPipelineHealthState IdleRebuild() =>
        new(RetrievalHealthStatus.Healthy, InProgress: false, PendingRebuildJobs: 0, PendingReembedJobs: 0);

    [Fact]
    public void DegradedModes_AllHealthy_IsEmpty()
    {
        var modes = RetrievalHealthClassifier.DegradedModes(
            indexingEnabled: true,
            sharedFeaturesAvailable: true,
            HealthyProjection(),
            HealthySemantic(),
            IdleRebuild(),
            collaborationStatus: RetrievalHealthStatus.Healthy);
        Assert.Empty(modes);
    }

    [Fact]
    public void DegradedModes_FailedProjectionJobs_FlagsIndexStaleWithCount()
    {
        var modes = RetrievalHealthClassifier.DegradedModes(
            indexingEnabled: true,
            sharedFeaturesAvailable: true,
            new ProjectionQueueHealthState(RetrievalHealthStatus.Degraded, QueueDepth: 0, FailedJobs: 3),
            HealthySemantic(),
            IdleRebuild(),
            RetrievalHealthStatus.Healthy);

        var indexStale = modes.Single(m => m.Mode == RetrievalDegradedMode.IndexStale);
        Assert.Equal("Search index is stale: 3 projection job(s) are failing.", indexStale.Message);
    }

    [Fact]
    public void DegradedModes_QueuePending_FlagsIndexStaleCatchingUp()
    {
        var modes = RetrievalHealthClassifier.DegradedModes(
            true, true,
            new ProjectionQueueHealthState(RetrievalHealthStatus.Healthy, QueueDepth: 5, FailedJobs: 0),
            HealthySemantic(),
            IdleRebuild(),
            RetrievalHealthStatus.Healthy);

        var indexStale = modes.Single(m => m.Mode == RetrievalDegradedMode.IndexStale);
        Assert.Equal("Search index is catching up: 5 projection job(s) are pending.", indexStale.Message);
    }

    [Fact]
    public void DegradedModes_ZeroVectors_FlagsSemanticUnavailable()
    {
        var modes = RetrievalHealthClassifier.DegradedModes(
            true, true,
            HealthyProjection(),
            new SemanticPipelineHealthState(RetrievalHealthStatus.Healthy, IndexedVectorCount: 0),
            IdleRebuild(),
            RetrievalHealthStatus.Healthy);

        var semantic = modes.Single(m => m.Mode == RetrievalDegradedMode.SemanticUnavailable);
        Assert.Equal("Semantic retrieval is unavailable until chunk embeddings are indexed.", semantic.Message);
    }

    [Fact]
    public void DegradedModes_RebuildInProgress_UsesRebuildOrReembedMessage()
    {
        var rebuilding = RetrievalHealthClassifier.DegradedModes(
            true, true, HealthyProjection(), HealthySemantic(),
            new RebuildPipelineHealthState(RetrievalHealthStatus.Healthy, InProgress: true, PendingRebuildJobs: 2, PendingReembedJobs: 0),
            RetrievalHealthStatus.Healthy);
        Assert.Contains(rebuilding, m => m.Mode == RetrievalDegradedMode.RebuildInProgress
            && m.Message.StartsWith("Search rebuild is in progress"));

        var reembedding = RetrievalHealthClassifier.DegradedModes(
            true, true, HealthyProjection(), HealthySemantic(),
            new RebuildPipelineHealthState(RetrievalHealthStatus.Healthy, InProgress: true, PendingRebuildJobs: 0, PendingReembedJobs: 4),
            RetrievalHealthStatus.Healthy);
        Assert.Contains(reembedding, m => m.Mode == RetrievalDegradedMode.RebuildInProgress
            && m.Message.StartsWith("Re-embedding is in progress"));
    }

    [Fact]
    public void DegradedModes_IndexingDisabled_SuppressesIndexAndSemanticButNotCloud()
    {
        var modes = RetrievalHealthClassifier.DegradedModes(
            indexingEnabled: false,
            sharedFeaturesAvailable: false,
            new ProjectionQueueHealthState(RetrievalHealthStatus.Failed, 9, 9),
            new SemanticPipelineHealthState(RetrievalHealthStatus.Failed, 0),
            IdleRebuild(),
            collaborationStatus: RetrievalHealthStatus.Failed);

        // Only the ungated cloud/shared mode is present.
        Assert.Single(modes);
        Assert.Equal(RetrievalDegradedMode.CloudSharedUnavailable, modes[0].Mode);
    }

    [Fact]
    public void PerformanceTimer_MeasuresNonNegativeElapsed()
    {
        long start = SearchPerformanceTimer.Now();
        Assert.True(SearchPerformanceTimer.ElapsedMilliseconds(start) >= 0);
        // A start in the future clamps to 0.
        Assert.Equal(0, SearchPerformanceTimer.ElapsedMilliseconds(long.MaxValue));
    }
}
