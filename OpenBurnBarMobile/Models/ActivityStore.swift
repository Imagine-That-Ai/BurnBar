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
    private(set) var usages: [TokenUsage] = []
    private(set) var searchHits: [StreamSearchHit] = []
    private(set) var hasMore = true
    private var lastDoc: DocumentSnapshot?
    private let pageSize = 25
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
            usages = AppStoreScreenshotData.recentUsage
            lastDoc = nil
            hasMore = false
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let (page, last) = try await firestore.fetchUsagePage(
                pageSize: pageSize,
                after: nil,
                provider: filterProvider?.rawValue,
                model: nil,
                device: nil,
                startDate: filterStartDate,
                endDate: filterEndDate
            )
            usages = page
            lastDoc = last
            hasMore = page.count == pageSize
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
            let (page, last) = try await firestore.fetchUsagePage(
                pageSize: pageSize,
                after: lastDoc,
                provider: filterProvider?.rawValue,
                model: nil,
                device: nil,
                startDate: filterStartDate,
                endDate: filterEndDate
            )
            usages.append(contentsOf: page)
            lastDoc = last
            hasMore = page.count == pageSize
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
        usages = []
        hasMore = true
        await load()
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
}
