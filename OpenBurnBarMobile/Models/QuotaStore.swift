import Foundation
import OpenBurnBarCore

@Observable
@MainActor
final class QuotaStore {
    private let firestore: FirestoreRepository

    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var snapshots: [ProviderQuotaSnapshot] = []

    init(firestore: FirestoreRepository = FirestoreRepository()) {
        self.firestore = firestore
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            snapshots = try await firestore.fetchQuotaSnapshots()
        } catch {
            self.error = error.localizedDescription
        }
    }

    var urgencySorted: [ProviderQuotaSnapshot] {
        snapshots.sorted {
            let lhs = $0.primaryBucket?.remainingPercent ?? .infinity
            let rhs = $1.primaryBucket?.remainingPercent ?? .infinity
            return lhs < rhs
        }
    }

    func snapshots(for provider: AgentProvider) -> [ProviderQuotaSnapshot] {
        snapshots.filter { $0.provider == provider }
    }
}
