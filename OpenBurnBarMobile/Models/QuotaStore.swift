import Foundation
import FirebaseFirestore
import OpenBurnBarCore
import OSLog

private let quotaStoreLogger = Logger(subsystem: "com.openburnbar.mobile", category: "QuotaStore")

@Observable
@MainActor
final class QuotaStore {
    private let firestore: FirestoreRepository
    private let functions: FunctionsRepository

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
    private var staleRefreshInFlight: Set<String> = []
    private var automaticRefreshTask: Task<Void, Never>?

    init(
        firestore: FirestoreRepository = FirestoreRepository(),
        functions: FunctionsRepository = FunctionsRepository()
    ) {
        self.firestore = firestore
        self.functions = functions
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
            await refreshStaleCloudQuotaIfPossible()
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
        startAutomaticRefresh()
        listener?.remove()
        captureCurrentUser()
        listener = firestore.listenToQuotaSnapshotUpdates { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let update):
                    let incomingVisibleProviders = Self.visibleProviderIDs(in: self.normalizeQuotaSnapshots(update.snapshots))
                    if Self.shouldApplySnapshotUpdate(
                        currentVisibleProviders: Set(self.visibleProviders),
                        incomingVisibleProviders: incomingVisibleProviders,
                        isFromCache: update.isFromCache
                    ) == false {
                        quotaStoreLogger.info(
                            "Ignored cache-only quota snapshot regression: currentProviders=[\(self.visibleProviders.joined(separator: ","), privacy: .public)] incomingProviders=[\(incomingVisibleProviders.sorted().joined(separator: ","), privacy: .public)] rawDocuments=\(update.rawDocumentCount)"
                        )
                        self.error = nil
                        return
                    }
                    self.applySnapshots(update.snapshots)
                    self.error = nil
                    await self.refreshAccountsIfStale()
                    await self.refreshStaleCloudQuotaIfPossible()
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
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
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

    nonisolated static func shouldApplySnapshotUpdate(
        currentVisibleProviders: Set<String>,
        incomingVisibleProviders: Set<String>,
        isFromCache: Bool
    ) -> Bool {
        guard isFromCache else { return true }
        guard currentVisibleProviders.isEmpty == false else { return true }
        return incomingVisibleProviders.count >= currentVisibleProviders.count
    }

    nonisolated private static func visibleProviderIDs(in snapshots: [ProviderQuotaSnapshot]) -> Set<String> {
        Set(snapshots.map(\.providerID.rawValue))
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
        rebuildDerivedSnapshotState()
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

    private func refreshStaleCloudQuotaIfPossible(maxRefreshes: Int = 3) async {
        let byAccount = Dictionary(grouping: snapshots) { $0.accountID ?? "" }
        let refreshable = accounts
            .filter { account in
                account.status == .connected || account.status == .stale || account.status == .error
            }
            .filter { account in
                account.storageScope == .cloudRefreshable || account.storageScope == .serverPrivate
            }
            .filter { account in
                guard !staleRefreshInFlight.contains(account.id) else { return false }
                guard let accountSnapshots = byAccount[account.id], !accountSnapshots.isEmpty else { return true }
                return accountSnapshots.contains { $0.isStale() }
            }
            .prefix(maxRefreshes)

        guard !refreshable.isEmpty else { return }

        for account in refreshable {
            staleRefreshInFlight.insert(account.id)
            defer { staleRefreshInFlight.remove(account.id) }
            do {
                let refreshed = try await functions.refreshProviderAccountQuota(accountID: account.id)
                let merged = snapshots
                    .filter { $0.accountID != refreshed.accountID || $0.sourceID != refreshed.sourceID }
                    + [refreshed]
                applySnapshots(merged)
            } catch {
                quotaStoreLogger.warning("Failed to refresh stale quota for \(account.providerID.rawValue, privacy: .public)/\(account.id, privacy: .private): \(error.localizedDescription)")
            }
        }
    }

    private func startAutomaticRefresh() {
        guard automaticRefreshTask == nil else { return }
        automaticRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled else { return }
                await self?.refreshStaleCloudQuotaIfPossible(maxRefreshes: 10)
            }
        }
    }

    private func rebuildDerivedSnapshotState() {
        urgencySorted = snapshots.sorted {
            remainingFraction(for: $0) < remainingFraction(for: $1)
        }

        snapshotsByProvider = Self.snapshotsByDisplayProvider(snapshots: snapshots, accounts: accounts)
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

        let rawSnapshotProviders = Set(snapshots.map(\.providerID.rawValue)).sorted().joined(separator: ",")
        let accountProviders = Set(
            accounts
                .filter { $0.status != .deleted }
                .map(\.providerID.rawValue)
        )
            .sorted()
            .joined(separator: ",")
        quotaStoreLogger.info(
            "Derived quota state: snapshots=\(self.snapshots.count) accounts=\(self.accounts.count) rawSnapshotProviders=[\(rawSnapshotProviders, privacy: .public)] visibleProviders=[\(self.visibleProviders.joined(separator: ","), privacy: .public)] accountProviders=[\(accountProviders, privacy: .public)]"
        )
    }

    func sortedSnapshots(for provider: String) -> [ProviderQuotaSnapshot] {
        (snapshotsByProvider[provider] ?? []).sorted {
            let lhs = ($0.accountLabel ?? $0.accountID ?? $0.sourceID).localizedCaseInsensitiveCompare($1.accountLabel ?? $1.accountID ?? $1.sourceID)
            if lhs != .orderedSame { return lhs == .orderedAscending }
            return $0.fetchedAt > $1.fetchedAt
        }
    }

    func accountCount(for provider: String) -> Int {
        Self.accountCount(
            for: provider,
            snapshots: snapshotsByProvider[provider] ?? [],
            accounts: accounts
        )
    }

    nonisolated static func accountCount(
        for provider: String,
        snapshots: [ProviderQuotaSnapshot],
        accounts: [ProviderAccountDoc]
    ) -> Int {
        let snapshotAccountIDs = Set(snapshots.compactMap(\.accountID))
        let connectedAccountCount = accounts.filter {
            $0.status != .deleted && $0.providerID.rawValue == provider
        }.count
        return max(connectedAccountCount, snapshotAccountIDs.count, snapshots.isEmpty ? 0 : 1)
    }

    nonisolated static func snapshotsByDisplayProvider(
        snapshots: [ProviderQuotaSnapshot],
        accounts: [ProviderAccountDoc]
    ) -> [String: [ProviderQuotaSnapshot]] {
        Dictionary(grouping: snapshots) { snapshot in
            providerDisplayKey(for: snapshot, accounts: accounts)
        }
    }

    nonisolated static func providerDisplayKey(
        for snapshot: ProviderQuotaSnapshot,
        accounts: [ProviderAccountDoc]
    ) -> String {
        guard let accountID = snapshot.accountID,
              let account = accounts.first(where: { $0.id == accountID && $0.status != .deleted }) else {
            return snapshot.providerID.rawValue
        }
        return account.providerID.rawValue
    }

    func snapshots(for provider: AgentProvider) -> [ProviderQuotaSnapshot] {
        snapshots.filter {
            $0.providerID == provider.providerID
                || Self.providerDisplayKey(for: $0, accounts: accounts) == provider.providerID.rawValue
                || $0.provider == provider.rawValue
        }
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
