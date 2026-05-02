import Foundation
import FirebaseFirestore
import OpenBurnBarCore

@Observable
@MainActor
final class QuotaStore {
    private let firestore: FirestoreRepository

    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var snapshots: [ProviderQuotaSnapshot] = []
    private var listener: ListenerRegistration?

    init(firestore: FirestoreRepository = FirestoreRepository()) {
        self.firestore = firestore
    }

    // Listener cleanup happens in `stopListening()` which is invoked from the
    // view's `.onDisappear`. We deliberately avoid a `deinit` cleanup hop:
    // (1) `@State` keeps the store alive for the view's lifetime, so leaks
    // here would imply a view leak that is the larger bug; (2) Swift 6
    // forbids reading `@MainActor` state from a nonisolated deinit.

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

    /// Re-fetches the latest snapshots; used by pull-to-refresh.
    func refresh() async {
        await load()
    }

    /// Subscribes to live quota updates. Safe to call multiple times — only
    /// one listener stays attached at any moment.
    func startListening() {
        listener?.remove()
        listener = firestore.listenToQuotaSnapshots { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let snaps):
                    self.snapshots = snaps
                    self.error = nil
                case .failure(let err):
                    self.error = err.localizedDescription
                }
            }
        }
    }

    /// Detaches the live listener; call on view `onDisappear`.
    func stopListening() {
        listener?.remove()
        listener = nil
    }

    var urgencySorted: [ProviderQuotaSnapshot] {
        snapshots.sorted {
            remainingFraction(for: $0) < remainingFraction(for: $1)
        }
    }

    /// Snapshots grouped by their persisted-token provider key.
    var snapshotsByProvider: [String: [ProviderQuotaSnapshot]] {
        Dictionary(grouping: snapshots, by: \.provider)
    }

    /// Provider keys sorted by urgency where any bucket has < 25% remaining.
    var urgentProviders: [String] {
        snapshotsByProvider
            .filter { _, snaps in snaps.contains(where: { isUrgent($0) }) }
            .keys
            .sorted { lhs, rhs in
                pressureScore(for: lhs) < pressureScore(for: rhs)
            }
    }

    /// Provider keys whose worst bucket has at least 25% headroom.
    var healthyProviders: [String] {
        let urgent = Set(urgentProviders)
        return snapshotsByProvider.keys
            .filter { !urgent.contains($0) }
            .sorted()
    }

    func snapshots(for provider: AgentProvider) -> [ProviderQuotaSnapshot] {
        snapshots.filter { $0.provider == provider.rawValue }
    }

    /// Fraction `0...1` representing the most-pressured bucket on a snapshot.
    /// Returns `.infinity` when no bucket has a usable limit so unknown
    /// snapshots sort to the end.
    private func remainingFraction(for snapshot: ProviderQuotaSnapshot) -> Double {
        let pressured = snapshot.buckets.compactMap { bucket -> Double? in
            guard bucket.limit > 0 else { return nil }
            return max(0, bucket.remaining) / bucket.limit
        }
        return pressured.min() ?? .infinity
    }

    private func isUrgent(_ snapshot: ProviderQuotaSnapshot) -> Bool {
        if snapshot.confidence == .stale { return true }
        return remainingFraction(for: snapshot) < 0.25
    }

    private func pressureScore(for provider: String) -> Double {
        (snapshotsByProvider[provider] ?? [])
            .map { remainingFraction(for: $0) }
            .min() ?? .infinity
    }
}
