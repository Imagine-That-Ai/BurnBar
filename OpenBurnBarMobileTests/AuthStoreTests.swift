import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class AuthStoreTests: XCTestCase {
    func testDeleteAccountCallsGatewayAndSignsOut() async {
        let identity = MobileAuthIdentity(
            uid: "review-user",
            email: "app-review@openburnbar.app",
            displayName: "App Review"
        )
        let lifecycle = AuthRouteLifecycleProbe()
        let gateway = FakeAuthGateway(identity: identity, lifecycle: lifecycle)
        let coordinator = makeAuthLifecycleCoordinator(lifecycle)
        let store = AuthStore(
            gateway: gateway,
            trustGateway: FakeDeviceTrustGateway(),
            controllerRouteLifecycle: coordinator
        )

        await store.deleteAccount()

        XCTAssertTrue(gateway.didDeleteAccount)
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(lifecycle.events, ["endpoint", "revoke", "delete"])
    }

    func testDeleteAccountRestoresSignedInStateWhenDeletionFails() async {
        let identity = MobileAuthIdentity(
            uid: "review-user",
            email: "app-review@openburnbar.app",
            displayName: "App Review"
        )
        let lifecycle = AuthRouteLifecycleProbe()
        let gateway = FakeAuthGateway(
            identity: identity,
            deleteError: CloudGatewayError.classified(.permissionDenied),
            lifecycle: lifecycle
        )
        let coordinator = makeAuthLifecycleCoordinator(lifecycle)
        let store = AuthStore(
            gateway: gateway,
            trustGateway: FakeDeviceTrustGateway(),
            controllerRouteLifecycle: coordinator
        )

        await store.deleteAccount()

        XCTAssertTrue(gateway.didDeleteAccount)
        XCTAssertEqual(store.state, .signedIn(identity: identity))
        XCTAssertEqual(store.lastError, .permissionDenied)
        XCTAssertEqual(lifecycle.events, ["endpoint", "revoke", "delete"])
    }

    func testSignOutRevokesControllerRouteBeforeSigningOutGateway() async {
        let identity = MobileAuthIdentity(
            uid: "review-user",
            email: "app-review@openburnbar.app",
            displayName: "App Review"
        )
        let lifecycle = AuthRouteLifecycleProbe()
        let gateway = FakeAuthGateway(identity: identity, lifecycle: lifecycle)
        let coordinator = makeAuthLifecycleCoordinator(lifecycle)
        let store = AuthStore(
            gateway: gateway,
            trustGateway: FakeDeviceTrustGateway(),
            controllerRouteLifecycle: coordinator
        )

        await store.signOut()

        XCTAssertEqual(store.state, .signedOut)
        XCTAssertEqual(lifecycle.events, ["endpoint", "revoke", "signOut"])
    }

    func testSignOutClearsScopedCachesAndDropsPreviousUid() async {
        let identity = MobileAuthIdentity(
            uid: "review-user",
            email: "app-review@openburnbar.app",
            displayName: "App Review"
        )
        let caches = MobileUIDScopedCacheRegistry()
        var cleared = 0
        caches.register { cleared += 1 }
        let lifecycle = AuthRouteLifecycleProbe()
        let gateway = FakeAuthGateway(identity: identity, lifecycle: lifecycle)
        let store = AuthStore(
            gateway: gateway,
            trustGateway: FakeDeviceTrustGateway(),
            controllerRouteLifecycle: makeAuthLifecycleCoordinator(lifecycle),
            scopedCaches: caches
        )
        let previous = store.sessionEpoch

        await store.signOut()

        XCTAssertEqual(store.state, .signedOut)
        XCTAssertGreaterThan(cleared, 0)
        XCTAssertFalse(MobileAuthSessionPolicy.isCurrent(expected: previous, current: store.sessionEpoch))
        XCTAssertFalse(
            MobileAuthSessionPolicy.shouldServeCachedData(
                cacheUid: "review-user",
                activeUid: store.sessionEpoch.uid,
                cacheGeneration: previous.generation,
                activeGeneration: store.sessionEpoch.generation
            )
        )
    }

    func testAccountSwitchDoesNotServePreviousUid() async {
        let first = MobileAuthIdentity(uid: "uid-a", email: "a@example.com", displayName: "A")
        let second = MobileAuthIdentity(uid: "uid-b", email: "b@example.com", displayName: "B")
        let caches = MobileUIDScopedCacheRegistry()
        var cleared = 0
        caches.register { cleared += 1 }
        let gateway = FakeAuthGateway(identity: first)
        let store = AuthStore(
            gateway: gateway,
            trustGateway: FakeDeviceTrustGateway(),
            controllerRouteLifecycle: makeAuthLifecycleCoordinator(AuthRouteLifecycleProbe()),
            scopedCaches: caches
        )
        let previous = store.sessionEpoch

        gateway.emit(second)

        XCTAssertEqual(store.state, .signedIn(identity: second))
        XCTAssertEqual(store.lastErrorClass, .accountSwitch)
        XCTAssertGreaterThan(cleared, 0)
        XCTAssertFalse(MobileAuthSessionPolicy.isCurrent(expected: previous, current: store.sessionEpoch))
    }

    func testAppCheckFailureIsDistinctFromSignedOutAndFirebaseUnavailable() async {
        let gateway = FakeAuthGateway(identity: nil)
        gateway.signInError = CloudGatewayError.classified(.appCheckBlocked)
        let store = AuthStore(
            gateway: gateway,
            trustGateway: FakeDeviceTrustGateway(),
            controllerRouteLifecycle: makeAuthLifecycleCoordinator(AuthRouteLifecycleProbe())
        )

        await store.signIn(.email)

        XCTAssertEqual(store.state, .signedOut)
        XCTAssertEqual(store.lastError, .appCheckBlocked)
        XCTAssertEqual(store.lastErrorClass, .appCheck)
        XCTAssertNotEqual(store.state, .firebaseUnavailable)
        XCTAssertNotEqual(store.lastErrorClass, .permissionDenied)
    }

    func testFirebaseUnavailableIsNotSignedOut() {
        let gateway = FakeAuthGateway(identity: nil)
        gateway.isFirebaseAvailable = false
        let store = AuthStore(
            gateway: gateway,
            trustGateway: FakeDeviceTrustGateway(),
            controllerRouteLifecycle: makeAuthLifecycleCoordinator(AuthRouteLifecycleProbe())
        )

        XCTAssertEqual(store.state, .firebaseUnavailable)
        XCTAssertNotEqual(store.state, .signedOut)
    }

    func testAuthLifecycleInvalidatesOnlyAfterObservedAccountChanges() async {
        let lifecycle = AuthRouteLifecycleProbe()
        let coordinator = makeAuthLifecycleCoordinator(lifecycle)

        await coordinator.handleAuthenticatedUIDChanged(to: "user-a")
        await coordinator.handleAuthenticatedUIDChanged(to: "user-a")
        XCTAssertEqual(lifecycle.events, [])

        await coordinator.handleAuthenticatedUIDChanged(to: "user-b")
        await coordinator.handleAuthenticatedUIDChanged(to: nil)
        XCTAssertEqual(
            lifecycle.events,
            ["endpoint", "invalidate", "endpoint", "invalidate"]
        )
    }

    private func makeAuthLifecycleCoordinator(
        _ lifecycle: AuthRouteLifecycleProbe
    ) -> IrohControllerRouteAuthLifecycleCoordinator {
        IrohControllerRouteAuthLifecycleCoordinator(
            routeLifecycle: lifecycle,
            endpointTeardown: {
                await lifecycle.recordEndpointTeardown()
            }
        )
    }
}

@MainActor
private final class FakeAuthGateway: AuthGateway {
    var availableProviders: [MobileAuthProviderID] = [.email]
    var isFirebaseAvailable = true
    var currentIdentity: MobileAuthIdentity?
    var didDeleteAccount = false
    var deleteError: Error?
    var signInError: Error?
    private let lifecycle: AuthRouteLifecycleProbe?
    private var observer: (@MainActor (MobileAuthIdentity?) -> Void)?

    init(
        identity: MobileAuthIdentity?,
        deleteError: Error? = nil,
        lifecycle: AuthRouteLifecycleProbe? = nil
    ) {
        self.currentIdentity = identity
        self.deleteError = deleteError
        self.lifecycle = lifecycle
    }

    func observe(onChange: @escaping @MainActor (MobileAuthIdentity?) -> Void) {
        observer = onChange
        onChange(currentIdentity)
    }

    func emit(_ identity: MobileAuthIdentity?) {
        currentIdentity = identity
        observer?(identity)
    }

    func signIn(provider: MobileAuthProviderID) async throws {
        if let signInError { throw signInError }
    }
    func createEmailAccount(email: String, password: String) async throws {}
    func signInWithEmail(email: String, password: String) async throws {}

    func deleteAccount() async throws {
        didDeleteAccount = true
        lifecycle?.events.append("delete")
        if let deleteError { throw deleteError }
        currentIdentity = nil
        observer?(nil)
    }

    func signOut() throws {
        lifecycle?.events.append("signOut")
        currentIdentity = nil
        observer?(nil)
    }
}

@MainActor
private final class AuthRouteLifecycleProbe: IrohControllerRouteLifecycleManaging {
    var events: [String] = []

    func recordEndpointTeardown() {
        events.append("endpoint")
    }

    func invalidateAndRevoke() async {
        events.append("revoke")
    }

    func invalidateForAccountChange() async {
        events.append("invalidate")
    }
}

@MainActor
private final class FakeDeviceTrustGateway: DeviceTrustGateway {
    func bootstrapApproveSelf() async throws {}
    func approve(deviceID: String) async throws {}
    func renameSelf(_ newName: String) async throws {}
    func revoke(deviceID: String) async throws {}
}
