import Foundation
import OpenBurnBarCore
import FirebaseFirestore

@Observable
@MainActor
final class ActivityStore {
    private let firestore: FirestoreRepository
    private let functions: FunctionsRepository

    private(set) var isLoading = false
    private(set) var isSearching = false
    private(set) var error: String?
    private(set) var rawUsages: [TokenUsage] = []
    private(set) var liveUsages: [TokenUsage] = []
    private(set) var usages: [TokenUsage] = []
    private(set) var searchHits: [StreamSearchHit] = []
    private(set) var hasMore = true
    private var lastDoc: DocumentSnapshot?
    private var liveUsageListener: ListenerRegistration?
    private let targetSessionPageSize = 25
    private let rawPageSize = 100
    private let maxRawPagesPerBatch = 6
    private var lastSearchQuery = ""

    /// Optional provider filter applied to the next fetch. The view binds
    /// directly to this and calls `applyFilters()` to re-query.
    var filterProvider: AgentProvider?
    var filterStartDate: Date?
    var filterEndDate: Date?

    init(
        firestore: FirestoreRepository = FirestoreRepository(),
        functions: FunctionsRepository = FunctionsRepository()
    ) {
        self.firestore = firestore
        self.functions = functions
    }

    /// Convenience alias used by `.task` and pull-to-refresh on first load.
    func loadInitial() async {
        await refresh()
    }

    /// Fetches the next page when the user reaches the bottom of the list.
    func loadNext() async {
        await loadMore()
    }

    func load() async {
        if AppStoreScreenshotMode.isEnabled {
            isLoading = false
            error = nil
            rawUsages = AppStoreScreenshotData.recentUsage
            liveUsages = AppStoreScreenshotData.recentUsage
            usages = Self.summarizeSessions(rawUsages)
            lastDoc = nil
            hasMore = false
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let batch = try await fetchRawBatch(after: nil, existingSessionKeys: [])
            rawUsages = batch.rows
            if liveUsages.isEmpty {
                liveUsages = batch.rows
            }
            usages = Self.summarizeSessions(rawUsages)
            lastDoc = batch.last
            hasMore = batch.hasMore
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        guard !AppStoreScreenshotMode.isEnabled else { return }
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let batch = try await fetchRawBatch(
                after: lastDoc,
                existingSessionKeys: Set(rawUsages.map(Self.sessionKey))
            )
            rawUsages.append(contentsOf: batch.rows)
            usages = Self.summarizeSessions(rawUsages)
            lastDoc = batch.last
            hasMore = batch.hasMore
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refresh() async {
        if AppStoreScreenshotMode.isEnabled {
            await load()
            return
        }
        lastDoc = nil
        rawUsages = []
        usages = []
        hasMore = true
        await load()
    }

    func loadLiveUsage(since startDate: Date) async {
        if AppStoreScreenshotMode.isEnabled {
            liveUsages = AppStoreScreenshotData.recentUsage
            return
        }
        do {
            liveUsages = try await firestore.fetchUsageSince(startDate)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func startLiveUsageListening(since startDate: Date) {
        guard !AppStoreScreenshotMode.isEnabled else {
            liveUsages = AppStoreScreenshotData.recentUsage
            return
        }
        liveUsageListener?.remove()
        liveUsageListener = firestore.listenToUsageSince(startDate) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let rows):
                self.liveUsages = rows
                self.error = nil
            case .failure(let error):
                self.error = error.localizedDescription
            }
        }
    }

    func stopLiveUsageListening() {
        liveUsageListener?.remove()
        liveUsageListener = nil
    }

    /// Re-runs the query with the current `filter*` properties. Called by
    /// the FilterSheet's Done button.
    func applyFilters() async {
        await refresh()
    }

    func updateSearch(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSearchQuery = trimmed
        guard trimmed.count >= 2 else {
            searchHits = []
            isSearching = false
            return
        }

        isSearching = true
        do {
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()
            guard lastSearchQuery == trimmed else { return }
            searchHits = try await functions.searchStreams(query: trimmed)
        } catch is CancellationError {
            return
        } catch {
            searchHits = []
        }
        isSearching = false
    }

    private func fetchRawBatch(
        after: DocumentSnapshot?,
        existingSessionKeys: Set<String>
    ) async throws -> (rows: [TokenUsage], last: DocumentSnapshot?, hasMore: Bool) {
        var rows: [TokenUsage] = []
        var cursor = after
        var last = after
        var hitEnd = false
        var sessionKeys = existingSessionKeys
        let startingSessionCount = sessionKeys.count

        for _ in 0..<maxRawPagesPerBatch {
            let (page, pageLast) = try await firestore.fetchUsagePage(
                pageSize: rawPageSize,
                after: cursor,
                provider: filterProvider?.rawValue,
                model: nil,
                device: nil,
                startDate: filterStartDate,
                endDate: filterEndDate
            )

            if page.isEmpty {
                hitEnd = true
                last = pageLast ?? cursor
                break
            }

            rows.append(contentsOf: page)
            page.forEach { sessionKeys.insert(Self.sessionKey(for: $0)) }
            cursor = pageLast
            last = pageLast

            if page.count < rawPageSize {
                hitEnd = true
                break
            }
            if sessionKeys.count - startingSessionCount >= targetSessionPageSize {
                break
            }
        }

        return (rows, last, !hitEnd && last != nil)
    }

    nonisolated static func summarizeSessions(_ rows: [TokenUsage]) -> [TokenUsage] {
        var groups: [String: [TokenUsage]] = [:]
        for row in rows {
            groups[sessionKey(for: row), default: []].append(row)
        }

        return groups.values
            .compactMap(sessionSummary)
            .sorted { activityDate(for: $0) > activityDate(for: $1) }
    }

    nonisolated static func sessionKey(for usage: TokenUsage) -> String {
        let sessionID = usage.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sessionID.isEmpty == false else {
            return "\(usage.provider.rawValue)|row|\(usage.id.uuidString)"
        }
        return "\(usage.provider.rawValue)|\(sessionID)"
    }

    nonisolated static func activityDate(for usage: TokenUsage) -> Date {
        max(usage.startTime, usage.endTime)
    }

    nonisolated private static func sessionSummary(from rows: [TokenUsage]) -> TokenUsage? {
        guard let latest = rows.max(by: { activityDate(for: $0) < activityDate(for: $1) }) else {
            return nil
        }
        let earliestStart = rows.map { min($0.startTime, $0.endTime) }.min() ?? latest.startTime
        let latestEnd = rows.map { max($0.startTime, $0.endTime) }.max() ?? latest.endTime
        let inputTokens = rows.reduce(0) { $0 + $1.inputTokens }
        let outputTokens = rows.reduce(0) { $0 + $1.outputTokens }
        let cacheCreationTokens = rows.reduce(0) { $0 + $1.cacheCreationTokens }
        let cacheReadTokens = rows.reduce(0) { $0 + $1.cacheReadTokens }
        let reasoningTokens = rows.reduce(0) { $0 + $1.reasoningTokens }
        let totalCost = rows.reduce(0) { $0 + $1.cost }
        let createdAt = rows.map(\.createdAt).max() ?? latest.createdAt

        return TokenUsage(
            id: latest.id,
            provider: latest.provider,
            sessionId: latest.sessionId,
            projectName: latestNonBlank(rows, \.projectName) ?? latest.projectName,
            model: dominantModel(in: rows, fallback: latest.model),
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            costUSD: totalCost,
            startTime: earliestStart,
            endTime: latestEnd,
            createdAt: createdAt,
            usageSource: latest.usageSource,
            sourceDeviceId: latestNonBlank(rows, \.sourceDeviceId) ?? latest.sourceDeviceId,
            sourceDeviceName: latestNonBlank(rows, \.sourceDeviceName) ?? latest.sourceDeviceName,
            isRemote: rows.contains(where: \.isRemote),
            providerID: latest.providerID,
            providerAccountID: latestNonBlank(rows, \.providerAccountID) ?? latest.providerAccountID,
            providerAccountLabel: latestNonBlank(rows, \.providerAccountLabel) ?? latest.providerAccountLabel,
            providerAccountSource: latest.providerAccountSource,
            provenanceMethod: rows.map(\.provenanceMethod).max() ?? latest.provenanceMethod,
            provenanceConfidence: rows.map(\.provenanceConfidence).max() ?? latest.provenanceConfidence,
            estimatorVersion: latestNonBlank(rows, \.estimatorVersion) ?? latest.estimatorVersion
        )
    }

    nonisolated private static func dominantModel(in rows: [TokenUsage], fallback: String) -> String {
        struct ModelStats {
            var tokens = 0
            var cost = 0.0
            var lastSeen = Date.distantPast
        }

        let stats = rows.reduce(into: [String: ModelStats]()) { result, row in
            let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard model.isEmpty == false else { return }
            var current = result[model] ?? ModelStats()
            current.tokens += row.totalTokens
            current.cost += row.cost
            current.lastSeen = max(current.lastSeen, activityDate(for: row))
            result[model] = current
        }

        return stats.sorted { lhs, rhs in
            if lhs.value.tokens != rhs.value.tokens { return lhs.value.tokens > rhs.value.tokens }
            if lhs.value.cost != rhs.value.cost { return lhs.value.cost > rhs.value.cost }
            return lhs.value.lastSeen > rhs.value.lastSeen
        }.first?.key ?? fallback
    }

    nonisolated private static func latestNonBlank(
        _ rows: [TokenUsage],
        _ keyPath: KeyPath<TokenUsage, String>
    ) -> String? {
        latestNonBlank(rows) { $0[keyPath: keyPath] }
    }

    nonisolated private static func latestNonBlank(
        _ rows: [TokenUsage],
        _ keyPath: KeyPath<TokenUsage, String?>
    ) -> String? {
        latestNonBlank(rows) { $0[keyPath: keyPath] }
    }

    nonisolated private static func latestNonBlank(
        _ rows: [TokenUsage],
        value: (TokenUsage) -> String?
    ) -> String? {
        rows
            .sorted { activityDate(for: $0) > activityDate(for: $1) }
            .compactMap { value($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.isEmpty == false }
    }
}
