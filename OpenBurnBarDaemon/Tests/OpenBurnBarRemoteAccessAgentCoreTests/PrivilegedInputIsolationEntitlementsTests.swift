import XCTest

/// WS1 isolation gate: input-execution leaf holds only virtual HID; socket adapter and agent stay minimal.
final class PrivilegedInputIsolationEntitlementsTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func test_inputExecutionEntitlements_onlyVirtualHID() throws {
        let url = repoRoot.appendingPathComponent(
            "OpenBurnBarDaemon/Resources/PrivilegedInputExecution/OpenBurnBarPrivilegedInputExecution.entitlements"
        )
        let plist = try loadEntitlements(url)
        XCTAssertEqual(plist["com.apple.developer.hid.virtual.device"] as? Bool, true)
        XCTAssertNil(plist["com.apple.security.network.client"])
        XCTAssertNil(plist["com.apple.security.network.server"])
        XCTAssertNil(plist["keychain-access-groups"])
        XCTAssertNil(plist["com.apple.developer.icloud-services"])
        XCTAssertNil(plist["com.apple.developer.applesignin"])
    }

    func test_virtualHIDBridgeSocketAdapter_hasNoHIDEntitlement() throws {
        let url = repoRoot.appendingPathComponent(
            "OpenBurnBarDaemon/Resources/VirtualHIDBridge/OpenBurnBarVirtualHIDBridgeSocketAdapter.entitlements"
        )
        let plist = try loadEntitlements(url)
        XCTAssertNil(plist["com.apple.developer.hid.virtual.device"])
        XCTAssertNil(plist["com.apple.security.network.client"])
        XCTAssertNil(plist["keychain-access-groups"])
    }

    func test_remoteAccessAgent_hasNoHIDNetworkOrKeychain() throws {
        let url = repoRoot.appendingPathComponent(
            "OpenBurnBarDaemon/Resources/RemoteAccessAgent/OpenBurnBarRemoteAccessAgent.entitlements"
        )
        let plist = try loadEntitlements(url)
        XCTAssertNil(plist["com.apple.developer.hid.virtual.device"])
        XCTAssertNil(plist["com.apple.security.network.client"])
        XCTAssertNil(plist["keychain-access-groups"])
    }

    private func loadEntitlements(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = plist as? [String: Any] else {
            XCTFail("entitlements plist is not a dictionary: \(url.path)")
            return [:]
        }
        return dictionary
    }
}
