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
            isDebugBuild: false,
            appAttestIsSupported: false,
            deviceCheckIsSupported: true
        )

        XCTAssertNotEqual(selection, .debug)
        XCTAssertEqual(selection, .deviceCheck)
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

    func testMacProductionIgnoresMisleadingAppAttestSupportAndUsesDeviceCheck() {
        XCTAssertEqual(
            OpenBurnBarAppCheckProviderFactory.productionProviderSelection(
                appAttestIsSupported: true,
                deviceCheckIsSupported: true
            ),
            .deviceCheck
        )
    }

    func testProductionFallsBackToDeviceCheckWhenAppAttestIsUnsupported() {
        XCTAssertEqual(
            OpenBurnBarAppCheckProviderFactory.productionProviderSelection(
                appAttestIsSupported: false,
                deviceCheckIsSupported: true
            ),
            .deviceCheck
        )
    }

    func testProductionFailsClosedWhenNoAttestationProviderIsSupported() {
        XCTAssertEqual(
            OpenBurnBarAppCheckProviderFactory.productionProviderSelection(
                appAttestIsSupported: false,
                deviceCheckIsSupported: false
            ),
            .unsupported
        )
    }

    private func writeGooglePlist(_ values: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoogleService-Info-\(UUID().uuidString).plist")
        XCTAssertTrue((values as NSDictionary).write(to: url, atomically: true))
        return url
    }
}
