import AppKit
import AuthenticationServices
import Foundation

// MARK: - AccountManagerProtocol

/// Protocol defining the account management interface.
/// This enables dependency injection and testing of account-related functionality.
///
/// ## Usage
/// ```swift
/// struct MyView {
///     @Bindable var accountManager: any AccountManagerProtocol
/// }
/// ```
///
/// For production use, `AccountManager.shared` conforms to this protocol.
/// For testing, inject a mock implementation.
@MainActor
protocol AccountManagerProtocol: AnyObject {

    // MARK: - State (read-only properties)

    /// Whether the user is currently signed in.
    var isSignedIn: Bool { get }

    /// The Firebase user ID, if signed in.
    var userID: String? { get }

    /// The user's email address, if available.
    var userEmail: String? { get }

    /// The user's display name or email, if available.
    var userDisplayName: String? { get }

    /// Whether cloud sync is enabled by the user.
    var isCloudSyncEnabled: Bool { get }

    /// Whether Firebase is available/configured.
    var isFirebaseAvailable: Bool { get }

    /// Stable device identifier persisted in Keychain.
    var deviceId: String { get }

    // MARK: - Authentication Methods

    /// Initiates Sign in with Apple flow.
    /// - Parameter window: The window to present the sign-in sheet on.
    func signInWithApple(presentingWindow window: NSWindow) async throws

    /// Initiates Sign in with Google flow.
    /// - Parameter window: The window to present the sign-in sheet on.
    func signInWithGoogle(presentingWindow window: NSWindow) async throws

    /// Signs in with an existing email/password account.
    func signInWithEmail(email: String, password: String) async throws

    /// Creates a new email/password account, or upgrades the current anonymous account.
    func signUpWithEmail(email: String, password: String) async throws

    /// Signs out the current user.
    func signOut() throws

    /// Enables or disables cloud sync.
    /// - Parameter enabled: Whether to enable cloud sync.
    func setCloudSyncEnabled(_ enabled: Bool)

    /// Called when Firebase configuration completes (e.g., after async Firebase setup).
    func onFirebaseConfigured()
}

// MARK: - AccountManager Extension

extension AccountManager: AccountManagerProtocol {}
