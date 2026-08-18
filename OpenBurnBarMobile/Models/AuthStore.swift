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
    private let scopedCaches: MobileUIDScopedCacheRegistry
    private(set) var state: AuthState
    private(set) var lastError: CloudErrorClassification?
    private(set) var lastErrorClass: MobileAuthErrorClass = .none
    private(set) var sessionEpoch = MobileAuthSessionEpoch(uid: nil, generation: 0)

    init(
        gateway: AuthGateway = LiveAuthGateway(),
        trustGateway: DeviceTrustGateway = LiveDeviceTrustGateway(),
        controllerRouteLifecycle: any IrohControllerRouteAuthLifecycleManaging = IrohControllerRouteAuthLifecycleCoordinator.shared,
        scopedCaches: MobileUIDScopedCacheRegistry = .shared
    ) {
        self.gateway = gateway
        self.trustGateway = trustGateway
        self.controllerRouteLifecycle = controllerRouteLifecycle
        self.scopedCaches = scopedCaches
        if !gateway.isFirebaseAvailable {
            self.state = .firebaseUnavailable
        } else if let identity = gateway.currentIdentity {
            self.state = .signedIn(identity: identity)
            self.sessionEpoch = MobileAuthSessionEpoch(uid: identity.uid, generation: 1)
            AgentReplyNotificationService.shared.bindConsumedEvents(to: identity.uid)
        } else {
            self.state = .signedOut
        }
        gateway.observe { [weak self] identity in
            guard let self else { return }
            self.applyObservedIdentity(identity)
        }
    }

    /// Fail-closed on UID change: bump the epoch and drop every registered cache
    /// so a late listener cannot paint the previous account.
    private func applyObservedIdentity(_ identity: MobileAuthIdentity?) {
        guard gateway.isFirebaseAvailable else {
            applyFirebaseUnavailable()
            MobileAnalytics.shared.setUserId(nil)
            return
        }
        // Cleared before reconciling so an observed account switch keeps the
        // class `reconcileEpoch` records.
        lastErrorClass = .none
        reconcileEpoch(nextUid: identity?.uid)
        if let identity {
            state = .signedIn(identity: identity)
            MobileAnalytics.shared.setUserId(
                AnalyticsUserIdentity.amplitudeUserId(forAccountUID: identity.uid)
            )
            Task { await (self.trustGateway as? LiveDeviceTrustGateway)?.registerSelfIfNeeded() }
        } else {
            state = .signedOut
            MobileAnalytics.shared.setUserId(nil)
        }
    }

    private func reconcileEpoch(nextUid: String?) {
        guard MobileAuthSessionPolicy.shouldReconcile(previousUid: sessionEpoch.uid, nextUid: nextUid) else {
            return
        }
        // uid → other uid is a real account switch; uid → nil is an ordinary sign-out.
        if sessionEpoch.uid != nil, nextUid != nil {
            lastErrorClass = .accountSwitch
            lastError = .accountMismatch
        }
        // Never write users/{previousUid} after Firebase Auth has switched.
        // Tombstone A while still authenticated as A (signIn / signOut / delete).
        sessionEpoch = sessionEpoch.advanced(for: nextUid)
        scopedCaches.clearAll()
        AgentReplyNotificationService.shared.clearBanners()
        AgentReplyNotificationService.shared.bindConsumedEvents(to: nextUid)
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
        await attemptSignIn(provider: provider) { success, error in
            trackSignIn(provider, success: success, error: error)
        } perform: {
            try await gateway.signIn(provider: provider)
        }
    }

    func createEmailAccount(email: String, password: String) async {
        await attemptSignIn(provider: .email) { success, error in
            trackSignUp(.email, success: success, error: error)
        } perform: {
            try await gateway.createEmailAccount(email: email, password: password)
        }
    }

    func signInWithEmail(email: String, password: String) async {
        await attemptSignIn(provider: .email) { success, error in
            trackSignIn(.email, success: success, error: error)
        } perform: {
            try await gateway.signInWithEmail(email: email, password: password)
        }
    }

    /// Shared shape for every credential entry point: refuse when Firebase is
    /// unavailable, land in `.signingIn`, then classify whatever comes back.
    /// `track` runs on both outcomes so the taxonomy sees one event per attempt.
    private func attemptSignIn(
        provider: MobileAuthProviderID,
        track: (Bool, CloudErrorClassification?) -> Void,
        perform: () async throws -> Void
    ) async {
        guard gateway.isFirebaseAvailable else {
            applyFirebaseUnavailable()
            return
        }
        state = .signingIn(provider: provider)
        lastError = nil
        lastErrorClass = .none
        do {
            try await perform()
            track(true, nil)
        } catch let CloudGatewayError.classified(c) {
            applySignInFailure(c)
            track(false, c)
        } catch {
            applyUnclassifiedSignInFailure(error)
            track(false, lastError)
        }
    }

    func signOut() async {
        await controllerRouteLifecycle.tearDownAndRevoke()
        await tombstoneCurrentDeviceBeforeAuthSwitch()
        do {
            try gateway.signOut()
            reconcileEpoch(nextUid: nil)
            let signedOut = MobileAuthSessionPolicy.stateAfterSignOut(firebaseAvailable: gateway.isFirebaseAvailable)
            state = signedOut == .firebaseUnavailable ? .firebaseUnavailable : .signedOut
            lastError = nil
            lastErrorClass = .none
            MobileAnalytics.shared.track(.authSignedOut, ["outcome": "success"])
        } catch let CloudGatewayError.classified(c) {
            await AgentReplyNotificationService.shared.restoreDeviceAfterFailedSwitch()
            lastError = c
            lastErrorClass = classify(c)
            MobileAnalytics.shared.track(.authSignedOut, ["outcome": "failure", "error_code": .string(c.analyticsCode)])
        } catch {
            await AgentReplyNotificationService.shared.restoreDeviceAfterFailedSwitch()
            lastError = .other(message: error.localizedDescription)
            lastErrorClass = .malformed
            MobileAnalytics.shared.track(.authSignedOut, ["outcome": "failure", "error_code": "other"])
        }
    }

    func deleteAccount() async {
        guard gateway.isFirebaseAvailable else {
            applyFirebaseUnavailable()
            return
        }
        guard let identity = currentIdentity else { return }
        state = .deletingAccount(identity: identity)
        lastError = nil
        lastErrorClass = .none
        do {
            await controllerRouteLifecycle.tearDownAndRevoke()
            await tombstoneCurrentDeviceBeforeAuthSwitch()
            try await gateway.deleteAccount()
            reconcileEpoch(nextUid: nil)
            state = .signedOut
            MobileAnalytics.shared.track(.authAccountDeleted, ["outcome": "success"])
        } catch let CloudGatewayError.classified(c) {
            lastError = c
            lastErrorClass = classify(c)
            state = .signedIn(identity: identity)
            await AgentReplyNotificationService.shared.restoreDeviceAfterFailedSwitch()
            MobileAnalytics.shared.track(.authAccountDeleted, ["outcome": "failure", "error_code": .string(c.analyticsCode)])
        } catch {
            lastError = .other(message: error.localizedDescription)
            lastErrorClass = .malformed
            state = .signedIn(identity: identity)
            await AgentReplyNotificationService.shared.restoreDeviceAfterFailedSwitch()
            MobileAnalytics.shared.track(.authAccountDeleted, ["outcome": "failure", "error_code": "other"])
        }
    }

    /// Invalidate this device's FCM token while Firebase Auth is still A.
    /// Post-switch writes to `users/{oldUid}` are denied by `ownsUserNamespace`.
    private func tombstoneCurrentDeviceBeforeAuthSwitch() async {
        await AgentReplyNotificationService.shared.tombstoneCurrentDevice()
    }

    private func applyFirebaseUnavailable() {
        reconcileEpoch(nextUid: nil)
        state = .firebaseUnavailable
        lastError = .firebaseUnavailable
        lastErrorClass = .firebaseUnavailable
    }

    /// A sign-in/sign-up failure the gateway did not classify. Always lands
    /// signed-out, but still records the sharpest class the message supports.
    private func applyUnclassifiedSignInFailure(_ error: Error) {
        lastError = .other(message: error.localizedDescription)
        lastErrorClass = MobileAuthSessionPolicy.classify(code: "other", message: error.localizedDescription)
        state = .signedOut
    }

    private func applySignInFailure(_ classification: CloudErrorClassification) {
        lastError = classification
        lastErrorClass = classify(classification)
        if lastErrorClass == .firebaseUnavailable {
            state = .firebaseUnavailable
        } else {
            state = .signedOut
        }
    }

    private func classify(_ classification: CloudErrorClassification) -> MobileAuthErrorClass {
        switch classification {
        case .appCheckBlocked: return .appCheck
        case .accountMismatch: return .accountSwitch
        case .permissionDenied: return .permissionDenied
        case .firebaseUnavailable: return .firebaseUnavailable
        case .firestoreUnavailable: return .firestoreUnavailable
        case .networkUnavailable: return .network
        case .notAuthenticated: return .none
        default: return MobileAuthSessionPolicy.classify(code: classification.analyticsCode, message: classification.label)
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

    func clearError() {
        lastError = nil
        if lastErrorClass != .firebaseUnavailable {
            lastErrorClass = .none
        }
    }

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
