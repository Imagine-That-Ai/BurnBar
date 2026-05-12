import Foundation
import FirebaseFirestore
import OpenBurnBarCore

@Observable
@MainActor
final class ProviderConnectionStore {
    private let functions: FunctionsRepository
    private let firestore: FirestoreRepository

    private(set) var connectingProvider: String?
    private(set) var deletingAccountID: String?
    private(set) var refreshingAccountID: String?
    private(set) var error: String?
    private(set) var accounts: [ProviderAccountDoc] = []
    private(set) var connections: [ProviderConnectionDoc] = []
    private(set) var quotaSnapshots: [ProviderQuotaSnapshot] = []
    private(set) var deviceLinksByAccount: [String: [FirestoreRepository.ProviderAccountDeviceLinkProjection]] = [:]
    private(set) var isLoading = false
    private(set) var accountsByProvider: [(providerID: ProviderID, accounts: [ProviderAccountDoc])] = []

    // Firestore's `ListenerRegistration` is thread-safe and cleanup must run
    // from `deinit` (a nonisolated context). Marking the property
    // `nonisolated(unsafe)` lets the actor-isolated store hold it while still
    // allowing `deinit` to call `remove()`.
    private nonisolated(unsafe) var deviceLinksListener: ListenerRegistration?

    init(
        functions: FunctionsRepository = FunctionsRepository(),
        firestore: FirestoreRepository = FirestoreRepository()
    ) {
        self.functions = functions
        self.firestore = firestore
    }

    deinit {
        deviceLinksListener?.remove()
    }

    /// Begin streaming device-link adoption state. Idempotent — repeated calls
    /// re-use the existing snapshot listener.
    func startDeviceLinksStream() {
        guard deviceLinksListener == nil else { return }
        deviceLinksListener = firestore.listenProviderAccountDeviceLinks { [weak self] projections in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.deviceLinksByAccount = Dictionary(grouping: projections, by: \.accountID)
            }
        }
    }

    func stopDeviceLinksStream() {
        deviceLinksListener?.remove()
        deviceLinksListener = nil
        deviceLinksByAccount.removeAll()
    }

    func deviceLinks(for accountID: String) -> [FirestoreRepository.ProviderAccountDeviceLinkProjection] {
        deviceLinksByAccount[accountID] ?? []
    }

    func load() async {
        if AppStoreScreenshotMode.isEnabled {
            isLoading = false
            error = nil
            applyAccounts(AppStoreScreenshotData.providerAccounts)
            connections = AppStoreScreenshotData.providerConnections
            quotaSnapshots = normalizeQuotaSnapshots(AppStoreScreenshotData.quotaSnapshots)
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            async let accountsTask = firestore.fetchProviderAccounts()
            async let connectionsTask = firestore.fetchProviderConnections()
            async let snapshotsTask = firestore.fetchQuotaSnapshots()
            applyAccounts(try await accountsTask)
            connections = try await connectionsTask
            // Quota snapshots are best-effort — they only enrich the routing
            // cockpit and account row hints. Failing here must not break the
            // connections list.
            quotaSnapshots = (try? await snapshotsTask).map(normalizeQuotaSnapshots) ?? quotaSnapshots
        } catch {
            self.error = error.localizedDescription
        }
    }

    func routingState(for providerID: ProviderID) -> ProviderRoutingStateSnapshot? {
        ProviderRoutingStateBuilder.build(
            providerID: providerID,
            accounts: accounts,
            snapshots: quotaSnapshots
        )
    }

    private func normalizeQuotaSnapshots(_ snapshots: [ProviderQuotaSnapshot]) -> [ProviderQuotaSnapshot] {
        snapshots.compactMap { $0.filteringToDisplayableQuotaSignal() }
    }

    func connect(providerID: ProviderID, credential: String, kind: CredentialKind, label: String?) async -> ProviderAccountDoc? {
        connectingProvider = providerID.rawValue
        error = nil
        defer { connectingProvider = nil }

        do {
            let doc = try await functions.connectProviderAccount(
                providerID: providerID,
                credential: credential,
                kind: kind,
                label: label
            )
            await load()
            return doc
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func connectLegacy(provider: String, credential: String, kind: CredentialKind) async {
        connectingProvider = provider
        error = nil
        defer { connectingProvider = nil }

        do {
            _ = try await functions.connectProviderCredential(
                provider: provider,
                credential: credential,
                kind: kind
            )
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func connectHosted(providerID: ProviderID, credential: String, kind: CredentialKind, label: String?) async -> ProviderAccountDoc? {
        connectingProvider = providerID.rawValue
        error = nil
        defer { connectingProvider = nil }

        do {
            let doc = try await functions.connectHostedQuotaAccount(
                providerID: providerID,
                credential: credential,
                label: label
            )
            await load()
            return doc
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func connectSelfHosted(providerID: ProviderID, label: String?) async -> ProviderAccountDoc? {
        connectingProvider = providerID.rawValue
        error = nil
        defer { connectingProvider = nil }

        do {
            let doc = try await functions.connectSelfHostedQuotaAccount(
                providerID: providerID,
                label: label
            )
            await load()
            return doc
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func delete(account: ProviderAccountDoc) async {
        deletingAccountID = account.id
        error = nil
        defer { deletingAccountID = nil }

        do {
            try await functions.deleteProviderAccount(accountID: account.id)
            if account.storageScope == .localOnly,
               account.providerID == .claudeCode || account.providerID == .codex {
                // Clean up locally-stored runner config when deleting a self-hosted account.
                SelfHostedQuotaRunnerStore.shared.delete(accountID: account.id)
            }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteLegacy(provider: String) async {
        deletingAccountID = provider
        error = nil
        defer { deletingAccountID = nil }

        do {
            try await functions.deleteProviderCredential(provider: provider)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refresh(account: ProviderAccountDoc) async {
        refreshingAccountID = account.id
        error = nil
        defer { refreshingAccountID = nil }

        do {
            if account.storageScope == .localOnly,
               account.providerID == .claudeCode || account.providerID == .codex {
                _ = try await SelfHostedQuotaRunnerStore.shared.refresh(account: account)
            } else {
                _ = try await functions.refreshProviderAccountQuota(accountID: account.id)
            }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshLegacy(provider: String) async {
        refreshingAccountID = provider
        error = nil
        defer { refreshingAccountID = nil }

        do {
            _ = try await functions.refreshProviderQuota(provider: provider)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func rebuildRollups() async {
        error = nil
        do {
            try await functions.rebuildUsageRollups()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func applyAccounts(_ newAccounts: [ProviderAccountDoc]) {
        accounts = newAccounts
        accountsByProvider = Dictionary(grouping: newAccounts, by: \.providerID)
            .map { providerID, accounts in
                (
                    providerID,
                    accounts.sorted {
                        if $0.isDefault != $1.isDefault { return $0.isDefault && !$1.isDefault }
                        if $0.sortKey != $1.sortKey { return $0.sortKey < $1.sortKey }
                        return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
                    }
                )
            }
            .sorted { lhs, rhs in providerDisplayName(lhs.providerID) < providerDisplayName(rhs.providerID) }
    }

    func providerDisplayName(_ providerID: ProviderID) -> String {
        AgentProvider.fromProviderID(providerID)?.displayName ?? providerID.rawValue
    }
}
