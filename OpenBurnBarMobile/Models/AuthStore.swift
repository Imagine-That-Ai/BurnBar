import Foundation
import OpenBurnBarCore

public enum AuthState: Sendable, Equatable {
    case signedOut
    case signingIn(provider: MobileAuthProviderID)
    case signedIn(identity: MobileAuthIdentity)
    case firebaseUnavailable
    case firestoreUnavailable

    public var isSignedIn: Bool {
        if case .signedIn = self { return true }; return false
    }
    public var inFlightProvider: MobileAuthProviderID? {
        if case .signingIn(let p) = self { return p }; return nil
    }
}

@Observable @MainActor
final class AuthStore {
    private let gateway: AuthGateway
    private let trustGateway: DeviceTrustGateway
    private(set) var state: AuthState
    private(set) var lastError: CloudErrorClassification?

    init(
        gateway: AuthGateway = LiveAuthGateway(),
        trustGateway: DeviceTrustGateway = LiveDeviceTrustGateway()
    ) {
        self.gateway = gateway
        self.trustGateway = trustGateway
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
                // Register this device in Firestore on sign-in
                Task { await (self.trustGateway as? LiveDeviceTrustGateway)?.registerSelfIfNeeded() }
            } else {
                self.state = .signedOut
            }
        }
    }

    var availableProviders: [MobileAuthProviderID] { gateway.availableProviders }
    var currentIdentity: MobileAuthIdentity? {
        if case .signedIn(let i) = state { return i }; return nil
    }

    func signIn(_ provider: MobileAuthProviderID) async {
        guard gateway.isFirebaseAvailable else { state = .firebaseUnavailable; return }
        state = .signingIn(provider: provider); lastError = nil
        do { try await gateway.signIn(provider: provider) }
        catch let CloudGatewayError.classified(c) { lastError = c; state = .signedOut }
        catch { lastError = .other(message: error.localizedDescription); state = .signedOut }
    }

    func signOut() {
        do { try gateway.signOut(); state = .signedOut; lastError = nil }
        catch let CloudGatewayError.classified(c) { lastError = c }
        catch { lastError = .other(message: error.localizedDescription) }
    }

    func clearError() { lastError = nil }
}
