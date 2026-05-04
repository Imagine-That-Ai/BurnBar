import Foundation
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
    private(set) var isLoading = false

    init(
        functions: FunctionsRepository = FunctionsRepository(),
        firestore: FirestoreRepository = FirestoreRepository()
    ) {
        self.functions = functions
        self.firestore = firestore
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            async let accountsTask = firestore.fetchProviderAccounts()
            async let connectionsTask = firestore.fetchProviderConnections()
            async let snapshotsTask = firestore.fetchQuotaSnapshots()
            accounts = try await accountsTask
            connections = try await connectionsTask
            // Quota snapshots are best-effort — they only enrich the routing
            // cockpit and account row hints. Failing here must not break the
            // connections list.
            quotaSnapshots = (try? await snapshotsTask) ?? quotaSnapshots
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

    func connectSelfHosted(providerID: ProviderID, label: String?) async -> ProviderAccountDoc? {
        connectingProvider = providerID.rawValue
        error = nil
        defer { connectingProvider = nil }

        do {
            let doc = try await functions.connectProviderAccount(
                providerID: providerID,
                credential: "",
                kind: .token,
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
            _ = try await functions.refreshProviderAccountQuota(accountID: account.id)
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

    var accountsByProvider: [(providerID: ProviderID, accounts: [ProviderAccountDoc])] {
        Dictionary(grouping: accounts, by: \.providerID)
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
