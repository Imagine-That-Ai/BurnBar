import Foundation
import OpenBurnBarCore

// MARK: - Search Query Cache

struct SearchQueryCacheKey: Hashable, Sendable {
    let text: String
    let lexicalFTSQuery: String?
    let provider: String?
    let projectName: String?
    let artifactTypes: Set<SearchSourceKind>?
    let dateRangeLower: Date?
    let dateRangeUpper: Date?
    let ownership: String
    let sourceIDs: Set<String>?
    let conversationSources: Set<ConversationSourceType>?
    let lexicalCandidateLimit: Int
    let semanticCandidateLimit: Int
    let rerankCandidateLimit: Int
    let resultLimit: Int
    let hybridFusionStrategy: String
    let crossEncoderEnabled: Bool
    let crossEncoderCandidateLimit: Int

    init(query: RetrievalQuery) {
        self.text = query.text
        self.lexicalFTSQuery = query.lexicalFTSQuery
        self.provider = query.filters.provider?.rawValue
        self.projectName = query.filters.projectName
        self.artifactTypes = query.filters.artifactTypes
        self.dateRangeLower = query.filters.dateRange?.lowerBound
        self.dateRangeUpper = query.filters.dateRange?.upperBound
        self.ownership = query.filters.ownership.rawValue
        self.sourceIDs = query.filters.sourceIDs
        self.conversationSources = query.filters.conversationSources
        self.lexicalCandidateLimit = query.lexicalCandidateLimit
        self.semanticCandidateLimit = query.semanticCandidateLimit
        self.rerankCandidateLimit = query.rerankCandidateLimit
        self.resultLimit = query.resultLimit
        self.hybridFusionStrategy = query.hybridFusionStrategy.rawValue
        self.crossEncoderEnabled = query.crossEncoderEnabled
        self.crossEncoderCandidateLimit = query.crossEncoderCandidateLimit
    }
}

struct SearchQueryCacheEntry: Sendable {
    let result: OpenBurnBarQueryRunResult
    let createdAt: Date

    func isValid(at date: Date, ttl: TimeInterval = 30) -> Bool {
        date.timeIntervalSince(createdAt) <= ttl
    }
}

final class SearchQueryCache: @unchecked Sendable {
    static let shared = SearchQueryCache()
    private let lock = NSLock()
    private var cache: [SearchQueryCacheKey: SearchQueryCacheEntry] = [:]

    private init() {}

    func get(key: SearchQueryCacheKey, now: Date) -> OpenBurnBarQueryRunResult? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = cache[key] else { return nil }
        if entry.isValid(at: now) {
            return entry.result
        }
        cache.removeValue(forKey: key)
        return nil
    }

    func set(key: SearchQueryCacheKey, result: OpenBurnBarQueryRunResult, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        cache[key] = SearchQueryCacheEntry(result: result, createdAt: now)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}
