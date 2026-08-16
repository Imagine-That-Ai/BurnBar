import BurnBarDaemon
import XCTest

final class BurnBarDaemonSocketEnvironmentTests: XCTestCase {
    func testEmptySocketOverrideFallsBackToSupportDirectoryDefault() {
        let supportDirectory = "/tmp/burnbar-empty-socket-support"
        let resolved = BurnBarDaemonPaths.socketPath(
            environment: [
                "BURNBAR_DAEMON_SOCKET_PATH": "",
                "BURNBAR_DAEMON_SUPPORT_DIR": supportDirectory
            ]
        )

        XCTAssertEqual(
            resolved,
            "\(supportDirectory)/burnbar-daemon.sock",
            "An empty override must behave as unset for executable and documented readers"
        )
    }

    func testNonEmptySocketOverrideWinsOverSupportDirectoryDefault() {
        let resolved = BurnBarDaemonPaths.socketPath(
            environment: [
                "BURNBAR_DAEMON_SOCKET_PATH": "/tmp/burnbar-explicit.sock",
                "BURNBAR_DAEMON_SUPPORT_DIR": "/tmp/burnbar-explicit-support"
            ]
        )

        XCTAssertEqual(resolved, "/tmp/burnbar-explicit.sock")
    }
}
