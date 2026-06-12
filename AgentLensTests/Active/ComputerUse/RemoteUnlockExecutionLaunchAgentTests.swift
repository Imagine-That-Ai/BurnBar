#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
@testable import OpenBurnBar

/// The execution helper must be launchd-supervised: RunAtLoad brings it back
/// at login, KeepAlive restarts it after a crash, and the label single-
/// instances it. A detached `Process` regression here silently kills remote
/// unlock on the first reboot — the exact away-from-Mac scenario the feature
/// exists for.
@MainActor
final class RemoteUnlockExecutionLaunchAgentTests: XCTestCase {
    private func decodedPlist() throws -> [String: Any] {
        let data = try RemoteUnlockVirtualHIDBridgeInstaller.executionLaunchAgentPlistData(
            executablePath: "/Library/Application Support/OpenBurnBar/RemoteUnlock/Helper.app/Contents/MacOS/Helper",
            socketPath: "/Library/Application Support/OpenBurnBar/RemoteUnlock/sockets/501/input.sock",
            stdoutPath: "/Users/test/Library/Logs/OpenBurnBar/helper.log",
            stderrPath: "/Users/test/Library/Logs/OpenBurnBar/helper.err.log"
        )
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    func test_launchAgentPlist_isSupervisedByLaunchd() throws {
        let plist = try decodedPlist()
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true, "helper must start at login")
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true, "helper must restart after a crash")
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
    }

    func test_launchAgentPlist_runsHelperAgainstItsSocket() throws {
        let plist = try decodedPlist()
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments.count, 3)
        XCTAssertTrue(arguments[0].hasSuffix("/Helper"))
        XCTAssertEqual(arguments[1], "--socket")
        XCTAssertTrue(arguments[2].hasSuffix("/sockets/501/input.sock"))
    }

    func test_launchAgentPlist_labelMatchesExecutionService() throws {
        let plist = try decodedPlist()
        XCTAssertEqual(plist["Label"] as? String, "com.openburnbar.privileged-input-execution")
    }

    func test_launchAgentPlist_capturesHelperLogs() throws {
        let plist = try decodedPlist()
        XCTAssertEqual(plist["StandardOutPath"] as? String, "/Users/test/Library/Logs/OpenBurnBar/helper.log")
        XCTAssertEqual(plist["StandardErrorPath"] as? String, "/Users/test/Library/Logs/OpenBurnBar/helper.err.log")
    }
}
#endif
