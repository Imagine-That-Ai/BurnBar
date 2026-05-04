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
    private(set) var providerAccounts: [ProviderAccountDoc] = []
    private(set) var syncHealth: SyncHealth = .unknown

    // MARK: - Multi-profile support (iPad Settings)
    private(set) var profiles: [BurnBarProfile] = []
    private(set) var activeProfile: BurnBarProfile?

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
        await fetchConnections()
    }

    func fetchConnections() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            async let connectionsTask = firestore.fetchProviderConnections()
            async let accountsTask = firestore.fetchProviderAccounts()
            connections = try await connectionsTask
            providerAccounts = try await accountsTask
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
            providerAccounts = []
            syncHealth = .unknown
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Profile Management

    func loadProfiles() async {
        isLoading = true
        defer { isLoading = false }

        // For now, derive profiles from the current Firebase user + any
        // cached switcher profiles stored in UserDefaults.
        // Full multi-account support requires deeper integration with
        // the macOS switcher system.
        var loaded: [BurnBarProfile] = []
        if let user = authRepo.currentUser {
            loaded.append(BurnBarProfile(
                id: user.uid,
                displayName: user.displayName ?? user.email ?? "Current Account",
                email: user.email,
                photoURL: user.photoURL,
                isActive: true
            ))
        }
        profiles = loaded
        activeProfile = loaded.first { $0.isActive }
    }

    func switchTo(_ profile: BurnBarProfile) async {
        // In the full implementation this would swap Firebase auth contexts.
        // For now we just update the active marker.
        profiles = profiles.map {
            var p = $0
            p.isActive = (p.id == profile.id)
            return p
        }
        activeProfile = profile
    }
}

enum SyncHealth: String, Sendable {
    case unknown, healthy, stale, error

    var label: String {
        displayText
    }

    /// Human-readable label that views can render alongside the status icon.
    var displayText: String {
        switch self {
        case .unknown: return "Sync status unknown"
        case .healthy: return "Cloud sync healthy"
        case .stale:   return "Sync data is stale"
        case .error:   return "Sync error"
        }
    }
}

// MARK: - BurnBar Profile

struct BurnBarProfile: Identifiable, Equatable, Sendable {
    let id: String
    var displayName: String
    var email: String?
    var photoURL: URL?
    var isActive: Bool

    static func == (lhs: BurnBarProfile, rhs: BurnBarProfile) -> Bool {
        lhs.id == rhs.id
    }
}
