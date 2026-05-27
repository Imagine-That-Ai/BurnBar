import Foundation
import OpenBurnBarCore

// MARK: - Retrieval Ownership Filter

/// Filter for scoping results by ownership (personal vs shared).
enum RetrievalOwnershipFilter: String, CaseIterable {
    case any
    case personal
    case shared

    var visibilityScope: SearchVisibilityScope {
        switch self {
        case .any:
            return .all
        case .personal:
            return .personalOnly
        case .shared:
            return .sharedOnly
        }
    }
}

/// How lexical and semantic candidates are merged before final ranking.
enum HybridFusionStrategy: String, Codable, Sendable, CaseIterable {
    /// Prior weighted blend of normalized lexical rank and semantic similarity (legacy behavior).
    case legacyWeighted
    /// Reciprocal rank fusion across lexical and semantic ranked lists (robust across score scales).
    case reciprocalRankFusion
}

/// RRF smoothing constant for reciprocal rank fusion.
enum HybridRetrievalConstants {
    /// Standard RRF smoothing constant (see Cormack et al. / Elasticsearch RRF).
    static let rrfK: Double = 60
}

// MARK: - Retrieval Filters

/// Filters for narrowing retrieval results.
struct RetrievalFilters {
    var provider: AgentProvider?
    var projectName: String?
    var artifactTypes: Set<SearchSourceKind>?
    var dateRange: ClosedRange<Date>?
    var ownership: RetrievalOwnershipFilter
    var sourceIDs: Set<String>?
    var conversationSources: Set<ConversationSourceType>?

    init(
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        artifactTypes: Set<SearchSourceKind>? = nil,
        dateRange: ClosedRange<Date>? = nil,
        ownership: RetrievalOwnershipFilter = .any,
        sourceIDs: Set<String>? = nil,
        conversationSources: Set<ConversationSourceType>? = nil
    ) {
        self.provider = provider
        self.projectName = projectName
        self.artifactTypes = artifactTypes
        self.dateRange = dateRange
        self.ownership = ownership
        self.sourceIDs = sourceIDs
        self.conversationSources = conversationSources
    }
}

// MARK: - Retrieval Query

/// A structured retrieval query with filters and tuning parameters.
struct RetrievalQuery {
    var text: String
    /// When set, used as the FTS5 `MATCH` string for lexical chunk search instead of deriving from `text`.
    var lexicalFTSQuery: String?
    var filters: RetrievalFilters
    var lexicalCandidateLimit: Int
    var semanticCandidateLimit: Int
    var rerankCandidateLimit: Int
    var resultLimit: Int
    var hybridFusionStrategy: HybridFusionStrategy
    /// When true, enables cross-encoder reranking on hydrated candidates.
    /// Defaults to false. Bypassed if the SearchService has no reranker configured.
    var crossEncoderEnabled: Bool
    /// Maximum number of candidates to send to cross-encoder reranking.
    /// Helps cap latency and cost. Defaults to 40, capped at 64.
    var crossEncoderCandidateLimit: Int

    init(
        text: String,
        lexicalFTSQuery: String? = nil,
        filters: RetrievalFilters = RetrievalFilters(),
        lexicalCandidateLimit: Int = 120,
        semanticCandidateLimit: Int = 120,
        rerankCandidateLimit: Int = 200,
        resultLimit: Int = 50,
        hybridFusionStrategy: HybridFusionStrategy = .reciprocalRankFusion,
        crossEncoderEnabled: Bool = false,
        crossEncoderCandidateLimit: Int = 40
    ) {
        self.text = text
        self.lexicalFTSQuery = lexicalFTSQuery
        self.filters = filters
        self.lexicalCandidateLimit = lexicalCandidateLimit
        self.semanticCandidateLimit = semanticCandidateLimit
        self.rerankCandidateLimit = rerankCandidateLimit
        self.resultLimit = resultLimit
        self.hybridFusionStrategy = hybridFusionStrategy
        self.crossEncoderEnabled = crossEncoderEnabled
        self.crossEncoderCandidateLimit = max(5, min(crossEncoderCandidateLimit, 64))
    }
}

// MARK: - Retrieval Result

/// Result of `SearchService.runBurnBarQuery`: hybrid retrieval plus optional aggregate counts.
struct OpenBurnBarQueryRunResult: Sendable {
    let plan: BurnBarSearchPlan
    let retrievalResults: [RetrievalResult]
    /// Total substring occurrences summed across patterns in `conversations.fullText`.
    let aggregateOccurrenceCount: Int?
    /// Human-readable note when a relative time phrase was turned into `dateRange`.
    let aggregateWindowDescription: String?
}

/// A single retrieval result with source metadata and ranking scores.
struct RetrievalResult: Identifiable, Sendable {
    let chunkID: String
    let documentID: String
    let sourceKind: SearchSourceKind
    let sourceID: String
    let provider: AgentProvider?
    let providerRawValue: String?
    let projectName: String?
    let title: String
    let subtitle: String?
    let snippet: String
    let sectionPath: String?
    let startOffset: Int
    let endOffset: Int
    let sourceUpdatedAt: Date?
    let indexedAt: Date
    let lexicalRank: Double?
    let semanticScore: Double?
    let rerankScore: Double
    let conversation: ConversationRecord?

    var id: String { chunkID }
}
