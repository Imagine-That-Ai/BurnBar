import Foundation
import FirebaseAuth

// MARK: - Auth Repository

@MainActor
final class AuthRepository {
    static let shared = AuthRepository()

    private let auth = Auth.auth()

    var currentUser: User? { auth.currentUser }

    var isSignedIn: Bool { auth.currentUser != nil }

    func signInAnonymously() async throws -> User {
        let result = try await auth.signInAnonymously()
        return result.user
    }

    func signOut() throws {
        try auth.signOut()
    }

    func addStateDidChangeListener(
        _ callback: @escaping @Sendable (User?) -> Void
    ) -> AuthStateDidChangeListenerHandle {
        auth.addStateDidChangeListener { _, user in
            callback(user)
        }
    }

    /// Convenience wrapper that subscribes to auth state changes for an
    /// `@Observable` store. Returns the underlying handle so callers can
    /// detach if they ever need to.
    @discardableResult
    func observeAuthChanges(
        _ callback: @escaping @Sendable (User?) -> Void
    ) -> AuthStateDidChangeListenerHandle {
        addStateDidChangeListener(callback)
    }
}
