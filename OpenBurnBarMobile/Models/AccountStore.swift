import Foundation
import OpenBurnBarCore
@preconcurrency import FirebaseAuth

@Observable
@MainActor
final class AccountStore {
    /// Process-wide shared instance for views that need a read-only
    /// snapshot of the user's connected providers without owning the
    /// store's lifecycle (notably the assistant model picker, which only
    /// needs `connectedProviderIDs`). Long-lived views (Account, You)
    /// still construct their own instance so they get their own loading
    /// state.
    static let shared = AccountStore()

    private let authRepo: AuthRepository
    private let firestore: FirestoreRepository
    private let profileDefaults: UserDefaults
    private let controllerRouteLifecycle: any IrohControllerRouteAuthLifecycleManaging

    private(set) var user: User?
    private(set) var isSignedIn = false
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var connections: [ProviderConnectionDoc] = []
    private(set) var providerAccounts: [ProviderAccountDoc] = []
    private(set) var syncHealth: SyncHealth = .unknown

    /// Providers the user has actually connected and that can route a
    /// request right now. Includes `.stale` because a recently-expired
    /// token is still routable until the next validation cycle — dropping
    /// it would flicker the picker's reachability set away.
    var connectedProviderIDs: Set<ProviderID> {
        Set(providerAccounts
            .filter { $0.status == .connected || $0.status == .stale }
            .map(\.providerID))
    }

    // MARK: - Multi-profile support (iPad Settings)
    private(set) var profiles: [BurnBarProfile] = []
    private(set) var activeProfile: BurnBarProfile?

    init(
        authRepo: AuthRepository = AuthRepository(),
        firestore: FirestoreRepository = FirestoreRepository(),
        profileDefaults: UserDefaults = .standard,
        controllerRouteLifecycle: any IrohControllerRouteAuthLifecycleManaging = IrohControllerRouteAuthLifecycleCoordinator.shared
    ) {
        self.authRepo = authRepo
        self.firestore = firestore
        self.profileDefaults = profileDefaults
        self.controllerRouteLifecycle = controllerRouteLifecycle
        self.isSignedIn = authRepo.isSignedIn
        self.user = authRepo.currentUser

        authRepo.observeAuthChanges { [weak self] user in
            self?.user = user
            self?.isSignedIn = user != nil
            if user != nil {
                Task { @MainActor [weak self] in
                    await self?.loadConnections()
                }
            } else {
                self?.resetSessionState()
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
            refreshProfilesFromLoadedAccounts()
            syncHealth = .healthy
        } catch {
            self.error = error.localizedDescription
            syncHealth = .error
        }
    }

    func signOut() async {
        await controllerRouteLifecycle.tearDownAndRevoke()
        do {
            try authRepo.signOut()
            resetSessionState()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func resetSessionState() {
        connections = []
        providerAccounts = []
        profiles = []
        activeProfile = nil
        syncHealth = .unknown
    }

    // MARK: - Profile Management

    func loadProfiles() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            providerAccounts = try await firestore.fetchProviderAccounts()
            refreshProfilesFromLoadedAccounts()
            syncHealth = .healthy
        } catch {
            self.error = error.localizedDescription
            syncHealth = .error
            refreshProfilesFromLoadedAccounts()
        }
    }

    func switchTo(_ profile: BurnBarProfile) async {
        if profiles.contains(where: { $0.id == profile.id }) == false {
            await loadProfiles()
        }
        guard profiles.contains(where: { $0.id == profile.id }) else { return }
        profileDefaults.set(profile.id, forKey: activeProfileDefaultsKey())
        profiles = profiles.map {
            var p = $0
            p.isActive = (p.id == profile.id)
            return p
        }
        activeProfile = profiles.first { $0.id == profile.id }
    }

    private func refreshProfilesFromLoadedAccounts() {
        profiles = Self.deriveProfiles(
            currentProfile: currentFirebaseProfile(),
            providerAccounts: providerAccounts,
            activeProfileID: profileDefaults.string(forKey: activeProfileDefaultsKey())
        )
        activeProfile = profiles.first { $0.isActive }
    }

    private func currentFirebaseProfile() -> BurnBarProfile? {
        guard let user = authRepo.currentUser else { return nil }
        return BurnBarProfile(
            id: user.uid,
            displayName: user.displayName ?? user.email ?? "Current Account",
            email: user.email,
            photoURL: user.photoURL,
            isActive: false
        )
    }

    private func activeProfileDefaultsKey() -> String {
        let uid = authRepo.currentUser?.uid ?? "anonymous"
        return "OpenBurnBarMobile.AccountStore.activeProfile.\(uid)"
    }

    nonisolated static func deriveProfiles(
        currentProfile: BurnBarProfile?,
        providerAccounts: [ProviderAccountDoc],
        activeProfileID: String?
    ) -> [BurnBarProfile] {
        var loaded: [BurnBarProfile] = []
        var seen = Set<String>()

        if let currentProfile {
            loaded.append(currentProfile)
            _ = seen.insert(currentProfile.id)
        }

        let accounts = providerAccounts
            .filter { $0.status != .deleted }
            .sorted { lhs, rhs in
                if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
                if lhs.providerID.rawValue != rhs.providerID.rawValue {
                    return lhs.providerID.rawValue < rhs.providerID.rawValue
                }
                return lhs.id < rhs.id
            }

        for account in accounts {
            let profileID = Self.profileID(for: account)
            guard seen.insert(profileID).inserted else { continue }
            loaded.append(BurnBarProfile(
                id: profileID,
                displayName: Self.profileDisplayName(for: account),
                email: Self.emailLikeIdentityHint(account.identityHint),
                photoURL: nil,
                isActive: false
            ))
        }

        let resolvedActiveID: String? = {
            if let activeProfileID, loaded.contains(where: { $0.id == activeProfileID }) {
                return activeProfileID
            }
            return currentProfile?.id ?? loaded.first?.id
        }()

        return loaded.map { profile in
            var copy = profile
            copy.isActive = profile.id == resolvedActiveID
            return copy
        }
    }

    private nonisolated static func profileID(for account: ProviderAccountDoc) -> String {
        if let linked = nonEmpty(account.linkedSwitcherProfileID) {
            return "switcher:\(linked)"
        }
        return "provider-account:\(account.id)"
    }

    private nonisolated static func profileDisplayName(for account: ProviderAccountDoc) -> String {
        if let label = nonEmpty(account.label) {
            return label
        }
        return AgentProvider.fromProviderID(account.providerID)?.displayName ?? account.providerID.rawValue
    }

    private nonisolated static func emailLikeIdentityHint(_ value: String?) -> String? {
        guard let value = nonEmpty(value), value.contains("@") else { return nil }
        return value
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
