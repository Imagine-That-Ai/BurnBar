import Foundation
import OpenBurnBarCore
import FirebaseFirestore

@Observable
@MainActor
final class ActivityStore {
    private let firestore: FirestoreRepository

    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var usages: [TokenUsage] = []
    private(set) var hasMore = true
    private var lastDoc: DocumentSnapshot?
    private let pageSize = 25

    init(firestore: FirestoreRepository = FirestoreRepository()) {
        self.firestore = firestore
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let (page, last) = try await firestore.fetchUsagePage(limit: pageSize)
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
            let (page, last) = try await firestore.fetchUsagePage(limit: pageSize, after: lastDoc)
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
