import XCTest
@testable import OpenBurnBarLaunchServices

final class AppCheckDebugTokenEnvironmentTests: XCTestCase {
    func testAllowedPolicyConfiguresFirebaseDebugTokenFromFirebasePlist() throws {
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
            debugAppCheckAllowed: true,
            setEnvironment: { key, value, _ in
                exported[key] = value
                return 0
            }
        )

        XCTAssertEqual(token, "debug-token")
        XCTAssertEqual(exported[AppCheckDebugTokenEnvironment.firaDebugTokenKey], "debug-token")
        XCTAssertEqual(exported[AppCheckDebugTokenEnvironment.firebaseDebugTokenKey], "debug-token")
    }

    func testAllowedPolicyMirrorsExistingFirebaseEnvironmentTokenToFIRAKey() {
        var exported: [String: String] = [:]
        let token = AppCheckDebugTokenEnvironment.configureIfAvailable(
            firebasePlistPath: nil,
            infoDictionary: [:],
            environment: [AppCheckDebugTokenEnvironment.firebaseDebugTokenKey: "existing-token"],
            debugAppCheckAllowed: true,
            setEnvironment: { key, value, _ in
                exported[key] = value
                return 0
            }
        )

        XCTAssertEqual(token, "existing-token")
        XCTAssertEqual(exported[AppCheckDebugTokenEnvironment.firaDebugTokenKey], "existing-token")
        XCTAssertNil(exported[AppCheckDebugTokenEnvironment.firebaseDebugTokenKey])
    }

    func testDeniedPolicyIgnoresConfiguredTokensAndDoesNotExportEnvironment() throws {
        let plistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoogleService-Info-\(UUID().uuidString).plist")
        let plist: NSDictionary = [
            AppCheckDebugTokenEnvironment.firebaseDebugTokenKey: "plist-token"
        ]
        XCTAssertTrue(plist.write(to: plistURL, atomically: true))
        defer { try? FileManager.default.removeItem(at: plistURL) }

        var exported: [String: String] = [:]
        let token = AppCheckDebugTokenEnvironment.configureIfAvailable(
            firebasePlistPath: plistURL.path,
            infoDictionary: [AppCheckDebugTokenEnvironment.firaDebugTokenKey: "info-token"],
            environment: [AppCheckDebugTokenEnvironment.firebaseDebugTokenKey: "env-token"],
            debugAppCheckAllowed: false,
            setEnvironment: { key, value, _ in
                exported[key] = value
                return 0
            }
        )

        XCTAssertNil(token)
        XCTAssertTrue(exported.isEmpty)
    }

    func testWhitespaceAndEmptyTokensAreIgnored() throws {
        let plistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoogleService-Info-\(UUID().uuidString).plist")
        let plist: NSDictionary = [
            AppCheckDebugTokenEnvironment.firebaseDebugTokenKey: " \n\t "
        ]
        XCTAssertTrue(plist.write(to: plistURL, atomically: true))
        defer { try? FileManager.default.removeItem(at: plistURL) }

        var exported: [String: String] = [:]
        let token = AppCheckDebugTokenEnvironment.configureIfAvailable(
            firebasePlistPath: plistURL.path,
            infoDictionary: [AppCheckDebugTokenEnvironment.firaDebugTokenKey: ""],
            environment: [AppCheckDebugTokenEnvironment.firebaseDebugTokenKey: "  "],
            debugAppCheckAllowed: true,
            setEnvironment: { key, value, _ in
                exported[key] = value
                return 0
            }
        )

        XCTAssertNil(token)
        XCTAssertTrue(exported.isEmpty)
    }

    func testDebugAppCheckAllowedRequiresDebugBuildOrBuiltInternalFlag() {
        XCTAssertTrue(AppCheckDebugTokenEnvironment.debugAppCheckAllowed(infoDictionary: [:], isDebugBuild: true))
        XCTAssertFalse(AppCheckDebugTokenEnvironment.debugAppCheckAllowed(infoDictionary: [:], isDebugBuild: false))
        XCTAssertFalse(
            AppCheckDebugTokenEnvironment.debugAppCheckAllowed(
                infoDictionary: [AppCheckDebugTokenEnvironment.useDebugAppCheckInfoKey: "NO"],
                isDebugBuild: false
            )
        )
        XCTAssertTrue(
            AppCheckDebugTokenEnvironment.debugAppCheckAllowed(
                infoDictionary: [AppCheckDebugTokenEnvironment.useDebugAppCheckInfoKey: "YES"],
                isDebugBuild: false
            )
        )
    }

    func testReturnsNilWhenNoDebugTokenIsConfigured() {
        var exported: [String: String] = [:]
        let token = AppCheckDebugTokenEnvironment.configureIfAvailable(
            firebasePlistPath: nil,
            infoDictionary: [:],
            environment: [:],
            debugAppCheckAllowed: true,
            setEnvironment: { key, value, _ in
                exported[key] = value
                return 0
            }
        )

        XCTAssertNil(token)
        XCTAssertTrue(exported.isEmpty)
    }
}
