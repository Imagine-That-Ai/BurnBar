import Foundation

// MARK: - Indexed search (daemon + extension)

/// Parameters for `BurnBarRPCMethod.searchQuery`.
public struct BurnBarSearchQueryRequest: Codable, Sendable, Hashable {
    public let query: String
    public let providerRaw: String?
    public let projectName: String?
    /// Optional inclusive date range as seconds since 1970 (matches JSON number encoding).
    public let dateRangeStartEpoch: Double?
    public let dateRangeEndEpoch: Double?
    public let resultLimit: Int

    // MARK: - Semantic Search Fields (Optional)

    /// Pre-computed query embedding vector. When provided, enables semantic search
    /// in the daemon without requiring API keys. This is the recommended approach
    /// for extension clients that cannot store API keys.
    public let queryEmbedding: [Float]?

    /// The embedding version ID used to generate the query embedding.
    /// Used to filter `chunk_embeddings` to the matching version.
    public let embeddingVersionID: String?

    /// The embedding dimension count. Used to validate that the query embedding
    /// matches the indexed embedding dimensions.
    public let embeddingDimension: Int?

    /// The distance metric used by the query embedding.
    public let embeddingDistanceMetric: BurnBarEmbeddingDistanceMetric?

    /// Whether to skip semantic search even if embeddings are available.
    /// Useful for testing or when only lexical results are desired.
    public let skipSemanticSearch: Bool

    public init(
        query: String,
        providerRaw: String? = nil,
        projectName: String? = nil,
        dateRangeStartEpoch: Double? = nil,
        dateRangeEndEpoch: Double? = nil,
        resultLimit: Int = 50,
        queryEmbedding: [Float]? = nil,
        embeddingVersionID: String? = nil,
        embeddingDimension: Int? = nil,
        embeddingDistanceMetric: BurnBarEmbeddingDistanceMetric? = nil,
        skipSemanticSearch: Bool = false
    ) {
        self.query = query
        self.providerRaw = providerRaw
        self.projectName = projectName
        self.dateRangeStartEpoch = dateRangeStartEpoch
        self.dateRangeEndEpoch = dateRangeEndEpoch
        self.resultLimit = resultLimit
        self.queryEmbedding = queryEmbedding
        self.embeddingVersionID = embeddingVersionID
        self.embeddingDimension = embeddingDimension
        self.embeddingDistanceMetric = embeddingDistanceMetric
        self.skipSemanticSearch = skipSemanticSearch
    }
}

public struct BurnBarIndexedSearchHit: Codable, Sendable, Hashable {
    public let chunkID: String
    public let sourceKind: String
    public let sourceID: String
    public let title: String
    public let snippet: String
    public let provider: String?
    public let projectName: String?

    // MARK: - Semantic Fields

    /// Combined relevance score from hybrid fusion (0.0 to 1.0).
    /// Present when semantic search was performed.
    public let relevanceScore: Double?

    /// Source of the hit (lexical, semantic, or both via RRF).
    public let hitSource: BurnBarHitSource?

    public init(
        chunkID: String,
        sourceKind: String,
        sourceID: String,
        title: String,
        snippet: String,
        provider: String?,
        projectName: String?,
        relevanceScore: Double? = nil,
        hitSource: BurnBarHitSource? = nil
    ) {
        self.chunkID = chunkID
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.title = title
        self.snippet = snippet
        self.provider = provider
        self.projectName = projectName
        self.relevanceScore = relevanceScore
        self.hitSource = hitSource
    }
}

/// Indicates the source(s) that contributed to a search hit.
public enum BurnBarHitSource: String, Codable, Sendable {
    /// Hit found via lexical FTS search.
    case lexical
    /// Hit found via semantic vector search.
    case semantic
    /// Hit found in both lexical and semantic, combined via RRF.
    case hybrid
}

public struct BurnBarSearchQueryResult: Codable, Sendable, Hashable {
    public let plan: BurnBarSearchPlan
    public let aggregateOccurrenceCount: Int?
    public let hits: [BurnBarIndexedSearchHit]
    /// Explains limitations (e.g. semantic ranking unavailable in daemon-only path).
    public let degradedMessage: String?
    /// Indicates whether semantic search was performed successfully.
    public let semanticSearchPerformed: Bool
    /// The number of hits that came from semantic search (if performed).
    public let semanticHitCount: Int?

    public init(
        plan: BurnBarSearchPlan,
        aggregateOccurrenceCount: Int?,
        hits: [BurnBarIndexedSearchHit],
        degradedMessage: String? = nil,
        semanticSearchPerformed: Bool = false,
        semanticHitCount: Int? = nil
    ) {
        self.plan = plan
        self.aggregateOccurrenceCount = aggregateOccurrenceCount
        self.hits = hits
        self.degradedMessage = degradedMessage
        self.semanticSearchPerformed = semanticSearchPerformed
        self.semanticHitCount = semanticHitCount
    }
}
