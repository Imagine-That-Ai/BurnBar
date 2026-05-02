import Foundation
import OpenBurnBarCore
import FirebaseAuth

@Observable
@MainActor
final class AccountStore {
    private let authRepo: AuthRepository
    private let firestore: FirestoreRepository

    private(set) var user: User?
    private(set) var isSignedIn = false
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var connections: [ProviderConnectionDoc] = []
    private(set) var syncHealth: SyncHealth = .unknown

    init(
        authRepo: AuthRepository = AuthRepository(),
        firestore: FirestoreRepository = FirestoreRepository()
    ) {
        self.authRepo = authRepo
        self.firestore = firestore
        self.isSignedIn = authRepo.isSignedIn
        self.user = authRepo.currentUser

        authRepo.observeAuthChanges { [weak self] user in
            Task { @MainActor in
                self?.user = user
                self?.isSignedIn = user != nil
                if user != nil {
                    await self?.loadConnections()
                }
            }
        }
    }

    func loadConnections() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            connections = try await firestore.fetchProviderConnections()
            syncHealth = .healthy
        } catch {
            self.error = error.localizedDescription
            syncHealth = .error
        }
    }

    func signOut() {
        do {
            try authRepo.signOut()
            connections = []
            syncHealth = .unknown
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum SyncHealth: String, Sendable {
    case unknown, healthy, syncing, error, offline

    var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .healthy: return "Healthy"
        case .syncing: return "Syncing"
        case .error: return "Error"
        case .offline: return "Offline"
        }
    }
}
