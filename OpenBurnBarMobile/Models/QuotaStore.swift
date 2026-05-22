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
    private let settingsStore = QuotaSettingsStore()

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

    /// On-demand refresh for a specific provider account. Pro users can
    /// trigger this at any time to get fresh quota numbers regardless of
    /// staleness. The account must be cloud-refreshable or server-private.
    func refreshAccountQuota(accountID: String) async throws -> ProviderQuotaSnapshot {
        let refreshed = try await functions.refreshProviderAccountQuota(accountID: accountID)
        let merged = snapshots
            .filter { $0.accountID != refreshed.accountID || $0.sourceID != refreshed.sourceID }
            + [refreshed]
        applySnapshots(merged)
        return refreshed
    }

    /// On-demand refresh for all accounts of a given provider. Pro users
    /// can trigger this at any time to get fresh quota numbers.
    /// Cloud-refreshable and server-private accounts use the cloud function;
    /// self-hosted local-only accounts (Claude Code, Codex) use the runner.
    func refreshAllAccounts(for providerID: ProviderID) async {
        let eligibleAccounts = accounts.filter {
            $0.providerID == providerID && $0.status != .deleted
        }
        for account in eligibleAccounts {
            do {
                if account.storageScope == .localOnly,
                   account.providerID == .claudeCode || account.providerID == .codex {
                    _ = try await SelfHostedQuotaRunnerStore.shared.refresh(account: account)
                } else if account.storageScope == .cloudRefreshable || account.storageScope == .serverPrivate {
                    _ = try await refreshAccountQuota(accountID: account.id)
                }
            } catch {
                quotaStoreLogger.warning("On-demand refresh failed for \(account.providerID.rawValue, privacy: .public)/\(account.id, privacy: .private): \(error.localizedDescription)")
            }
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
                    self.applySnapshots(Self.snapshotsForApplyingUpdate(
                        current: self.snapshots,
                        incoming: update.snapshots,
                        isFromCache: update.isFromCache
                    ))
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
        Self.displayReadyQuotaSnapshots(snapshots)
    }

    nonisolated static func displayReadyQuotaSnapshots(_ snapshots: [ProviderQuotaSnapshot]) -> [ProviderQuotaSnapshot] {
        let displayable = snapshots.compactMap { $0.filteringToDisplayableQuotaSignal() }
        return dropShadowedProviderLevelSnapshots(
            deduplicateQuotaSnapshotsByProviderAccount(displayable)
        )
    }

    nonisolated static func deduplicateQuotaSnapshotsByProviderAccount(_ snapshots: [ProviderQuotaSnapshot]) -> [ProviderQuotaSnapshot] {
        Dictionary(grouping: snapshots, by: quotaSnapshotDedupKey)
            .values
            .map(mergeQuotaSnapshotGroup)
            .sorted {
                let providerCompare = $0.providerID.rawValue.localizedCaseInsensitiveCompare($1.providerID.rawValue)
                if providerCompare != .orderedSame { return providerCompare == .orderedAscending }
                let lhsAccount = ($0.accountLabel ?? $0.accountID ?? $0.sourceID).lowercased()
                let rhsAccount = ($1.accountLabel ?? $1.accountID ?? $1.sourceID).lowercased()
                return lhsAccount < rhsAccount
            }
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

    nonisolated static func snapshotsForApplyingUpdate(
        current: [ProviderQuotaSnapshot],
        incoming: [ProviderQuotaSnapshot],
        isFromCache: Bool
    ) -> [ProviderQuotaSnapshot] {
        guard isFromCache, !current.isEmpty else { return incoming }
        return current + incoming
    }

    nonisolated private static func visibleProviderIDs(in snapshots: [ProviderQuotaSnapshot]) -> Set<String> {
        Set(snapshots.map(\.providerID.rawValue))
    }

    nonisolated private static func quotaSnapshotDedupKey(_ snapshot: ProviderQuotaSnapshot) -> String {
        let providerKey = snapshot.providerID.rawValue.lowercased()
        let accountKey = snapshot.accountID.nilIfBlank
            ?? snapshot.accountLabel.nilIfBlank?.lowercased()
            ?? "provider-level"
        return "\(providerKey)::\(accountKey)"
    }

    nonisolated private static func mergeQuotaSnapshotGroup(_ snapshots: [ProviderQuotaSnapshot]) -> ProviderQuotaSnapshot {
        let ordered = snapshots.sorted {
            let lhsFreshness = freshnessDate($0)
            let rhsFreshness = freshnessDate($1)
            if lhsFreshness != rhsFreshness { return lhsFreshness > rhsFreshness }
            return $0.id > $1.id
        }
        guard let latest = ordered.first else { return snapshots[0] }
        guard ordered.count > 1 else { return latest }

        var seenBuckets = Set<String>()
        let mergedBuckets = ordered
            .filter { !$0.isExplicitlyStale }
            .flatMap(\.buckets)
            .filter { bucket in
                let key = "\(bucket.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())::\(bucket.window?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")"
                guard !seenBuckets.contains(key) else { return false }
                seenBuckets.insert(key)
                return true
            }

        return ProviderQuotaSnapshot(
            id: ordered.map(\.id).filter { !$0.isEmpty }.uniqued().joined(separator: "+"),
            provider: latest.provider,
            providerID: latest.providerID,
            accountID: latest.accountID ?? ordered.compactMap(\.accountID).firstNonBlank,
            accountLabel: latest.accountLabel ?? ordered.compactMap(\.accountLabel).firstNonBlank,
            accountStorageScope: latest.accountStorageScope ?? ordered.compactMap(\.accountStorageScope).first,
            sourceKind: latest.sourceKind,
            sourceId: ordered.map(\.sourceID).filter { !$0.isEmpty }.uniqued().joined(separator: ", "),
            fetchedAt: latest.fetchedAt,
            source: latest.source,
            confidence: ordered.max(by: { confidenceRank($0.confidence) < confidenceRank($1.confidence) })?.confidence ?? latest.confidence,
            managementURL: latest.managementURL ?? ordered.compactMap(\.managementURL).firstNonBlank,
            statusMessage: latest.statusMessage ?? ordered.compactMap(\.statusMessage).firstNonBlank,
            buckets: mergedBuckets,
            schemaVersion: latest.schemaVersion,
            updatedAt: latest.updatedAt
        )
    }

    nonisolated private static func dropShadowedProviderLevelSnapshots(_ snapshots: [ProviderQuotaSnapshot]) -> [ProviderQuotaSnapshot] {
        let providersWithAccountSnapshots = Set(
            snapshots
                .filter { ($0.accountID.nilIfBlank ?? $0.accountLabel.nilIfBlank) != nil }
                .map(\.providerID.rawValue)
        )
        guard !providersWithAccountSnapshots.isEmpty else { return snapshots }
        return snapshots.filter { snapshot in
            let isProviderLevel = snapshot.accountID.nilIfBlank == nil && snapshot.accountLabel.nilIfBlank == nil
            return !(isProviderLevel && providersWithAccountSnapshots.contains(snapshot.providerID.rawValue))
        }
    }

    nonisolated private static func freshnessDate(_ snapshot: ProviderQuotaSnapshot) -> Date {
        max(snapshot.updatedAt, snapshot.fetchedAt)
    }

    nonisolated private static func confidenceRank(_ confidence: ProviderQuotaConfidence) -> Int {
        switch confidence {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        case .stale: return 0
        }
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
                account.storageScope == .cloudRefreshable
                    || account.storageScope == .serverPrivate
                    || (account.storageScope == .localOnly
                        && (account.providerID == .claudeCode || account.providerID == .codex))
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
                if account.storageScope == .localOnly,
                   account.providerID == .claudeCode || account.providerID == .codex {
                    let refreshed = try await SelfHostedQuotaRunnerStore.shared.refresh(account: account)
                    let merged = snapshots
                        .filter { $0.accountID != refreshed.accountID || $0.sourceID != refreshed.sourceID }
                        + [refreshed]
                    applySnapshots(merged)
                } else {
                    let refreshed = try await functions.refreshProviderAccountQuota(accountID: account.id)
                    let merged = snapshots
                        .filter { $0.accountID != refreshed.accountID || $0.sourceID != refreshed.sourceID }
                        + [refreshed]
                    applySnapshots(merged)
                }
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

        let allKeys = Array(snapshotsByProvider.keys)
        let visibleSet = Set(settingsStore.visibleProviders.map(\.persistedToken))
        let orderedTokens = settingsStore.providerOrder.map(\.persistedToken)

        let filteredKeys = allKeys.filter { visibleSet.contains($0) }
        visibleProviders = filteredKeys.sorted { lhs, rhs in
            let lhsIdx = orderedTokens.firstIndex(of: lhs) ?? Int.max
            let rhsIdx = orderedTokens.firstIndex(of: rhs) ?? Int.max
            if lhsIdx != rhsIdx {
                return lhsIdx < rhsIdx
            }
            return lhs < rhs
        }

        let urgentKeys = snapshotsByProvider
            .filter { _, snaps in snaps.contains(where: { isUrgent($0) }) }
            .keys
            .filter { visibleSet.contains($0) }
        urgentProviders = urgentKeys.sorted { lhs, rhs in
            let lhsIdx = orderedTokens.firstIndex(of: lhs) ?? Int.max
            let rhsIdx = orderedTokens.firstIndex(of: rhs) ?? Int.max
            if lhsIdx != rhsIdx {
                return lhsIdx < rhsIdx
            }
            return pressureScore(for: lhs) < pressureScore(for: rhs)
        }

        let urgentSet = Set(urgentProviders)
        let healthyKeys = snapshotsByProvider.keys
            .filter { visibleSet.contains($0) && !urgentSet.contains($0) }
        healthyProviders = healthyKeys.sorted { lhs, rhs in
            let lhsIdx = orderedTokens.firstIndex(of: lhs) ?? Int.max
            let rhsIdx = orderedTokens.firstIndex(of: rhs) ?? Int.max
            if lhsIdx != rhsIdx {
                return lhsIdx < rhsIdx
            }
            return lhs < rhs
        }

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
        let pressured = snapshot.buckets.compactMap(\.displayRemainingFraction)
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

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

private extension Array where Element == String {
    var firstNonBlank: String? {
        first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
