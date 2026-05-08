import XCTest
@testable import OpenBurnBarCore

final class AppCheckDebugTokenEnvironmentTests: XCTestCase {
    func testConfiguresFirebaseDebugTokenFromFirebasePlist() throws {
        let plistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoogleService-Info-\(UUID().uuidString).plist")
        let plist: NSDictionary = [
            AppCheckDebugTokenEnvironment.firebaseDebugTokenKey: " debug-token "
        ]
        XCTAssertTrue(plist.write(to: plistURL, atomically: true))
        defer { try? FileManager.default.removeItem(at: plistURL) }

        var exported: [String: String] = [:]
        let token = AppCheckDebugTokenEnvironment.configureIfAvailable(
            firebasePlistPath: plistURL.path,
            infoDictionary: [:],
            environment: [:],
            setEnvironment: { key, value, _ in
                exported[key] = value
                return 0
            }
        )

        XCTAssertEqual(token, "debug-token")
        XCTAssertEqual(exported[AppCheckDebugTokenEnvironment.firaDebugTokenKey], "debug-token")
        XCTAssertEqual(exported[AppCheckDebugTokenEnvironment.firebaseDebugTokenKey], "debug-token")
    }

    func testMirrorsExistingFirebaseEnvironmentTokenToFIRAKey() {
        var exported: [String: String] = [:]
        let token = AppCheckDebugTokenEnvironment.configureIfAvailable(
            firebasePlistPath: nil,
            infoDictionary: [:],
            environment: [AppCheckDebugTokenEnvironment.firebaseDebugTokenKey: "existing-token"],
            setEnvironment: { key, value, _ in
                exported[key] = value
                return 0
            }
        )

        XCTAssertEqual(token, "existing-token")
        XCTAssertEqual(exported[AppCheckDebugTokenEnvironment.firaDebugTokenKey], "existing-token")
        XCTAssertNil(exported[AppCheckDebugTokenEnvironment.firebaseDebugTokenKey])
    }
}
