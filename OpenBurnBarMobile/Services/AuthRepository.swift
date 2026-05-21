import Foundation
@preconcurrency import FirebaseAuth
import FirebaseCore
import FirebaseFunctions

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

    func deleteCurrentUser() async throws {
        guard let auth else {
            throw CloudGatewayError.classified(.firebaseUnavailable)
        }
        guard auth.currentUser != nil else {
            throw CloudGatewayError.classified(.notAuthenticated)
        }
        let callable = Functions.functions(region: "us-central1").httpsCallable("deleteUserCloudData")
        _ = try await callable.call([String: Any]())
        try? auth.signOut()
    }

    @discardableResult
    func addStateDidChangeListener(
        _ callback: @escaping @MainActor (User?) -> Void
    ) -> AuthStateDidChangeListenerHandle? {
        guard let auth else { return nil }
        return auth.addStateDidChangeListener { _, user in
            // FirebaseAuth invokes auth-state listeners on the main queue; keep
            // the non-Sendable `User` on the main actor instead of hopping it
            // through a Sendable task closure.
            MainActor.assumeIsolated {
                callback(user)
            }
        }
    }

    /// Convenience wrapper that subscribes to auth state changes for an
    /// `@Observable` store. Returns the underlying handle so callers can
    /// detach if they ever need to.
    @discardableResult
    func observeAuthChanges(
        _ callback: @escaping @MainActor (User?) -> Void
    ) -> AuthStateDidChangeListenerHandle? {
        addStateDidChangeListener(callback)
    }
}
