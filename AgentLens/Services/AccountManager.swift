import AppKit
import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import Foundation
import GoogleSignIn

// MARK: - AccountManager

/// Manages Firebase Authentication and device identity.
/// Supports Sign in with Apple and Google. Device UUID is persisted locally in app defaults
/// and migrated from legacy OpenBurnBar/AgentLens defaults keys when present.
@Observable
@MainActor
final class AccountManager {

    static let shared = AccountManager()

    // MARK: - State

    private(set) var isSignedIn = false
    private(set) var userID: String?
    private(set) var userEmail: String?
    private(set) var userDisplayName: String?
    private(set) var isCloudSyncEnabled = true
    private(set) var isFirebaseAvailable = false

    /// Stable device identifier stored in Keychain.
    let deviceId: String

    // MARK: - Private

    private var authStateListenerHandle: AuthStateDidChangeListenerHandle?
    private var currentNonce: String?
    /// Retains `AppleSignInPresentationCoordinator` until Sign in with Apple completes.
    private var appleSignInPresentation: AppleSignInPresentationCoordinator?

    /// Avoids calling `FirebaseApp.app()` when no default app exists, which can emit noisy logs.
    private static var hasConfiguredFirebaseApp: Bool {
        !(FirebaseApp.allApps ?? [:]).isEmpty
    }

    // MARK: - Init

    private init() {
        deviceId = Self.loadOrCreateDeviceId()
        configureFirebase()
    }

    // MARK: - Firebase Setup

    private func configureFirebase() {
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil,
              Self.hasConfiguredFirebaseApp else {
            return
        }
        isFirebaseAvailable = true
        configureGoogleSignInIfPossible()
        observeAuthState()
    }

    func onFirebaseConfigured() {
        isFirebaseAvailable = true
        configureGoogleSignInIfPossible()
        observeAuthState()
    }

    private func configureGoogleSignInIfPossible() {
        guard Self.hasConfiguredFirebaseApp else { return }
        guard let clientID = FirebaseApp.app()?.options.clientID else { return }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    }

    private func observeAuthState() {
        guard authStateListenerHandle == nil else { return }
        authStateListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                self?.isSignedIn = user != nil
                self?.userID = user?.uid
                self?.userEmail = user?.email
                self?.userDisplayName = user?.displayName ?? user?.email
            }
        }
    }

    // MARK: - Sign In with Apple

    /// Call from `SignInWithAppleButton` request closure — returns SHA256(nonce) for the Apple request.
    func appleSignInNonceHash() -> String {
        let nonce = randomNonceString()
        currentNonce = nonce
        return sha256(nonce)
    }

    func signInWithAppleAuthorization(_ authorization: ASAuthorization) async throws {
        guard isFirebaseAvailable else {
            throw AccountError.firebaseNotConfigured
        }
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let appleIDToken = appleIDCredential.identityToken,
              let idTokenString = String(data: appleIDToken, encoding: .utf8),
              let rawNonce = currentNonce else {
            throw AccountError.invalidCredential
        }

        let credential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: rawNonce,
            fullName: appleIDCredential.fullName
        )
        try await Auth.auth().signIn(with: credential)
    }

    /// Presents Sign in with Apple from a window (Settings sheet, etc.).
    func signInWithApple(presentingWindow window: NSWindow) async throws {
        guard isFirebaseAvailable else {
            throw AccountError.firebaseNotConfigured
        }
        let nonceHash = appleSignInNonceHash()
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let request = appleIDProvider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonceHash

        let controller = ASAuthorizationController(authorizationRequests: [request])

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let coordinator = AppleSignInPresentationCoordinator(
                accountManager: self,
                window: window,
                controller: controller,
                continuation: continuation,
                onFinish: { [weak self] in
                    self?.appleSignInPresentation = nil
                }
            )
            appleSignInPresentation = coordinator
            coordinator.start()
        }
    }

    // MARK: - Sign In with Google

    func signInWithGoogle(presentingWindow window: NSWindow) async throws {
        guard isFirebaseAvailable else {
            throw AccountError.firebaseNotConfigured
        }
        guard Self.hasConfiguredFirebaseApp,
              let clientID = FirebaseApp.app()?.options.clientID else {
            throw AccountError.firebaseNotConfigured
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            GIDSignIn.sharedInstance.signIn(withPresenting: window) { signInResult, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let signInResult,
                      let idToken = signInResult.user.idToken?.tokenString else {
                    continuation.resume(throwing: AccountError.invalidCredential)
                    return
                }
                let accessToken = signInResult.user.accessToken.tokenString
                Task { @MainActor in
                    do {
                        let credential = GoogleAuthProvider.credential(
                            withIDToken: idToken,
                            accessToken: accessToken
                        )
                        try await Auth.auth().signIn(with: credential)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Sign Out

    func signOut() throws {
        if isFirebaseAvailable {
            try Auth.auth().signOut()
        }
        GIDSignIn.sharedInstance.signOut()
    }

    // MARK: - Cloud Sync Toggle

    func setCloudSyncEnabled(_ enabled: Bool) {
        isCloudSyncEnabled = enabled
    }

    // MARK: - Device UUID

    private static func loadOrCreateDeviceId() -> String {
        OpenBurnBarMigration.migrateUserDefaults()
        let key = OpenBurnBarIdentity.deviceIDKey
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        }
        for legacyKey in OpenBurnBarIdentity.legacyDeviceIDKeys {
            if let stored = UserDefaults.standard.string(forKey: legacyKey) {
                UserDefaults.standard.set(stored, forKey: key)
                return stored
            }
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    // MARK: - Nonce Helpers

    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        precondition(errorCode == errSecSuccess, "SecRandomCopyBytes failed")
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - AccountError

enum AccountError: LocalizedError {
    case firebaseNotConfigured
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .firebaseNotConfigured:
            return "Firebase is not configured. Add GoogleService-Info.plist to the app bundle."
        case .invalidCredential:
            return "Sign in failed: invalid credential received from the provider."
        }
    }
}

// MARK: - Sign in with Apple (presentation)

private final class AppleSignInPresentationCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let accountManager: AccountManager
    private weak var window: NSWindow?
    private let controller: ASAuthorizationController
    private var continuation: CheckedContinuation<Void, Error>?
    private let onFinish: () -> Void

    init(
        accountManager: AccountManager,
        window: NSWindow,
        controller: ASAuthorizationController,
        continuation: CheckedContinuation<Void, Error>,
        onFinish: @escaping () -> Void
    ) {
        self.accountManager = accountManager
        self.window = window
        self.controller = controller
        self.continuation = continuation
        self.onFinish = onFinish
        super.init()
        controller.delegate = self
        controller.presentationContextProvider = self
    }

    func start() {
        controller.performRequests()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        window ?? NSApp.keyWindow ?? NSWindow()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let cont = continuation
        continuation = nil
        Task {
            do {
                try await accountManager.signInWithAppleAuthorization(authorization)
                cont?.resume()
                onFinish()
            } catch {
                cont?.resume(throwing: error)
                onFinish()
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let cont = continuation
        continuation = nil
        cont?.resume(throwing: error)
        onFinish()
    }
}
