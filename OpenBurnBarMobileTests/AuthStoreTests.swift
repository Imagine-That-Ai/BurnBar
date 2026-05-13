import XCTest
@testable import OpenBurnBarMobile

@MainActor
final class AuthStoreTests: XCTestCase {
    func testDeleteAccountCallsGatewayAndSignsOut() async {
        let identity = MobileAuthIdentity(
            uid: "review-user",
            email: "app-review@openburnbar.app",
            displayName: "App Review"
        )
        let gateway = FakeAuthGateway(identity: identity)
        let store = AuthStore(gateway: gateway, trustGateway: FakeDeviceTrustGateway())

        await store.deleteAccount()

        XCTAssertTrue(gateway.didDeleteAccount)
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertNil(store.lastError)
    }

    func testDeleteAccountRestoresSignedInStateWhenDeletionFails() async {
        let identity = MobileAuthIdentity(
            uid: "review-user",
            email: "app-review@openburnbar.app",
            displayName: "App Review"
        )
        let gateway = FakeAuthGateway(
            identity: identity,
            deleteError: CloudGatewayError.classified(.permissionDenied)
        )
        let store = AuthStore(gateway: gateway, trustGateway: FakeDeviceTrustGateway())

        await store.deleteAccount()

        XCTAssertTrue(gateway.didDeleteAccount)
        XCTAssertEqual(store.state, .signedIn(identity: identity))
        XCTAssertEqual(store.lastError, .permissionDenied)
    }
}

@MainActor
private final class FakeAuthGateway: AuthGateway {
    var availableProviders: [MobileAuthProviderID] = [.email]
    var isFirebaseAvailable = true
    var currentIdentity: MobileAuthIdentity?
    var didDeleteAccount = false
    var deleteError: Error?
    private var observer: (@MainActor (MobileAuthIdentity?) -> Void)?

    init(identity: MobileAuthIdentity?, deleteError: Error? = nil) {
        self.currentIdentity = identity
        self.deleteError = deleteError
    }

    func observe(onChange: @escaping @MainActor (MobileAuthIdentity?) -> Void) {
        observer = onChange
        onChange(currentIdentity)
    }

    func signIn(provider: MobileAuthProviderID) async throws {}
    func createEmailAccount(email: String, password: String) async throws {}
    func signInWithEmail(email: String, password: String) async throws {}

    func deleteAccount() async throws {
        didDeleteAccount = true
        if let deleteError { throw deleteError }
        currentIdentity = nil
        observer?(nil)
    }

    func signOut() throws {
        currentIdentity = nil
        observer?(nil)
    }
}

@MainActor
private final class FakeDeviceTrustGateway: DeviceTrustGateway {
    func bootstrapApproveSelf() async throws {}
    func renameSelf(_ newName: String) async throws {}
    func revoke(deviceID: String) async throws {}
}
