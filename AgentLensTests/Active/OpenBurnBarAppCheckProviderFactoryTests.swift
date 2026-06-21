import XCTest
@testable import OpenBurnBar
import OpenBurnBarCore

final class OpenBurnBarAppCheckProviderFactoryTests: XCTestCase {
    func testDebugBuildWithTokenSelectsDebugProvider() throws {
        let plistURL = try writeGooglePlist([
            AppCheckDebugTokenEnvironment.firebaseDebugTokenKey: "debug-token"
        ])
        defer { try? FileManager.default.removeItem(at: plistURL) }

        XCTAssertEqual(
            OpenBurnBarAppCheckProviderFactory.providerSelection(
                firebasePlistPath: plistURL.path,
                infoDictionary: [:],
                environment: [:],
                isDebugBuild: true
            ),
            .debug
        )
    }

    func testReleaseWithoutInternalFlagIgnoresTokenBearingEnvAndPlists() throws {
        let plistURL = try writeGooglePlist([
            AppCheckDebugTokenEnvironment.firebaseDebugTokenKey: "plist-token"
        ])
        defer { try? FileManager.default.removeItem(at: plistURL) }

        let selection = OpenBurnBarAppCheckProviderFactory.providerSelection(
            firebasePlistPath: plistURL.path,
            infoDictionary: [
                AppCheckDebugTokenEnvironment.firaDebugTokenKey: "info-token",
                AppCheckDebugTokenEnvironment.useDebugAppCheckInfoKey: "NO"
            ],
            environment: [
                AppCheckDebugTokenEnvironment.firebaseDebugTokenKey: "env-token",
                AppCheckDebugTokenEnvironment.firaDebugTokenKey: "env-token"
            ],
            isDebugBuild: false
        )

        XCTAssertNotEqual(selection, .debug)
        if #available(macOS 11.0, *) {
            XCTAssertEqual(selection, .appAttest)
        } else {
            XCTAssertEqual(selection, .deviceCheck)
        }
    }

    func testReleaseWithBuiltInternalFlagAndTokenSelectsDebugProvider() throws {
        let plistURL = try writeGooglePlist([
            AppCheckDebugTokenEnvironment.firaDebugTokenKey: "plist-token"
        ])
        defer { try? FileManager.default.removeItem(at: plistURL) }

        XCTAssertEqual(
            OpenBurnBarAppCheckProviderFactory.providerSelection(
                firebasePlistPath: plistURL.path,
                infoDictionary: [AppCheckDebugTokenEnvironment.useDebugAppCheckInfoKey: "YES"],
                environment: [:],
                isDebugBuild: false
            ),
            .debug
        )
    }

    private func writeGooglePlist(_ values: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoogleService-Info-\(UUID().uuidString).plist")
        XCTAssertTrue((values as NSDictionary).write(to: url, atomically: true))
        return url
    }
}
