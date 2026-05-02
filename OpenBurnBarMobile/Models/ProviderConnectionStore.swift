import Foundation
import OpenBurnBarCore

@Observable
@MainActor
final class ProviderConnectionStore {
    private let functions: FunctionsRepository
    private let firestore: FirestoreRepository

    private(set) var connectingProvider: String?
    private(set) var deletingProvider: String?
    private(set) var refreshingProvider: String?
    private(set) var error: String?
    private(set) var connections: [ProviderConnectionDoc] = []
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
            connections = try await firestore.fetchProviderConnections()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func connect(provider: String, credential: String, kind: CredentialKind) async {
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

    func delete(provider: String) async {
        deletingProvider = provider
        error = nil
        defer { deletingProvider = nil }

        do {
            try await functions.deleteProviderCredential(provider: provider)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refresh(provider: String) async {
        refreshingProvider = provider
        error = nil
        defer { refreshingProvider = nil }

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
}
