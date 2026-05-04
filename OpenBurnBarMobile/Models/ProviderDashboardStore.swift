import Foundation
import OpenBurnBarCore
import FirebaseFirestore

@Observable
@MainActor
final class ProviderDashboardStore {
    private let firestore: FirestoreRepository
    private let provider: AgentProvider

    private(set) var isLoading = false
    private(set) var error: String?
    var usages: [TokenUsage] = []
    private(set) var hasMore = true
    private var lastDoc: DocumentSnapshot?
    private let pageSize = 25

    init(provider: AgentProvider, firestore: FirestoreRepository = FirestoreRepository()) {
        self.provider = provider
        self.firestore = firestore
    }

    var totalCost: Double {
        usages.reduce(0) { $0 + $1.cost }
    }

    var totalTokens: Int {
        usages.reduce(0) { $0 + $1.totalTokens }
    }

    var totalSessions: Int { usages.count }

    var inputTokens: Int { usages.reduce(0) { $0 + $1.inputTokens } }
    var outputTokens: Int { usages.reduce(0) { $0 + $1.outputTokens } }
    var cacheReadTokens: Int { usages.reduce(0) { $0 + $1.cacheReadTokens } }
    var cacheCreationTokens: Int { usages.reduce(0) { $0 + $1.cacheCreationTokens } }

    var dailyPoints: [(date: Date, cost: Double, tokens: Int)] {
        let calendar = Calendar.current
        var buckets: [Date: (cost: Double, tokens: Int)] = [:]
        for usage in usages {
            let day = calendar.startOfDay(for: usage.startTime)
            var entry = buckets[day] ?? (0, 0)
            entry.cost += usage.cost
            entry.tokens += usage.totalTokens
            buckets[day] = entry
        }
        return buckets
            .map { (date: $0.key, cost: $0.value.cost, tokens: $0.value.tokens) }
            .sorted { $0.date < $1.date }
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let (page, last) = try await firestore.fetchUsagePage(
                pageSize: pageSize,
                after: nil,
                provider: provider.rawValue,
                model: nil,
                device: nil,
                startDate: nil,
                endDate: nil
            )
            usages = page
            lastDoc = last
            hasMore = page.count == pageSize
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let (page, last) = try await firestore.fetchUsagePage(
                pageSize: pageSize,
                after: lastDoc,
                provider: provider.rawValue,
                model: nil,
                device: nil,
                startDate: nil,
                endDate: nil
            )
            usages.append(contentsOf: page)
            lastDoc = last
            hasMore = page.count == pageSize
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refresh() async {
        lastDoc = nil
        usages = []
        hasMore = true
        await load()
    }
}
