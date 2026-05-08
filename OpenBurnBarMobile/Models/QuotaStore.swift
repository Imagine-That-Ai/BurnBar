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
    private(set) var accounts: [ProviderAccountDoc] = []
    private(set) var currentUserDisplayID: String?
    private(set) var urgencySorted: [ProviderQuotaSnapshot] = []
    private(set) var visibleProviders: [String] = []
    private(set) var snapshotsByProvider: [String: [ProviderQuotaSnapshot]] = [:]
    private(set) var urgentProviders: [String] = []
    private(set) var healthyProviders: [String] = []
    private var listener: ListenerRegistration?
    private var lastAccountRefreshAt: Date?

    init(firestore: FirestoreRepository = FirestoreRepository()) {
        self.firestore = firestore
    }

    // Listener cleanup happens in `stopListening()` which is invoked from the
    // view's `.onDisappear`. We deliberately avoid a `deinit` cleanup hop:
    // (1) `@State` keeps the store alive for the view's lifetime, so leaks
    // here would imply a view leak that is the larger bug; (2) Swift 6
    // forbids reading `@MainActor` state from a nonisolated deinit.

    func load() async {
        if AppStoreScreenshotMode.isEnabled {
            applyScreenshotData()
            return
        }
        isLoading = true
        error = nil
        captureCurrentUser()
        defer { isLoading = false }

        do {
            async let snapshotsTask = firestore.fetchQuotaSnapshots()
            async let accountsTask = firestore.fetchProviderAccounts()
            applySnapshots(try await snapshotsTask)
            // Account fetch is best-effort — routing visualization is
            // additive, never required.
            if let docs = try? await accountsTask {
                applyAccounts(docs)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Re-fetches the latest snapshots; used by pull-to-refresh.
    func refresh() async {
        if AppStoreScreenshotMode.isEnabled {
            applyScreenshotData()
            return
        }
        await load()
    }

    /// Subscribes to live quota updates. Safe to call multiple times — only
    /// one listener stays attached at any moment.
    func startListening() {
        guard !AppStoreScreenshotMode.isEnabled else { return }
        listener?.remove()
        captureCurrentUser()
        listener = firestore.listenToQuotaSnapshots { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let snaps):
                    self.applySnapshots(snaps)
                    self.error = nil
                    await self.refreshAccountsIfStale()
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

    private func captureCurrentUser() {
        currentUserDisplayID = firestore.currentUserDisplayID()
    }

    private func applyScreenshotData() {
        isLoading = false
        error = nil
        applySnapshots(AppStoreScreenshotData.quotaSnapshots)
        applyAccounts(AppStoreScreenshotData.providerAccounts)
        currentUserDisplayID = "…demo"
    }

    func accounts(for providerID: ProviderID) -> [ProviderAccountDoc] {
        accounts.filter { $0.providerID == providerID && $0.status != .deleted }
    }

    private func normalizeQuotaSnapshots(_ snapshots: [ProviderQuotaSnapshot]) -> [ProviderQuotaSnapshot] {
        snapshots.compactMap { $0.filteringToDisplayableQuotaSignal() }
    }

    func routingState(for providerID: ProviderID) -> ProviderRoutingStateSnapshot? {
        ProviderRoutingStateBuilder.build(
            providerID: providerID,
            accounts: accounts,
            snapshots: snapshots
        )
    }

    private func applySnapshots(_ newSnapshots: [ProviderQuotaSnapshot]) {
        snapshots = normalizeQuotaSnapshots(newSnapshots)
        rebuildDerivedSnapshotState()
    }

    private func applyAccounts(_ newAccounts: [ProviderAccountDoc]) {
        accounts = newAccounts
        lastAccountRefreshAt = Date()
    }

    private func refreshAccountsIfStale(maxAge: TimeInterval = 60) async {
        if let lastAccountRefreshAt,
           Date().timeIntervalSince(lastAccountRefreshAt) < maxAge,
           !accounts.isEmpty {
            return
        }
        if let docs = try? await firestore.fetchProviderAccounts() {
            applyAccounts(docs)
        }
    }

    private func rebuildDerivedSnapshotState() {
        urgencySorted = snapshots.sorted {
            remainingFraction(for: $0) < remainingFraction(for: $1)
        }

        snapshotsByProvider = Dictionary(grouping: snapshots, by: { $0.providerID.rawValue })
        visibleProviders = Array(snapshotsByProvider.keys).sorted()
        urgentProviders = snapshotsByProvider
            .filter { _, snaps in snaps.contains(where: { isUrgent($0) }) }
            .keys
            .sorted { lhs, rhs in
                pressureScore(for: lhs) < pressureScore(for: rhs)
            }
        let urgent = Set(urgentProviders)
        healthyProviders = snapshotsByProvider.keys
            .filter { !urgent.contains($0) }
            .sorted()
    }

    func sortedSnapshots(for provider: String) -> [ProviderQuotaSnapshot] {
        (snapshotsByProvider[provider] ?? []).sorted {
            let lhs = ($0.accountLabel ?? $0.accountID ?? $0.sourceID).localizedCaseInsensitiveCompare($1.accountLabel ?? $1.accountID ?? $1.sourceID)
            if lhs != .orderedSame { return lhs == .orderedAscending }
            return $0.fetchedAt > $1.fetchedAt
        }
    }

    func accountCount(for provider: String) -> Int {
        let ids = Set((snapshotsByProvider[provider] ?? []).compactMap(\.accountID))
        return max(ids.count, snapshotsByProvider[provider]?.isEmpty == false ? 1 : 0)
    }

    func snapshots(for provider: AgentProvider) -> [ProviderQuotaSnapshot] {
        snapshots.filter { $0.providerID == provider.providerID || $0.provider == provider.rawValue }
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
