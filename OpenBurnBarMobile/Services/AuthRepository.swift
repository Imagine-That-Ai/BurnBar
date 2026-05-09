import Foundation
import FirebaseAuth
import FirebaseCore

// MARK: - Auth Repository

@MainActor
final class AuthRepository {
    static let shared = AuthRepository()

    private var auth: Auth? {
        guard FirebaseApp.app() != nil else { return nil }
        return Auth.auth()
    }

    var isFirebaseAvailable: Bool { FirebaseApp.app() != nil }

    var currentUser: User? { auth?.currentUser }

    var isSignedIn: Bool { auth?.currentUser != nil }

    func signInAnonymously() async throws -> User {
        guard let auth else { throw CloudGatewayError.classified(.firebaseUnavailable) }
        let result = try await auth.signInAnonymously()
        return result.user
    }

    func signOut() throws {
        guard let auth else { return }
        try auth.signOut()
    }

    @discardableResult
    func addStateDidChangeListener(
        _ callback: @escaping @Sendable (User?) -> Void
    ) -> AuthStateDidChangeListenerHandle? {
        guard let auth else { return nil }
        return auth.addStateDidChangeListener { _, user in
            callback(user)
        }
    }

    /// Convenience wrapper that subscribes to auth state changes for an
    /// `@Observable` store. Returns the underlying handle so callers can
    /// detach if they ever need to.
    @discardableResult
    func observeAuthChanges(
        _ callback: @escaping @Sendable (User?) -> Void
    ) -> AuthStateDidChangeListenerHandle? {
        addStateDidChangeListener(callback)
    }
}
