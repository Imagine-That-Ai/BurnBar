import Foundation
import OpenBurnBarCore

@Observable
@MainActor
final class ProviderConnectionStore {
    private let functions: FunctionsRepository

    private(set) var connectingProvider: String?
    private(set) var deletingProvider: String?
    private(set) var refreshingProvider: String?
    private(set) var error: String?

    init(functions: FunctionsRepository = FunctionsRepository()) {
        self.functions = functions
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
