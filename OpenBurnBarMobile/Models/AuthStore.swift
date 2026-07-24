import Foundation
import OpenBurnBarCore
import OpenBurnBarAnalytics

public enum AuthState: Sendable, Equatable {
    case signedOut
    case signingIn(provider: MobileAuthProviderID)
    case signedIn(identity: MobileAuthIdentity)
    case deletingAccount(identity: MobileAuthIdentity)
    case firebaseUnavailable
    case firestoreUnavailable

    public var isSignedIn: Bool {
        switch self {
        case .signedIn, .deletingAccount: return true
        default: return false
        }
    }
    public var inFlightProvider: MobileAuthProviderID? {
        if case .signingIn(let p) = self { return p }; return nil
    }
}

@Observable @MainActor
final class AuthStore {
    private let gateway: AuthGateway
    private let trustGateway: DeviceTrustGateway
    private let controllerRouteLifecycle: any IrohControllerRouteAuthLifecycleManaging
    private(set) var state: AuthState
    private(set) var lastError: CloudErrorClassification?

    init(
        gateway: AuthGateway = LiveAuthGateway(),
        trustGateway: DeviceTrustGateway = LiveDeviceTrustGateway(),
        controllerRouteLifecycle: any IrohControllerRouteAuthLifecycleManaging = IrohControllerRouteAuthLifecycleCoordinator.shared
    ) {
        self.gateway = gateway
        self.trustGateway = trustGateway
        self.controllerRouteLifecycle = controllerRouteLifecycle
        if !gateway.isFirebaseAvailable {
            self.state = .firebaseUnavailable
        } else if let identity = gateway.currentIdentity {
            self.state = .signedIn(identity: identity)
        } else {
            self.state = .signedOut
        }
        gateway.observe { [weak self] identity in
            guard let self else { return }
            if !gateway.isFirebaseAvailable {
                self.state = .firebaseUnavailable
            } else if let identity {
                self.state = .signedIn(identity: identity)
                // Identify the signed-in user with a STABLE HASH of the account
                // uid — never the raw uid. No-op unless analytics consent is
                // granted. Set only after verified sign-in, per the taxonomy.
                MobileAnalytics.shared.setUserId(
                    AnalyticsUserIdentity.amplitudeUserId(forAccountUID: identity.uid)
                )
                // Register this device in Firestore on sign-in
                Task { await (self.trustGateway as? LiveDeviceTrustGateway)?.registerSelfIfNeeded() }
            } else {
                self.state = .signedOut
                // Clear the identity so a later anonymous session is not tied to
                // the prior account. No-op unless consent is granted.
                MobileAnalytics.shared.setUserId(nil)
            }
        }
    }

    /// The taxonomy `method` enum value for an auth provider (`google` | `apple` |
    /// `github` | `email`) — the `MobileAuthProviderID` raw values already match.
    private static func method(_ provider: MobileAuthProviderID) -> AnalyticsValue {
        .string(provider.rawValue)
    }

    var availableProviders: [MobileAuthProviderID] { gateway.availableProviders }
    var currentIdentity: MobileAuthIdentity? {
        switch state {
        case .signedIn(let identity), .deletingAccount(let identity): return identity
        default: return nil
        }
    }
    var isDeletingAccount: Bool {
        if case .deletingAccount = state { return true }; return false
    }

    func signIn(_ provider: MobileAuthProviderID) async {
        guard gateway.isFirebaseAvailable else { state = .firebaseUnavailable; return }
        state = .signingIn(provider: provider); lastError = nil
        do {
            try await gateway.signIn(provider: provider)
            trackSignIn(provider, success: true, error: nil)
        } catch let CloudGatewayError.classified(c) {
            lastError = c; state = .signedOut
            trackSignIn(provider, success: false, error: c)
        } catch {
            lastError = .other(message: error.localizedDescription); state = .signedOut
            trackSignIn(provider, success: false, error: lastError)
        }
    }

    func createEmailAccount(email: String, password: String) async {
        guard gateway.isFirebaseAvailable else { state = .firebaseUnavailable; return }
        state = .signingIn(provider: .email); lastError = nil
        do {
            try await gateway.createEmailAccount(email: email, password: password)
            trackSignUp(.email, success: true, error: nil)
        } catch let CloudGatewayError.classified(c) {
            lastError = c; state = .signedOut
            trackSignUp(.email, success: false, error: c)
        } catch {
            lastError = .other(message: error.localizedDescription); state = .signedOut
            trackSignUp(.email, success: false, error: lastError)
        }
    }

    func signInWithEmail(email: String, password: String) async {
        guard gateway.isFirebaseAvailable else { state = .firebaseUnavailable; return }
        state = .signingIn(provider: .email); lastError = nil
        do {
            try await gateway.signInWithEmail(email: email, password: password)
            trackSignIn(.email, success: true, error: nil)
        } catch let CloudGatewayError.classified(c) {
            lastError = c; state = .signedOut
            trackSignIn(.email, success: false, error: c)
        } catch {
            lastError = .other(message: error.localizedDescription); state = .signedOut
            trackSignIn(.email, success: false, error: lastError)
        }
    }

    func signOut() async {
        await controllerRouteLifecycle.tearDownAndRevoke()
        do {
            try gateway.signOut(); state = .signedOut; lastError = nil
            MobileAnalytics.shared.track(.authSignedOut, ["outcome": "success"])
        } catch let CloudGatewayError.classified(c) {
            lastError = c
            MobileAnalytics.shared.track(.authSignedOut, ["outcome": "failure", "error_code": .string(c.analyticsCode)])
        } catch {
            lastError = .other(message: error.localizedDescription)
            MobileAnalytics.shared.track(.authSignedOut, ["outcome": "failure", "error_code": "other"])
        }
    }

    func deleteAccount() async {
        guard gateway.isFirebaseAvailable else { state = .firebaseUnavailable; return }
        guard let identity = currentIdentity else { return }
        state = .deletingAccount(identity: identity)
        lastError = nil
        do {
            await controllerRouteLifecycle.tearDownAndRevoke()
            try await gateway.deleteAccount()
            state = .signedOut
            MobileAnalytics.shared.track(.authAccountDeleted, ["outcome": "success"])
        } catch let CloudGatewayError.classified(c) {
            lastError = c
            state = .signedIn(identity: identity)
            MobileAnalytics.shared.track(.authAccountDeleted, ["outcome": "failure", "error_code": .string(c.analyticsCode)])
        } catch {
            lastError = .other(message: error.localizedDescription)
            state = .signedIn(identity: identity)
            MobileAnalytics.shared.track(.authAccountDeleted, ["outcome": "failure", "error_code": "other"])
        }
    }

    private func trackSignIn(_ provider: MobileAuthProviderID, success: Bool, error: CloudErrorClassification?) {
        var props: [String: AnalyticsValue] = [
            "method": Self.method(provider),
            "outcome": .string(success ? "success" : "failure")
        ]
        if let error { props["error_code"] = .string(error.analyticsCode) }
        MobileAnalytics.shared.track(.authSignInCompleted, props)
    }

    private func trackSignUp(_ provider: MobileAuthProviderID, success: Bool, error: CloudErrorClassification?) {
        var props: [String: AnalyticsValue] = [
            "method": Self.method(provider),
            "outcome": .string(success ? "success" : "failure")
        ]
        if let error { props["error_code"] = .string(error.analyticsCode) }
        MobileAnalytics.shared.track(.authSignUpCompleted, props)
    }

    func clearError() { lastError = nil }

    /// Patch the in-memory identity with a newly uploaded photoURL so views
    /// refresh immediately without waiting for the next Firebase observer event.
    func refreshIdentity(photoURL: URL) async {
        guard let identity = currentIdentity else { return }
        let patched = MobileAuthIdentity(
            uid: identity.uid,
            email: identity.email,
            displayName: identity.displayName,
            photoURL: photoURL
        )
        state = .signedIn(identity: patched)
    }
}
