import AuthenticationServices
import CryptoKit
import Foundation
import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import OSLog
import UIKit

/// Production AuthGateway with real Sign in with Apple and Google flows.
@MainActor
final class LiveAuthGateway: NSObject, AuthGateway {
    private let authRepo: AuthRepository
    private var observer: ((MobileAuthIdentity?) -> Void)?
    private var currentNonce: String?

    init(authRepo: AuthRepository = AuthRepository()) {
        self.authRepo = authRepo
        super.init()
        if authRepo.isFirebaseAvailable {
            authRepo.observeAuthChanges { [weak self] (user: User?) in
                Task { @MainActor in self?.observer?(Self.identity(from: user)) }
            }
        }
    }

    var availableProviders: [MobileAuthProviderID] {
        var p: [MobileAuthProviderID] = [.apple]
        if isFirebaseAvailable { p.append(.google) }
        return p
    }

    var isFirebaseAvailable: Bool { authRepo.isFirebaseAvailable }
    var currentIdentity: MobileAuthIdentity? { Self.identity(from: authRepo.currentUser) }

    func observe(onChange: @escaping @MainActor (MobileAuthIdentity?) -> Void) {
        observer = onChange; onChange(currentIdentity)
    }

    func signIn(provider: MobileAuthProviderID) async throws {
        switch provider {
        case .email: throw CloudGatewayError.classified(.other(message: "Use email sign-in from the email form."))
        case .apple: try await signInWithApple()
        case .google: try await signInWithGoogle()
        }
    }

    func signOut() throws {
        try authRepo.signOut()
        GIDSignIn.sharedInstance.signOut()
    }

    func deleteAccount() async throws {
        try validateFirebaseBundle()
        try await authRepo.deleteCurrentUser()
        GIDSignIn.sharedInstance.signOut()
    }

    // MARK: - Apple

    private func signInWithApple() async throws {
        try validateFirebaseBundle()
        let nonce = randomNonceString(); currentNonce = nonce
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        return try await withCheckedThrowingContinuation { cont in
            let d = AppleDelegate(nonce: nonce) { result in
                cont.resume(with: result)
            }
            controller.delegate = d; controller.presentationContextProvider = d
            objc_setAssociatedObject(controller, "d", d, .OBJC_ASSOCIATION_RETAIN)
            controller.performRequests()
        }
    }

    // MARK: - Google

    private func signInWithGoogle() async throws {
        try validateFirebaseBundle()
        guard let clientID = googleClientID else {
            throw CloudGatewayError.classified(.other(message: "Google sign-in is missing its iOS client ID."))
        }
        guard let root = rootVC else {
            throw CloudGatewayError.classified(.firebaseUnavailable)
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        return try await withCheckedThrowingContinuation { cont in
            GIDSignIn.sharedInstance.signIn(withPresenting: root) { result, error in
                if let error {
                    let nsError = error as NSError
                    // GIDSignInError.canceled = -5: user dismissed the sheet
                    if nsError.code == -5 {
                        cont.resume(throwing: CloudGatewayError.classified(.other(message: "Sign-in was cancelled.")))
                    } else {
                        cont.resume(throwing: CloudGatewayError.classified(.other(message: error.localizedDescription)))
                    }
                    return
                }
                guard let r = result, let id = r.user.idToken?.tokenString else {
                    cont.resume(throwing: CloudGatewayError.classified(.other(message: "Google sign-in returned no token.")))
                    return
                }
                let c = GoogleAuthProvider.credential(withIDToken: id, accessToken: r.user.accessToken.tokenString)
                Task { @MainActor in
                    do { try await self.auth(c); cont.resume() }
                    catch { cont.resume(throwing: CloudGatewayError.classified(.other(message: error.localizedDescription))) }
                }
            }
        }
    }

    // MARK: - Email

    func createEmailAccount(email: String, password: String) async throws {
        try validateFirebaseBundle()
        try validateEmailCredentials(email: email, password: password)
        try await Auth.auth().createUser(withEmail: email.trimmedEmail, password: password)
    }

    func signInWithEmail(email: String, password: String) async throws {
        try validateFirebaseBundle()
        try validateEmailCredentials(email: email, password: password)
        try await Auth.auth().signIn(withEmail: email.trimmedEmail, password: password)
    }

    private func auth(_ cred: AuthCredential) async throws {
        if let u = Auth.auth().currentUser, u.isAnonymous { try await u.link(with: cred); return }
        try await Auth.auth().signIn(with: cred)
    }

    private var rootVC: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return activeScene?.windows.first { $0.isKeyWindow }?.rootViewController
            ?? activeScene?.windows.first?.rootViewController
    }

    private var googleClientID: String? {
        FirebaseApp.app()?.options.clientID
            ?? firebasePlistValue("CLIENT_ID")
    }

    private func firebasePlistValue(_ key: String) -> String? {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let values = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return nil
        }
        return values[key] as? String
    }

    private func validateFirebaseBundle() throws {
        guard let options = FirebaseApp.app()?.options else {
            throw CloudGatewayError.classified(.firebaseUnavailable)
        }
        guard let runtimeBundleID = Bundle.main.bundleIdentifier,
              options.bundleID != runtimeBundleID else {
            return
        }
        throw CloudGatewayError.classified(.other(message: "This Firebase app is registered for \(options.bundleID), but this build is \(Bundle.main.bundleIdentifier ?? "unknown")."))
    }

    private func validateEmailCredentials(email: String, password: String) throws {
        guard email.trimmedEmail.contains("@") else {
            throw CloudGatewayError.classified(.other(message: "Enter a valid email address."))
        }
        guard password.count >= 8 else {
            throw CloudGatewayError.classified(.other(message: "Use at least 8 characters for your password."))
        }
    }

    private static func identity(from user: User?) -> MobileAuthIdentity? {
        guard let u = user else { return nil }
        return MobileAuthIdentity(uid: u.uid, email: u.email, displayName: u.displayName, photoURL: u.photoURL)
    }

    private func randomNonceString(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        precondition(SecRandomCopyBytes(kSecRandomDefault, length, &bytes) == errSecSuccess)
        let set = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(bytes.map { set[Int($0) % set.count] })
    }

    private func sha256(_ s: String) -> String {
        Data(SHA256.hash(data: Data(s.utf8))).compactMap { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var trimmedEmail: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class AppleDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    let nonce: String; let done: (Result<Void, Error>) -> Void
    init(nonce: String, done: @escaping (Result<Void, Error>) -> Void) { self.nonce = nonce; self.done = done }

    func presentationAnchor(for c: ASAuthorizationController) -> ASPresentationAnchor {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first ?? UIWindow()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization a: ASAuthorization) {
        guard let cred = a.credential as? ASAuthorizationAppleIDCredential,
              let tok = cred.identityToken, let str = String(data: tok, encoding: .utf8) else {
            done(.failure(CloudGatewayError.classified(.other(message: "Invalid Apple credential")))); return
        }
        let fc = OAuthProvider.appleCredential(withIDToken: str, rawNonce: nonce, fullName: cred.fullName)
        Task { @MainActor in
            do {
                if let u = Auth.auth().currentUser, u.isAnonymous { try await u.link(with: fc) }
                else { try await Auth.auth().signIn(with: fc) }
                done(.success(()))
            } catch { done(.failure(CloudGatewayError.classified(.other(message: error.localizedDescription)))) }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        done(.failure(CloudGatewayError.classified(.other(message: error.localizedDescription))))
    }
}
