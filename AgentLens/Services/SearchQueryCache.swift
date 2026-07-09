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
    let conversationSources: Set<OpenBurnBarCore.ConversationSourceType>?
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

/// Bounded LRU cache for search query results.
///
/// Round-4 perf sweep: the original cache was an unbounded dictionary whose
/// only eviction was lazy removal of an expired key *when that exact key was
/// read again*. Under rapid typing or many distinct filter combinations it
/// grew without limit and never reclaimed memory for stale entries. This
/// version caps the entry count, evicts least-recently-used entries on
/// insertion, sweeps expired entries opportunistically, and emits hit/miss/
/// size counters through `OpenBurnBarMetrics` so cache effectiveness is
/// observable in production telemetry (the prior reviews explicitly asked
/// for this).
final class SearchQueryCache: Sendable {
    static let shared = SearchQueryCache()

    /// Default cap: 256 distinct query shapes. Each entry holds a
    /// `OpenBurnBarQueryRunResult` (bounded by `resultLimit`), so 256 entries
    /// is well under 10 MB even at `resultLimit = 200` with full context.
    static let defaultMaxEntries = 256

    private struct Bucket {
        var entry: SearchQueryCacheEntry
        /// Monotonic insertion/access order stamp; lower = older.
        var orderStamp: UInt64
    }

    private let buckets = Locked<[SearchQueryCacheKey: Bucket]>([:])
    private let maxEntries: Int
    private let orderCounter = Locked<UInt64>(0)

    // Counters are read+reset atomically by `snapshotAndResetCounters`; they
    // are written under the `buckets` lock so a snapshot is consistent with
    // the live cache state.
    private struct Counters {
        var hits = 0
        var misses = 0
        var evictions = 0
        var expiredEvictions = 0
    }
    private let counters = Locked<Counters>(Counters())

    init(maxEntries: Int = SearchQueryCache.defaultMaxEntries) {
        self.maxEntries = max(1, maxEntries)
    }

    func get(key: SearchQueryCacheKey, now: Date) -> OpenBurnBarQueryRunResult? {
        buckets.withLock { cache in
            guard let bucket = cache[key] else {
                counters.withLock { $0.misses += 1 }
                return nil
            }
            if bucket.entry.isValid(at: now) {
                // Refresh LRU stamp on access so frequently-repeated queries
                // survive longer than one-off queries.
                let stamp = nextOrderStamp()
                cache[key] = Bucket(entry: bucket.entry, orderStamp: stamp)
                counters.withLock { $0.hits += 1 }
                return bucket.entry.result
            }
            cache.removeValue(forKey: key)
            counters.withLock { $0.misses += 1; $0.expiredEvictions += 1 }
            return nil
        }
    }

    func set(key: SearchQueryCacheKey, result: OpenBurnBarQueryRunResult, now: Date) {
        buckets.withLock { cache in
            // Opportunistic expired-entry sweep: every insertion walks the
            // table once and drops anything past TTL. Cost is O(n) but n is
            // capped at `maxEntries`, and this is the only path that reclaims
            // entries for keys that are never read again (the common case
            // for one-off queries).
            if cache.count >= maxEntries / 2 {
                for (k, b) in cache where b.entry.isValid(at: now) == false {
                    cache.removeValue(forKey: k)
                    counters.withLock { $0.expiredEvictions += 1 }
                }
            }
            let stamp = nextOrderStamp()
            cache[key] = Bucket(entry: SearchQueryCacheEntry(result: result, createdAt: now), orderStamp: stamp)
            // Enforce the cap by evicting the least-recently-used entry/entries.
            while cache.count > maxEntries {
                if let lru = cache.min(by: { $0.value.orderStamp < $1.value.orderStamp }) {
                    cache.removeValue(forKey: lru.key)
                    counters.withLock { $0.evictions += 1 }
                } else {
                    break
                }
            }
        }
    }

    func clear() {
        buckets.withLock { $0.removeAll() }
    }

    /// Current number of cached entries (test/diagnostic surface).
    var count: Int {
        buckets.read().count
    }

    /// Atomically snapshot and reset the hit/miss/eviction counters, then
    /// emit them through `OpenBurnBarMetrics`. Callers (e.g. a periodic
    /// health sampler) decide the cadence; the cache itself stays passive.
    @discardableResult
    func snapshotAndResetCounters() -> SearchQueryCacheCounters {
        // Read entryCount *before* acquiring the counters lock to avoid a
        // lock-ordering inversion with get/set (which acquire buckets then
        // counters). A slightly stale entry count on a metric is acceptable.
        let entryCount = buckets.read().count
        let snapshot = counters.withLock { c -> SearchQueryCacheCounters in
            let s = SearchQueryCacheCounters(
                hits: c.hits,
                misses: c.misses,
                evictions: c.evictions,
                expiredEvictions: c.expiredEvictions,
                entryCount: entryCount
            )
            c = Counters()
            return s
        }
        OpenBurnBarMetrics.gauge(name: "search_cache_entries", value: Double(snapshot.entryCount), labels: [:])
        OpenBurnBarMetrics.counter(name: "search_cache_hits_total", delta: Double(snapshot.hits), labels: [:])
        OpenBurnBarMetrics.counter(name: "search_cache_misses_total", delta: Double(snapshot.misses), labels: [:])
        OpenBurnBarMetrics.counter(name: "search_cache_evictions_total", delta: Double(snapshot.evictions), labels: [:])
        OpenBurnBarMetrics.counter(name: "search_cache_expired_evictions_total", delta: Double(snapshot.expiredEvictions), labels: [:])
        return snapshot
    }

    private func nextOrderStamp() -> UInt64 {
        orderCounter.withLock { counter in
            counter &+= 1
            return counter
        }
    }
}

struct SearchQueryCacheCounters: Equatable, Sendable {
    let hits: Int
    let misses: Int
    let evictions: Int
    let expiredEvictions: Int
    let entryCount: Int

    var hitRate: Double {
        let total = hits + misses
        guard total > 0 else { return 0 }
        return Double(hits) / Double(total)
    }
}
