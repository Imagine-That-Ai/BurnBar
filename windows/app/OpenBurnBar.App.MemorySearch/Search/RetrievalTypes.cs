using System;

namespace OpenBurnBar.App.MemorySearch.Search;

// PORTED (faithful subset) from
//   AgentLens/Services/Search/RetrievalQueryTypes.swift  (HybridFusionStrategy, constants, RetrievalResult)
//   AgentLens/Services/DataStore/DataStoreTypes.swift     (RetrievalHealthStatus)
//   AgentLens/Services/Search/SearchTypes.swift           (RetrievalDegradedMode)
//
// Only the fields the PORTABLE ranking / rerank / health math reads are ported; the wider
// RetrievalResult (provider metadata, section paths, conversation record, etc.) is DataStore
// hydration concern and is out of the deterministic core.

/// <summary>Hybrid fusion strategy. Swift: <c>enum HybridFusionStrategy</c>. Default
/// <see cref="ReciprocalRankFusion"/>.</summary>
public enum HybridFusionStrategy
{
    LegacyWeighted,
    ReciprocalRankFusion,
}

/// <summary>Retrieval-subsystem health status. Swift: <c>enum RetrievalHealthStatus</c>.</summary>
public enum RetrievalHealthStatus
{
    Healthy,
    Degraded,
    Failed,
}

/// <summary>A degraded mode affecting retrieval quality. Swift: <c>enum RetrievalDegradedMode</c>.</summary>
public enum RetrievalDegradedMode
{
    IndexStale,
    SemanticUnavailable,
    RebuildInProgress,
    CloudSharedUnavailable,
}

/// <summary>Lowercase raw-value parity with the Swift <c>String</c>-backed enums.</summary>
public static class RetrievalEnumExtensions
{
    public static string RawValue(this RetrievalHealthStatus status) => status switch
    {
        RetrievalHealthStatus.Healthy => "healthy",
        RetrievalHealthStatus.Degraded => "degraded",
        _ => "failed",
    };

    public static string RawValue(this RetrievalDegradedMode mode) => mode switch
    {
        RetrievalDegradedMode.IndexStale => "indexStale",
        RetrievalDegradedMode.SemanticUnavailable => "semanticUnavailable",
        RetrievalDegradedMode.RebuildInProgress => "rebuildInProgress",
        _ => "cloudSharedUnavailable",
    };
}

/// <summary>Fixed hybrid-retrieval constants. Swift: <c>enum HybridRetrievalConstants</c>.</summary>
public static class HybridRetrievalConstants
{
    /// <summary>RRF damping constant. Swift: <c>static let rrfK: Double = 60</c>.</summary>
    public const double RrfK = 60;
}

/// <summary>
/// A retrieval result (ranking-relevant subset). Swift: <c>struct RetrievalResult</c>. The
/// portable ranking/rerank math reads exactly these fields; <see cref="RerankScore"/> is the
/// hybrid blend that determines the final order and is surfaced as the UI <c>rank</c>.
/// </summary>
public sealed record RetrievalResult(
    string ChunkId,
    string DocumentId,
    string Title,
    string Snippet,
    DateTimeOffset IndexedAt,
    double RerankScore,
    string? Subtitle = null,
    DateTimeOffset? SourceUpdatedAt = null,
    double? LexicalRank = null,
    double? SemanticScore = null)
{
    /// <summary>Identity mirrors the Swift <c>var id: String { chunkID }</c>.</summary>
    public string Id => ChunkId;
}
