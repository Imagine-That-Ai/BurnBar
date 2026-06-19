@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarCodexProviderExecutorTests: XCTestCase {
    func testSanitizedEnvironmentPrependsUserCLIBinsBeforeSystemLaunchdPath() {
        let environment = BurnBarCodexProviderExecutor.sanitizedEnvironment(apiKey: "")
        let path = environment["PATH"] ?? ""
        let entries = path.split(separator: ":").map(String.init)
        let localBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin")
            .path

        XCTAssertEqual(entries.first, localBin)
        XCTAssertTrue(entries.contains("/usr/bin"))
        XCTAssertLessThan(
            try XCTUnwrap(entries.firstIndex(of: localBin)),
            try XCTUnwrap(entries.firstIndex(of: "/usr/bin"))
        )
    }
}
