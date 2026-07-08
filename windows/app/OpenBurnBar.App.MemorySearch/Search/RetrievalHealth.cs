using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace OpenBurnBar.App.MemorySearch.Search;

// PORTED (faithful) from
//   AgentLens/Services/Search/SearchService+Health.swift        (per-query status + error mapping)
//   AgentLens/Services/Search/RetrievalHealthService.swift       (degradedModes classification)
//   AgentLens/Services/Search/SearchTypes.swift                  (health-state records)
//   AgentLens/Services/Search/OpenBurnBarSearchPerformanceTimer.swift (monotonic latency)
//
// Retrieval-health has NO percentile / recall / hit-rate / empty-rate aggregation (verified in
// the oracle). "Metrics" are (1) raw per-query millisecond latencies from a MONOTONIC clock and
// (2) boolean/count-threshold status classification. Both are ported deterministically here. The
// wide DB-backed snapshot assembly (reading detailsJSON blobs, fetching projection jobs) is
// DataStore I/O and stays out of the portable core; the classification INPUTS are modeled as
// plain records so the exact thresholds/messages are unit-tested.

/// <summary>
/// Monotonic latency timer. Swift: <c>OpenBurnBarPerformanceTimer</c> (DispatchTime uptime). Uses
/// <see cref="Stopwatch"/> ticks and clamps to 0 when end &lt; start, matching the Swift guard.
/// This is deliberately NOT injectable (the Swift peer isn't either); tests measure real short spans.
/// </summary>
public static class SearchPerformanceTimer
{
    /// <summary>A monotonic timestamp. Swift: <c>now()</c> (uptimeNanoseconds).</summary>
    public static long Now() => Stopwatch.GetTimestamp();

    /// <summary>Elapsed milliseconds since a prior <see cref="Now"/>; 0 when end &lt; start.
    /// Swift: <c>elapsedMilliseconds(since:)</c>.</summary>
    public static double ElapsedMilliseconds(long start)
    {
        long end = Now();
        if (end < start)
        {
            return 0;
        }

        return (end - start) * 1000.0 / Stopwatch.Frequency;
    }
}

/// <summary>Per-query lexical health detail blob. Swift: <c>struct LexicalRetrievalHealthDetails</c>.</summary>
public sealed record LexicalRetrievalHealthDetails(
    int QueryLength,
    int LexicalCandidateCount,
    int SemanticCandidateCount,
    int ResultCount,
    bool IndexStale,
    bool SemanticFallbackUsed,
    double? TotalQueryLatencyMs = null,
    double? LexicalQueryLatencyMs = null,
    double? SemanticQueryLatencyMs = null,
    double? RerankLatencyMs = null,
    double? HydrationLatencyMs = null,
    double? CrossEncoderLatencyMs = null);

/// <summary>Projection-queue subsystem state (classification input). Swift:
/// <c>struct ProjectionQueueHealthState</c>.</summary>
public sealed record ProjectionQueueHealthState(
    RetrievalHealthStatus Status,
    int QueueDepth,
    int FailedJobs,
    string? ErrorCode = null,
    string? ErrorMessage = null);

/// <summary>Semantic-pipeline subsystem state (classification input). Swift:
/// <c>struct SemanticPipelineHealthState</c> (subset the classifier reads).</summary>
public sealed record SemanticPipelineHealthState(
    RetrievalHealthStatus Status,
    int IndexedVectorCount,
    bool FallbackToExact = false,
    string? ErrorCode = null,
    string? ErrorMessage = null);

/// <summary>Rebuild-pipeline subsystem state (classification input). Swift:
/// <c>struct RebuildPipelineHealthState</c>.</summary>
public sealed record RebuildPipelineHealthState(
    RetrievalHealthStatus Status,
    bool InProgress,
    int PendingRebuildJobs,
    int PendingReembedJobs,
    string? ErrorCode = null,
    string? ErrorMessage = null);

/// <summary>A degraded state for display. Swift: <c>struct RetrievalDegradedState</c>.</summary>
public sealed record RetrievalDegradedState(RetrievalDegradedMode Mode, string Title, string Message);

/// <summary>An error code/message pair. Peer of the Swift <c>(code:message:)</c> tuple.</summary>
public sealed record RetrievalHealthError(string? Code, string? Message);

/// <summary>The deterministic retrieval-health classification. Swift: the pure branches of
/// <c>SearchService.lexicalHealthStatus/lexicalHealthError</c> and
/// <c>RetrievalHealthService.degradedModes</c>.</summary>
public static class RetrievalHealthClassifier
{
    /// <summary>Per-query lexical status. Swift: <c>lexicalHealthStatus(indexStale:semanticFallbackUsed:)</c>.</summary>
    public static RetrievalHealthStatus LexicalHealthStatus(bool indexStale, bool semanticFallbackUsed)
    {
        if (indexStale)
        {
            return RetrievalHealthStatus.Degraded;
        }

        if (semanticFallbackUsed)
        {
            return RetrievalHealthStatus.Degraded;
        }

        return RetrievalHealthStatus.Healthy;
    }

    /// <summary>Per-query error code/message. Swift: <c>lexicalHealthError(...)</c>.</summary>
    public static RetrievalHealthError LexicalHealthError(
        bool indexStale,
        bool semanticFallbackUsed,
        bool lexicalSkippedEmptyQuery = false,
        string? indexStaleError = null)
    {
        if (indexStale)
        {
            return new RetrievalHealthError(
                "INDEX_STALE_PARTIAL_RESULTS",
                indexStaleError ?? "Search index metadata could not be fully loaded; partial results were returned.");
        }

        if (semanticFallbackUsed)
        {
            return new RetrievalHealthError(
                "SEMANTIC_FALLBACK_USED",
                "Semantic retrieval failed; lexical fallback served this query.");
        }

        if (lexicalSkippedEmptyQuery)
        {
            return new RetrievalHealthError(
                "LEXICAL_SKIPPED_EMPTY_QUERY",
                "Lexical FTS query was empty (stopwords-only input); semantic retrieval served this query.");
        }

        return new RetrievalHealthError(null, null);
    }

    /// <summary>
    /// Classifies degraded modes from subsystem states. Swift: <c>degradedModes(...)</c>. Order and
    /// boundary thresholds are exact: rebuildInProgress, then indexStale, then semanticUnavailable
    /// (all gated on <paramref name="indexingEnabled"/>), then cloudSharedUnavailable (ungated).
    /// </summary>
    public static List<RetrievalDegradedState> DegradedModes(
        bool indexingEnabled,
        bool sharedFeaturesAvailable,
        ProjectionQueueHealthState projection,
        SemanticPipelineHealthState semantic,
        RebuildPipelineHealthState rebuild,
        RetrievalHealthStatus? collaborationStatus)
    {
        ArgumentNullException.ThrowIfNull(projection);
        ArgumentNullException.ThrowIfNull(semantic);
        ArgumentNullException.ThrowIfNull(rebuild);
        var modes = new List<RetrievalDegradedState>();

        if (indexingEnabled)
        {
            if (rebuild.InProgress)
            {
                string rebuildMessage = rebuild.PendingRebuildJobs > 0
                    ? "Search rebuild is in progress. Results may lag until projection and re-embedding complete."
                    : "Re-embedding is in progress. Semantic ranking may be temporarily incomplete.";
                modes.Add(new RetrievalDegradedState(
                    RetrievalDegradedMode.RebuildInProgress,
                    "Rebuild in progress",
                    rebuildMessage));
            }

            bool indexStale = projection.Status != RetrievalHealthStatus.Healthy
                || projection.QueueDepth > 0
                || projection.FailedJobs > 0;
            if (indexStale)
            {
                string indexMessage;
                if (projection.FailedJobs > 0)
                {
                    indexMessage = $"Search index is stale: {projection.FailedJobs} projection job(s) are failing.";
                }
                else if (projection.QueueDepth > 0)
                {
                    indexMessage = $"Search index is catching up: {projection.QueueDepth} projection job(s) are pending.";
                }
                else
                {
                    indexMessage = projection.ErrorMessage ?? "Search index health is degraded.";
                }

                modes.Add(new RetrievalDegradedState(RetrievalDegradedMode.IndexStale, "Index stale", indexMessage));
            }

            bool semanticUnavailable = semantic.Status != RetrievalHealthStatus.Healthy
                || semantic.IndexedVectorCount == 0;
            if (semanticUnavailable)
            {
                string semanticMessage = semantic.IndexedVectorCount == 0
                    ? "Semantic retrieval is unavailable until chunk embeddings are indexed."
                    : semantic.ErrorMessage
                        ?? "Semantic retrieval is temporarily unavailable; lexical fallback remains active.";
                modes.Add(new RetrievalDegradedState(
                    RetrievalDegradedMode.SemanticUnavailable,
                    "Semantic unavailable",
                    semanticMessage));
            }
        }

        if (!sharedFeaturesAvailable
            || collaborationStatus == RetrievalHealthStatus.Failed
            || collaborationStatus == RetrievalHealthStatus.Degraded)
        {
            modes.Add(new RetrievalDegradedState(
                RetrievalDegradedMode.CloudSharedUnavailable,
                "Cloud/shared unavailable",
                "Cloud and shared artifact features are unavailable. Local search continues to work."));
        }

        return modes;
    }
}
