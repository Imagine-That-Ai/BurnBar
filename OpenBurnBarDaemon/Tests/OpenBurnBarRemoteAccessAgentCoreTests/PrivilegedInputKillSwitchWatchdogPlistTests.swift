import XCTest

final class PrivilegedInputKillSwitchWatchdogPlistTests: XCTestCase {
    func test_watchdogPlistIsValidAndReferencesBinary() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repoRoot
            .appendingPathComponent("OpenBurnBarDaemon/Resources/PrivilegedInputKillSwitch/com.openburnbar.privileged-input-killswitch-watchdog.plist")

        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertNotNil(plist)

        let label = plist?["Label"] as? String
        XCTAssertEqual(label, "com.openburnbar.privileged-input-killswitch-watchdog")

        let args = plist?["ProgramArguments"] as? [String]
        XCTAssertEqual(args?.first?.hasSuffix("openburnbar-killswitch-watchdog"), true)
        XCTAssertEqual(args?.contains("--socket"), true)
        XCTAssertEqual(args?.contains("/var/run/openburnbar-killswitch-watch.sock"), true)
        XCTAssertEqual(plist?["KeepAlive"] as? Bool, true)
    }
}
