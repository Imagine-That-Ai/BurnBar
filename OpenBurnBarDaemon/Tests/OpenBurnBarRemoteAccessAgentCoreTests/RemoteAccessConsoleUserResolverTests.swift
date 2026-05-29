import XCTest
@testable import OpenBurnBarRemoteAccessAgentCore

final class RemoteAccessConsoleUserResolverTests: XCTestCase {
    /// The regression that broke Remote Unlock: while the screen is locked, `/dev/console` flips to
    /// root (uid 0) but SystemConfiguration still reports the logged-in user. We must trust the
    /// console user and keep serving uid 501.
    func testLockedScreenResolvesLoggedInUserEvenWhenConsoleDeviceIsRoot() {
        let resolved = RemoteAccessConsoleUserResolver.resolve(
            dynamicStoreUser: (name: "albertonunez", uid: 501, gid: 20),
            consoleDeviceOwner: (uid: 0, gid: 0)
        )
        XCTAssertEqual(resolved, RemoteAccessConsoleUser(uid: 501, gid: 20))
    }

    /// At the login window (logged out / fast-user-switch) there is no interactive user. The
    /// resolver must return nil so the daemon stays alive and simply declines work.
    func testLoginWindowReturnsNoConsoleUser() {
        let resolved = RemoteAccessConsoleUserResolver.resolve(
            dynamicStoreUser: (name: "loginwindow", uid: 0, gid: 0),
            consoleDeviceOwner: (uid: 0, gid: 0)
        )
        XCTAssertNil(resolved)
    }

    /// A nil console-user name (some macOS versions return NULL at the login window) is also
    /// treated as "no interactive user" when the uid is root.
    func testNilDynamicStoreNameWithRootUIDReturnsNil() {
        let resolved = RemoteAccessConsoleUserResolver.resolve(
            dynamicStoreUser: (name: nil, uid: 0, gid: 0),
            consoleDeviceOwner: nil
        )
        XCTAssertNil(resolved)
    }

    /// When SystemConfiguration is momentarily unavailable, fall back to the `/dev/console` owner
    /// (valid while unlocked, where it points at the logged-in user).
    func testFallsBackToConsoleDeviceOwnerWhenDynamicStoreUnavailable() {
        let resolved = RemoteAccessConsoleUserResolver.resolve(
            dynamicStoreUser: nil,
            consoleDeviceOwner: (uid: 501, gid: 20)
        )
        XCTAssertEqual(resolved, RemoteAccessConsoleUser(uid: 501, gid: 20))
    }

    /// The console user from SystemConfiguration always wins over the `/dev/console` fallback,
    /// including the multi-user case where they disagree.
    func testDynamicStoreUserTakesPrecedenceOverConsoleDeviceOwner() {
        let resolved = RemoteAccessConsoleUserResolver.resolve(
            dynamicStoreUser: (name: "second", uid: 502, gid: 20),
            consoleDeviceOwner: (uid: 501, gid: 20)
        )
        XCTAssertEqual(resolved, RemoteAccessConsoleUser(uid: 502, gid: 20))
    }

    /// System/service accounts (uid < 500) are never treated as interactive GUI users, even if a
    /// signal somehow reports one.
    func testServiceAccountUIDsAreRejected() {
        XCTAssertNil(
            RemoteAccessConsoleUserResolver.resolve(
                dynamicStoreUser: (name: "_mbsetupuser", uid: 248, gid: 248),
                consoleDeviceOwner: (uid: 248, gid: 248)
            )
        )
        XCTAssertFalse(RemoteAccessConsoleUserResolver.isInteractive(name: nil, uid: 0))
        XCTAssertFalse(RemoteAccessConsoleUserResolver.isInteractive(name: nil, uid: 499))
        XCTAssertTrue(RemoteAccessConsoleUserResolver.isInteractive(name: "albertonunez", uid: 501))
    }

    /// A real account name with a `root`/`loginwindow` collision in casing/whitespace is still
    /// rejected, but a normal account name passes.
    func testNonInteractiveNamesAreRejectedCaseInsensitively() {
        XCTAssertFalse(RemoteAccessConsoleUserResolver.isInteractive(name: " LoginWindow ", uid: 501))
        XCTAssertFalse(RemoteAccessConsoleUserResolver.isInteractive(name: "root", uid: 501))
        XCTAssertTrue(RemoteAccessConsoleUserResolver.isInteractive(name: "alberto", uid: 501))
    }

    func testDisplayWakePolicyWaitsLongerWhenDisplayWasAsleep() {
        XCTAssertEqual(
            RemoteAccessDisplayWakePolicy.settleDelayMicroseconds(displayWasAsleep: false),
            150_000
        )
        XCTAssertEqual(
            RemoteAccessDisplayWakePolicy.settleDelayMicroseconds(displayWasAsleep: true),
            900_000
        )
        XCTAssertGreaterThan(
            RemoteAccessDisplayWakePolicy.settleDelayMicroseconds(displayWasAsleep: true),
            RemoteAccessDisplayWakePolicy.settleDelayMicroseconds(displayWasAsleep: false)
        )
    }
}
